// Who is signed in on this device, and what of theirs the device keeps.
//
// The server knows who is signed in (GET /api/me). The device keeps
// changes waiting to sync (the outbox), a session under way (the run
// store), a copy of the weight unit and the service worker's copies of API
// answers, all of them one user's. So the device remembers whose they are,
// and forgets them when someone else signs in or the user signs out:
// person B never sees, or syncs into their account, what person A left.
// Device preferences (beeps, vibration, lead-in) are the device's and stay.
// Kept free of the DOM so the rules can be tested.

import { send } from "./api.js";
import { escape } from "./html.js";
import { AHEAD_KEY } from "./offline.js";

export const ACCOUNT_KEY = "account";
// What belongs to the signed-in user: the outbox, the running session, the
// unit copy and when their data was last fetched ahead (see outbox.js,
// run-store.js, weights.js, offline.js).
export const USER_KEYS = ["outbox", "run", "unit", AHEAD_KEY, "setup-hidden"];
// The service worker's copies of API answers (sw.js).
export const DATA_CACHE = "data";
// Set while the server still has to hear of a sign-out on this device alone.
export const SIGNED_OUT_HERE_KEY = "signed-out-here";

// The user this device last saw signed in: { id, username, owner }, or null.
export function storedAccount(storage) {
  try {
    return JSON.parse(storage?.getItem(ACCOUNT_KEY)) ?? null;
  } catch {
    return null;
  }
}

// The account a page is for: the first one it sees signed in. `id()` tags
// what the page queues; `current()` is false once someone else has signed
// in (or out) in another tab, so the page stops writing their things.
export function pageAccount(storage) {
  let id = null;
  return {
    id: () => (id ??= storedAccount(storage)?.id ?? null),
    current() {
      const mine = this.id();
      return mine == null || storedAccount(storage)?.id === mine;
    },
  };
}

// Forgets everything of the signed-in user's on this device.
export async function forgetAccount({ storage, caches }) {
  for (const key of [...USER_KEYS, ACCOUNT_KEY]) {
    try {
      storage?.removeItem(key);
    } catch {
      // Blocked storage keeps nothing to forget.
    }
  }
  await caches?.delete(DATA_CACHE).catch(() => false);
}

// Forgets the service worker's copies of the user's API answers, and that
// they were fetched ahead, so the next sign-in fetches them again.
async function forgetCopies({ storage, caches }) {
  try {
    storage?.removeItem(AHEAD_KEY);
  } catch {
    // Blocked storage keeps nothing to forget.
  }
  await caches?.delete(DATA_CACHE).catch(() => false);
}

// Takes note of the user the server says is signed in. When the device last
// held someone else's things, they are forgotten first; `switched` says so,
// for a page that showed them to reload.
export async function adoptAccount(user, { storage, caches }) {
  const stored = storedAccount(storage);
  const switched = stored != null && stored.id !== user.id;
  if (switched) await forgetAccount({ storage, caches });
  note(storage, false);
  try {
    storage?.setItem(ACCOUNT_KEY, JSON.stringify({ id: user.id, username: user.username, owner: user.owner }));
  } catch {
    // Blocked storage: nothing kept, so nothing to mix up either.
  }
  return { switched };
}

// Asks the server who is signed in: { user } when someone is, { signedOut,
// setupRequired } when nobody is, { signedOut, gate } when something in
// front of the app wants a sign-in first (a proxy's sign-in page), and
// { offline: true } when it can't be asked (or only the service worker's
// copy answered).
// Redirects aren't followed: the app never redirects /api/me, so one is a
// sign-in page in front of it; followed to another origin, it would look
// like no network (#222). A browser shows such a redirect as an opaque one.
export async function whoIsSignedIn(fetchFn = fetch) {
  let response;
  try {
    response = await fetchFn("/api/me", { headers: { Accept: "application/json" }, redirect: "manual" });
  } catch {
    return { offline: true };
  }
  if (response.type === "opaqueredirect") return GATE;
  if (response.headers.get("x-served-from") === "cache") return { offline: true };
  const body = await response.json().catch(() => null);
  if (appSignedOut(response, body)) {
    return { signedOut: true, setupRequired: body.setup_required === true, signInWith: body.sign_in_with ?? null };
  }
  // A sign-in challenge that isn't the app's: a proxy's, or the browser's
  // own password prompt.
  if (response.status === 401 || response.status === 407) return GATE;
  if (!response.ok || !body?.user) return { offline: true };
  return { user: body.user, coachUnseen: body.coach_unseen ?? 0 };
}

