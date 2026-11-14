// An ordered queue of API writes that survives reloads and lost connections.
//
// Requests are sent in order. Anything that may succeed later stops the flush
// and keeps the request for the next try: no connection, a server error, a
// throttled request, or an expired sign-in (401/403/407, or a redirect to a
// sign-in page). A request the server rejects for good (400, 404, 409, 410,
// 422 and other 4xx) is moved to a rejected list with the server's error, so
// it cannot block the queue and is not lost without a trace.
//
// A request can save the id from its response under a name (`saveAs`), and
// later paths refer to it as `{name}`, so sets can be queued before the
// session exists. When a request with `saveAs` is rejected, the requests that
// refer to it are rejected along with it.
//
// Several tabs (or the installed app and a browser tab) can share one queue:
// every read and change starts from what is in storage, so no tab writes back
// a stale copy over another's entries, and flushing holds a Web Lock so only
// one tab sends at a time. Without Web Locks two tabs may both send an entry;
// the writes are idempotent (sessions are created with a client_ref) and the
// entry is still taken off the queue once.
//
// Each entry carries the id of the user who queued it (`user`), and is only
// ever sent while that user is signed in on this device: changes queued by
// someone whose sign-in ran out never land in the next person's account.
// account.js clears the queue when someone else signs in, but only once
// they are signed in, and another tab may flush in between. So each entry
// is skipped here when the device's account is someone else's, and sent
// with its user's id, which the server checks against the session: a 409
// user_mismatch drops it unseen, as the clearing would have (#205).

import { errorMessage, send as sendRequest } from "./api.js";

// Retried, and worth telling the user to sign in again. A 403 is a proxy's
// sign-in unless the app answered it (its JSON error): then it's a refusal.
const AUTH = new Set([401, 403, 407]);
// Retried: the server may answer differently later.
const LATER = new Set([408, 425, 429]);
// Rejected requests kept for the user to see; the oldest go first.
const KEEP_REJECTED = 50;
// Saved responses kept for whichever tab asked for them; the oldest go first.
const KEEP_RESULTS = 10;

const empty = () => ({ queue: [], ids: {}, rejected: [], results: {} });

// What to do with a response: { outcome: "sent" | "retry" | "drop", ... }.
// `waiting` says why a retry waits ("offline", "auth" or "server").
async function classify(response, entry) {
  if (response.redirected) return { outcome: "retry", waiting: "auth" };
  const json = AUTH.has(response.status) && response.status !== 403 ? undefined : await response.json().catch(() => undefined);
  if (AUTH.has(response.status) && !(response.status === 403 && json?.error?.code)) return { outcome: "retry", waiting: "auth" };
  if (LATER.has(response.status) || response.status >= 500) return { outcome: "retry", waiting: "server" };
  if (response.status === 409 && json?.error?.code === "user_mismatch") return { outcome: "discard" };

  if (!response.ok) {
    return { outcome: "drop", status: response.status, error: errorMessage(json, response.status) };
  }
  // A sign-in or proxy page that came back as 200: the request never reached the app.
  if (entry.saveAs && (json == null || typeof json !== "object")) return { outcome: "retry", waiting: "auth" };
  return { outcome: "sent", json };
}

