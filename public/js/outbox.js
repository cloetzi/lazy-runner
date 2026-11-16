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
// user_mismatch drops it unseen, as the clearing would have.
//
// A server error usually means an outage, and the queue waits for it to end.
// But a change that hits a bug answers 500 for good, and would hold up every
// change behind it. So when the app itself answers that it hit a bug (a 500
// with its `server_error` code, not a proxy's 502/503/504, nor the app's 503
// for a locked or full database) while it is reachable (a GET /api/version
// right after succeeds), the head entry gets a strike, and after three within
// an hour it is parked: set aside with the server's answer, together with
// the queued changes that refer to it, while the rest carries on. The user
// sees the parked changes in Settings and retries or discards them.

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
// Server errors, with the server reachable, before a change is parked.
export const PARK_AFTER = 3;
// The time from a change's first strike in which the others must come, else
// the count starts again: failures days apart are not one bug.
export const STRIKE_WINDOW_MS = 60 * 60 * 1000;

// `strikes` counts the server errors of the entry at the head of the queue;
// `parking` is set from a park until a change goes through (see strike).
const empty = () => ({ queue: [], ids: {}, rejected: [], results: {}, parked: [], strikes: null, parking: false });

// What to do with a response: { outcome: "sent" | "retry" | "drop", ... }.
// `waiting` says why a retry waits ("offline", "auth" or "server").
async function classify(response, entry) {
  if (response.redirected) return { outcome: "retry", waiting: "auth" };
  const json = AUTH.has(response.status) && response.status !== 403 ? undefined : await response.json().catch(() => undefined);
  if (AUTH.has(response.status) && !(response.status === 403 && json?.error?.code)) return { outcome: "retry", waiting: "auth" };
  if (response.status >= 500) {
    // Only the app's own answer that it hit a bug can count against the change.
    const bug = response.status === 500 && json?.error?.code === "server_error";
    return { outcome: "retry", waiting: "server", ...(bug && { status: response.status, error: errorMessage(json, response.status) }) };
  }
  if (LATER.has(response.status)) return { outcome: "retry", waiting: "server" };
  if (response.status === 409 && json?.error?.code === "user_mismatch") return { outcome: "discard" };

  if (!response.ok) {
    return { outcome: "drop", status: response.status, error: errorMessage(json, response.status) };
  }
  // A sign-in or proxy page that came back as 200: the request never reached the app.
  if (entry.saveAs && (json == null || typeof json !== "object")) return { outcome: "retry", waiting: "auth" };
  return { outcome: "sent", json };
}