// The app's own "nobody is signed in": its error shape, not just any 401
// with JSON (proxies answer with their own).
function appSignedOut(response, body) {
  return response.status === 401 && body?.error?.code === "unauthorized";
}

const GATE = Object.freeze({ signedOut: true, gate: true, setupRequired: false, signInWith: null });

// Signs out on the server, then forgets the user's things on this device.
// Resolves to "done"; to "unreachable" when no answer came from the app
// (no network, something in front of it, or a server error), or "refused"
// when it said no: either way the device keeps everything, since it is
// still signed in.
export async function signOut({ storage, caches, fetchFn = fetch }) {
  try {
    const response = await send("/api/auth/logout", { body: {}, fetchFn, redirect: "manual" });
    if (response.type === "opaqueredirect") return "unreachable";
    const body = await response.clone().json().catch(() => null);
    if (!response.ok && !appSignedOut(response, body)) {
      const app = body?.error?.code && response.status < 500;
      return app ? "refused" : "unreachable";
    }
  } catch {
    return "unreachable";
  }
  await forgetAccount({ storage, caches });
  note(storage, false);
  return "done";
}

// Signs out on this device alone, when the server can't be reached: it
// forgets the user's things, and notes that the server still has to be
// told, which `checkSignedIn` does the next time it can (#222).
export async function signOutHere({ storage, caches }) {
  await forgetAccount({ storage, caches });
  note(storage, true);
}

// Reads, sets or clears that note. Blocked storage keeps none, and the
// server's sign-in then lasts until it expires.
function note(storage, value) {
  try {
    if (value === undefined) return storage?.getItem(SIGNED_OUT_HERE_KEY) === "1";
    if (value) storage?.setItem(SIGNED_OUT_HERE_KEY, "1");
    else storage?.removeItem(SIGNED_OUT_HERE_KEY);
  } catch {
    return false;
  }
}

// `whoIsSignedIn` for a page: after signing out on this device alone, the
// server's sign-in that is still there is ended first, never taken up
// again. While the server can't be reached, the device counts as offline;
// should the app refuse to sign out, the note goes, so the device isn't
// stuck: the sign-in is the server's to end.
//
// When the app answers that nobody is signed in (a sign-in that expired, was
// ended on another device or by the owner, or a user removed), the copies of
// API answers go, so none is served offline to whoever uses the device next
// (#210). What waits to sync and a session under way stay: they sync once
// the same user signs in again, and go if someone else does.
export async function checkSignedIn({ storage, caches, fetchFn = fetch }) {
  const me = await whoIsSignedIn(fetchFn);
  if (me.signedOut && !me.gate) await forgetCopies({ storage, caches });
  if (!note(storage)) return me;
  if (me.user) {
    const outcome = await signOut({ storage, caches, fetchFn });
    if (outcome === "unreachable") return { offline: true };
    note(storage, false);
    return outcome === "done" ? whoIsSignedIn(fetchFn) : me;
  }
  if (me.signedOut && !me.gate) note(storage, false);
  return me;
}

// Starts signing in with the install's OpenID Connect provider: resolves to
// the provider's page to send the browser to. Signed in, it links the
// identity instead. `invite` joins with an invite link; `next` is where the
// sign-in page goes on to afterwards.
export async function startOidc({ invite, next, fetchFn } = {}) {
  const response = await send("/api/auth/oidc", { body: { invite, next }, fetchFn });
  const json = await response.json().catch(() => null);
  if (!response.ok || typeof json?.authorize_url !== "string") {
    throw new Error(json?.error?.message ?? "Couldn't start the sign-in; try again.");
  }
  return json.authorize_url;
}