// `locks` is navigator.locks where the browser has it.
export function createOutbox({ storage, fetch, locks, user = () => null, key = "outbox", now = () => new Date().toISOString() }) {
  const load = () => {
    try {
      return { ...empty(), ...JSON.parse(storage.getItem(key)) };
    } catch {
      return empty();
    }
  };
  let data = load();
  let flushing = null;
  let waiting = null;
  // False once a save has failed: from then on this page's copy is the only
  // complete one, so it is not replaced from storage.
  let stored = true;

  // Picks up what other tabs changed since this page last looked.
  const refresh = () => {
    if (!stored) return data;
    try {
      const raw = storage.getItem(key);
      // Gone: signing out or in as someone else cleared it (account.js).
      data = raw == null ? empty() : { ...empty(), ...JSON.parse(raw) };
    } catch {
      // Unreadable storage: keep this page's copy.
    }
    return data;
  };

  const save = () => {
    try {
      storage.setItem(key, JSON.stringify(data));
      stored = true;
    } catch {
      stored = false;
      // Storage full or blocked: the queue still works for this page load.
    }
  };

  const names = (path) => [...path.matchAll(/\{([\w:.-]+)\}/g)].map((m) => m[1]);

  // The path with saved ids filled in, or null while one is missing.
  function resolve(path) {
    const missing = names(path).some((name) => data.ids[name] == null);
    return missing ? null : path.replace(/\{([\w:.-]+)\}/g, (_, name) => data.ids[name]);
  }

  function reject(entry, status, error) {
    data.rejected.push({ entry, status, error, at: now() });
    data.rejected = data.rejected.slice(-KEEP_REJECTED);
  }

  // Rejects the queued requests that refer to a name that will never get an
  // id, and in turn the ones that refer to theirs.
  function rejectDependants(name, cause) {
    const lost = new Set([name]);
    data.queue = data.queue.filter((entry) => {
      if (!names(entry.path).some((n) => lost.has(n))) return true;
      if (entry.saveAs) lost.add(entry.saveAs);
      reject(entry, null, `Not sent: ${cause}`);
      return false;
    });
  }

  // Drops, unseen, the queued requests that refer to a discarded name.
  function discardDependants(name) {
    const lost = new Set([name]);
    data.queue = data.queue.filter((entry) => {
      if (!names(entry.path).some((n) => lost.has(n))) return true;
      if (entry.saveAs) lost.add(entry.saveAs);
      return false;
    });
  }

  async function send(entry) {
    // Someone else's change, before anything else: never sent, never shown.
    const current = user();
    if (entry.user != null && current != null && entry.user !== current) return { outcome: "discard" };

    const path = resolve(entry.path);
    // What it refers to was rejected before this outbox kept dependants.
    if (path === null) return { outcome: "drop", status: null, error: "Not sent: an earlier change it depends on was not saved" };

    let response;
    try {
      response = await sendRequest(path, { method: entry.method, body: entry.body, fetchFn: fetch, user: entry.user });
    } catch {
      return { outcome: "retry", waiting: "offline" };
    }
    return classify(response, entry);
  }

  function keepResult(name, json) {
    delete data.results[name];
    data.results[name] = json;
    const names = Object.keys(data.results);
    for (const old of names.slice(0, Math.max(0, names.length - KEEP_RESULTS))) delete data.results[old];
  }

  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

  async function run() {
    while (refresh().queue.length > 0) {
      const entry = data.queue[0];
      const result = await send(entry);
      if (result.outcome === "retry") {
        waiting = result.waiting;
        return false;
      }
      // Another tab may have changed the queue while this request was out,
      // or (without Web Locks) sent the same entry and taken it off already.
      refresh();
      if (same(data.queue[0], entry)) data.queue.shift();
      if (result.outcome === "discard") {
        // Someone else's change: gone without a trace, as signing in clears
        // it, and so are the changes that build on it.
        if (entry.saveAs) discardDependants(entry.saveAs);
      } else if (result.outcome === "drop") {
        reject(entry, result.status, result.error);
        if (entry.saveAs) rejectDependants(entry.saveAs, result.error);
      } else if (entry.saveAs) {
        keepResult(entry.saveAs, result.json);
        if (result.json?.id != null) data.ids[entry.saveAs] = result.json.id;
      }
      save();
    }
    waiting = null;
    return true;
  }

  const locked = () => (locks ? locks.request(key, run) : run());

  return {
    enqueue(entry) {
      const owner = user();
      refresh().queue.push(owner == null ? entry : { ...entry, user: owner });
      save();
    },
    remember(name, id) {
      refresh().ids[name] = id;
      save();
    },
    // Resolves to true once everything queued so far has been handled, here
    // or by another tab.
    flush() {
      flushing ??= locked().finally(() => { flushing = null; });
      return flushing;
    },
    pending: () => refresh().queue.length,
    // The requests still to send, oldest first.
    queued: () => refresh().queue.map((entry) => ({ ...entry })),
    // Why the last flush stopped early: "offline", "auth", "server" or null.
    waiting: () => waiting,
    // Requests the server would not take, oldest first: { entry, status, error, at }.
    rejected: () => [...refresh().rejected],
    dismissRejected() {
      refresh().rejected = [];
      save();
    },
    result: (name) => refresh().results[name],
  };
}