// `locks` is navigator.locks where the browser has it.
export function createOutbox({
  storage, fetch, locks, user = () => null, key = "outbox", now = () => new Date().toISOString(),
  id = () => `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`,
}) {
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

  // Takes the queued requests that refer to one of `held` (a Set of names)
  // off the queue, and in turn the ones that refer to theirs, adding their
  // names to `held`. Returns them, oldest first.
  function takeDependants(held) {
    const taken = [];
    data.queue = data.queue.filter((entry) => {
      if (!names(entry.path).some((n) => held.has(n))) return true;
      if (entry.saveAs) held.add(entry.saveAs);
      taken.push(entry);
      return false;
    });
    return taken;
  }

  // Rejects the queued requests that refer to a name that will never get an
  // id, and in turn the ones that refer to theirs.
  function rejectDependants(name, cause) {
    for (const entry of takeDependants(new Set([name]))) reject(entry, null, `Not sent: ${cause}`);
  }

  // Drops, unseen, the queued requests that refer to a discarded name.
  const discardDependants = (name) => takeDependants(new Set([name]));

  // The names a parked change holds back: the id it would save, and the
  // record it acts on itself when that is named (a planned session started
  // as `{run:...}`), so the later changes to that record wait with it rather
  // than overtake it. A change to a part of one (its sets) holds nothing.
  const holds = (entry) => {
    const own = /\{([\w:.-]+)\}$/.exec(entry.path.split("?")[0])?.[1];
    return [entry.saveAs, own].filter(Boolean);
  };

  // Sets the head entry aside with the queued entries that build on it, in
  // turn, since they cannot be sent (or not in order) without it.
  function park(entry, status, error) {
    const held = new Set(holds(entry));
    const entries = [entry, ...takeDependants(held)];
    data.parked.push({ id: id(), entries, names: [...held], status, error, at: now() });
  }

  // The parked group a queued entry builds on, if any: queued after its
  // group was parked (a set for a session whose start is parked).
  function parkedFor(entry) {
    const wanted = names(entry.path);
    if (wanted.length === 0) return null;
    return data.parked.find((group) => (group.names ?? []).some((n) => wanted.includes(n))) ?? null;
  }

  // Splits a parked group into what goes with its first change when that is
  // discarded (it, and what needs an id one of those would have saved) and
  // what only waited behind it to keep the order (changes to a record that
  // exists, such as the sets of a session whose start is parked).
  function split(group) {
    const [first, ...rest] = group.entries;
    const lost = new Set([first.saveAs].filter(Boolean));
    const drop = [first];
    const keep = [];
    for (const entry of rest) {
      if (names(entry.path).some((n) => lost.has(n))) {
        drop.push(entry);
        if (entry.saveAs) lost.add(entry.saveAs);
      } else {
        keep.push(entry);
      }
    }
    return { drop, keep };
  }

  // Whether the server answers at all: a 5xx it gives while this succeeds
  // is about the change, not an outage.
  async function reachable() {
    try {
      const response = await sendRequest("/api/version", { method: "GET", fetchFn: fetch });
      return response.ok && !response.redirected;
    } catch {
      return false;
    }
  }

  // Counts a server error against the head entry; true once it is parked.
  // Once one change is parked, no other is until a change goes through: a
  // second one failing too points at the server (a full disk, a locked
  // database) rather than at the change, and the queue waits as for an outage.
  async function strike(entry, result) {
    if (refresh().parking || !(await reachable())) return false;
    refresh();
    if (!same(data.queue[0], entry)) return false;
    const at = now();
    const recent = same(data.strikes?.entry, entry) && Date.parse(at) - Date.parse(data.strikes.since ?? at) <= STRIKE_WINDOW_MS;
    const count = recent ? data.strikes.count + 1 : 1;
    if (count < PARK_AFTER) {
      data.strikes = { entry, count, since: recent ? data.strikes.since : at };
      save();
      return false;
    }
    data.queue.shift();
    data.strikes = null;
    park(entry, result.status, result.error);
    data.parking = true;
    save();
    return true;
  }

  // Queued by someone other than who is signed in on this device now.
  const othersChange = (entry) => {
    const current = user();
    return entry.user != null && current != null && entry.user !== current;
  };

  async function send(entry) {
    // Someone else's change, before anything else: never sent, never shown.
    if (othersChange(entry)) return { outcome: "discard" };

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
      // Checked by send() too, but first here: someone else's change never
      // joins a parked group, where it would show in Settings.
      const group = othersChange(entry) ? null : parkedFor(entry);
      if (group) {
        data.queue.shift();
        group.entries.push(entry);
        // What builds on it waits with the group too.
        group.names = [...new Set([...(group.names ?? []), ...holds(entry)])];
        save();
        continue;
      }
      const result = await send(entry);
      if (result.outcome === "retry") {
        if (result.status != null && (await strike(entry, result))) continue;
        waiting = result.waiting;
        return false;
      }
      // Another tab may have changed the queue while this request was out,
      // or (without Web Locks) sent the same entry and taken it off already.
      refresh();
      if (same(data.queue[0], entry)) data.queue.shift();
      if (same(data.strikes?.entry, entry)) data.strikes = null;
      if (result.outcome === "sent") data.parking = false;
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
    // Nothing left that a park could be holding up: the next change the
    // server keeps failing on is parked in its turn.
    if (data.parking) {
      data.parking = false;
      save();
    }
    waiting = null;
    return true;
  }

  const locked = (work = run) => (locks ? locks.request(key, work) : work());

  const api = {
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
    // Changes set aside after repeated server errors, oldest first:
    // { id, entries, status, error, at }, `entries` the change and those
    // that build on it.
    // `dependants` counts the ones after the first that go with it when it is
    // discarded; the rest are sent then.
    parked: () => refresh().parked.map((group) => ({
      ...group, entries: group.entries.map((e) => ({ ...e })), dependants: split(group).drop.length - 1,
    })),
    // How many changes are parked, counting those that build on them.
    parkedCount: () => refresh().parked.reduce((n, group) => n + group.entries.length, 0),
    // Puts a parked group back at the head of the queue for one more try:
    // another server error parks it again straight away. It waits for a
    // flush under way (here, or in another tab with Web Locks), since one
    // takes an entry off only while it is still at the head.
    async retryParked(groupId) {
      while (flushing) await flushing.catch(() => {});
      const retry = () => {
        const group = refresh().parked.find((g) => g.id === groupId);
        if (!group) return run();
        data.parked = data.parked.filter((g) => g !== group);
        data.queue.unshift(...group.entries);
        data.strikes = { entry: group.entries[0], count: PARK_AFTER - 1, since: now() };
        data.parking = false;
        save();
        return run();
      };
      flushing = locked(retry).finally(() => { flushing = null; });
      return flushing;
    },
    // Whether the change saved under `name` waits among the parked ones.
    isParked: (name) => refresh().parked.some((group) => group.entries.some((e) => e.saveAs === name)),
    // Drops a parked change with the changes that need an id it would have
    // saved, and puts the ones that only waited behind it back at the head
    // of the queue. Changes queued behind it that need its id are rejected
    // when their turn comes, in the list the user sees. The user has dealt
    // with it, so the next change the server keeps failing on is parked in
    // turn rather than holding up the queue.
    // Waits for a flush under way, as retryParked does, since one takes an
    // entry off only while it is still at the head.
    async discardParked(groupId) {
      while (flushing) await flushing.catch(() => {});
      const discard = () => {
        const group = refresh().parked.find((g) => g.id === groupId);
        if (!group) return;
        data.parked = data.parked.filter((g) => g !== group);
        data.queue.unshift(...split(group).keep);
        data.parking = false;
        save();
      };
      await locked(discard);
    },
  };
  return api;
}