// What the server says came of a sign-in or a link at the provider
// (`?oidc_error=` on the sign-in page, `?oidc=` in Settings), in words;
// `ok` for a link that worked.
export function oidcOutcome(code, provider = "single sign-on") {
  const messages = {
    linked: `Linked: you can sign in with ${provider} now.`,
    no_account: `No account here is linked to that ${provider} sign-in. Sign in with your password and link it in Settings, or ask the owner for an invite.`,
    invite_gone: "This invite link has expired, been used or been revoked; ask for a new one.",
    cancelled: `Signing in with ${provider} was cancelled.`,
    unavailable: `Can't reach ${provider} right now. Try again, or sign in with your password.`,
    linked_elsewhere: `That ${provider} sign-in is linked to another user here already.`,
    already_linked: `You have a ${provider} sign-in linked already; unlink it first.`,
    signed_in: "This device is signed in already.",
    signed_out: "This device was signed out; sign in and try again.",
  };
  return { ok: code === "linked", message: messages[code] ?? `Signing in with ${provider} didn't work. Try again.` };
}

// The sign-in page, coming back to `here` (a location) afterwards. With
// `gate`, something in front of the app wants a sign-in: the service worker
// then loads the page from the network, so that sign-in shows (sw.js).
export function signInHref(here, { gate = false } = {}) {
  const next = `${here.pathname}${here.search}${here.hash}`;
  const params = new URLSearchParams();
  if (gate) params.set("gate", "1");
  if (next !== "/" && next !== "/index.html") params.set("next", next);
  // Not `params.size`: Safari before 17 doesn't have it.
  const query = params.toString();
  return query ? `/signin.html?${query}` : "/signin.html";
}

// Where to go after signing in: a path on this site, never another site.
// Read the way the browser will read it (which drops tabs and newlines, and
// takes a backslash for a slash), and kept only when it stays on this origin.
export function nextPath(search) {
  const next = new URLSearchParams(search).get("next");
  if (!next?.startsWith("/")) return "/";
  const base = "https://this-app.invalid";
  try {
    const url = new URL(next, base);
    return url.origin === base ? `${url.pathname}${url.search}${url.hash}` : "/";
  } catch {
    return "/";
  }
}

// The token of an invite link (/signin.html#invite/<token>), else null.
// It travels in the fragment, which the browser never sends.
export function inviteToken(hash) {
  return /^#invite\/([A-Za-z0-9_-]{43})$/.exec(hash ?? "")?.[1] ?? null;
}

// The welcome screen shown on a first sign-in, going on to `next` after;
// `next` itself when it is the welcome screen already.
export function welcomeHref(next) {
  if (/^\/welcome\.html([?#]|$)/.test(next)) return next;
  return next === "/" ? "/welcome.html" : `/welcome.html?next=${encodeURIComponent(next)}`;
}

// The note above a page with changes waiting to sync, as HTML. When they wait
// for a sign-in, it links to the sign-in page, which comes back to `here`.
export function syncNote(pending, waiting, here) {
  const changes = `${pending} ${pending === 1 ? "change" : "changes"}`;
  if (waiting !== "auth") return `${changes} waiting to sync`;
  return `<a href="${escape(signInHref(here))}">Sign in again</a> to sync ${changes}`;
}

// A device as people name it ("Firefox on Android"), from the user agent it
// signed in with.
export function deviceName(userAgent) {
  const ua = userAgent ?? "";
  const browser = [
    [/Edg(A|iOS)?\//, "Edge"], [/Firefox\/|FxiOS\//, "Firefox"], [/OPR\//, "Opera"],
    [/Chrome\/|CriOS\//, "Chrome"], [/Safari\//, "Safari"],
  ].find(([pattern]) => pattern.test(ua))?.[1];
  const system = [
    [/iPhone/, "iPhone"], [/iPad/, "iPad"], [/Android/, "Android"], [/CrOS/, "ChromeOS"],
    [/Mac OS X|Macintosh/, "macOS"], [/Windows/, "Windows"], [/Linux/, "Linux"],
  ].find(([pattern]) => pattern.test(ua))?.[1];
  if (browser && system) return `${browser} on ${system}`;
  return browser ?? system ?? "Unknown device";
}