// What a queued change is, in a few words, for the list of parked changes.
export function describeChange(entry) {
  const path = entry.path.split("?")[0];
  const body = entry.body ?? {};
  const workout = entry.workout?.title;
  if (/^\/api\/sessions\/[^/]+\/sets$/.test(path)) return "A logged set";
  if (/^\/api\/sessions\/[^/]+\/complete$/.test(path)) return "Finishing a workout";
  if (path === "/api/sessions" && entry.method === "POST") {
    if (body.status === "skipped") return "Skipping a workout";
    if (body.status === "in_progress") return "Starting a workout";
    return workout ? `Planning ${workout}` : "Planning a workout";
  }
  if (/^\/api\/sessions\/[^/]+$/.test(path)) {
    if (entry.method === "DELETE") return "Removing a workout";
    if (body.status === "skipped") return "Skipping a workout";
    if (body.status === "in_progress") return "Starting a workout";
    if (body.date) return "Moving a workout";
    return "Changing a workout";
  }
  if (/^\/api\/exercises\/[^/]+\/weight$/.test(path)) return "An exercise's weight";
  if (/^\/api\/activities(\/|$)/.test(path)) {
    if (entry.method === "POST") return "Logging an activity";
    return entry.method === "DELETE" ? "Removing an activity" : "Changing an activity";
  }
  if (path === "/api/settings") return "A setting";
  return `${entry.method} ${path}`;
}
