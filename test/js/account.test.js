import { test } from "node:test";
import assert from "node:assert/strict";
import {
  USER_KEYS, storedAccount, forgetAccount, adoptAccount, whoIsSignedIn, checkSignedIn, signOut, signOutHere, signInHref, nextPath, syncNote, deviceName, pageAccount, inviteToken, welcomeHref, startOidc, oidcOutcome,
} from "../../public/js/account.js";
import { AHEAD_KEY } from "../../public/js/offline.js";

function memoryStorage(entries = {}) {
  const items = new Map(Object.entries(entries));
  return {
    getItem: (k) => items.get(k) ?? null,
    setItem: (k, v) => items.set(k, v),
    removeItem: (k) => items.delete(k),
    keys: () => [...items.keys()].sort(),
  };
}

function fakeCaches() {
  const deleted = [];
  return { deleted, delete: async (name) => { deleted.push(name); return true; } };
}

const someone = { id: 1, username: "runner", owner: true };
const answer = (body, init = {}) => async () => Response.json(body, init);

test("remembers who signed in, and keeps their things while it is them again", async () => {
  const storage = memoryStorage({ outbox: "[]", run: "{}" });
  const caches = fakeCaches();

  assert.deepEqual(await adoptAccount(someone, { storage, caches }), { switched: false });
  assert.deepEqual(await adoptAccount(someone, { storage, caches }), { switched: false });
  assert.deepEqual(storedAccount(storage), someone);
  assert.deepEqual(storage.keys(), ["account", "outbox", "run"]);
  assert.deepEqual(caches.deleted, []);
});

test("forgets the last user's things when someone else signs in, but keeps the device's preferences", async () => {
  const storage = memoryStorage({ account: JSON.stringify(someone), outbox: "[]", run: "{}", unit: "kg", preferences: "{}" });
  const caches = fakeCaches();

  const { switched } = await adoptAccount({ id: 2, username: "other", owner: false }, { storage, caches });

  assert.equal(switched, true);
  assert.deepEqual(storage.keys(), ["account", "preferences"]);
  assert.equal(storedAccount(storage).id, 2);
  assert.deepEqual(caches.deleted, ["data"]);
});

test("reads no account from blocked or broken storage", () => {
  assert.equal(storedAccount(null), null);
  assert.equal(storedAccount(memoryStorage({ account: "{not json" })), null);
});

test("asks the server who is signed in", async () => {
  assert.deepEqual(await whoIsSignedIn(answer({ user: someone })), { user: someone });
  assert.deepEqual(
    await whoIsSignedIn(answer({ error: { code: "unauthorized" }, setup_required: true }, { status: 401 })),
    { signedOut: true, setupRequired: true, signInWith: null },
  );
  assert.deepEqual(
    await whoIsSignedIn(answer({ error: { code: "unauthorized" }, setup_required: false }, { status: 401 })),
    { signedOut: true, setupRequired: false, signInWith: null },
  );
  assert.deepEqual(
    await whoIsSignedIn(answer({ error: { code: "unauthorized" }, setup_required: false, sign_in_with: "Home ID" }, { status: 401 })),
    { signedOut: true, setupRequired: false, signInWith: "Home ID" },
  );
});

test("starts an OIDC sign-in: the provider's page, or why not", async () => {
  let asked;
  const url = await startOidc({
    invite: "abc", next: "/calendar.html",
    fetchFn: async (path, init) => { asked = { path, body: JSON.parse(init.body) }; return Response.json({ authorize_url: "https://id.example/authorize?x=1" }); },
  });
  assert.equal(url, "https://id.example/authorize?x=1");
  assert.deepEqual(asked, { path: "/api/auth/oidc", body: { invite: "abc", next: "/calendar.html" } });
  await assert.rejects(
    startOidc({ fetchFn: async () => Response.json({ error: { message: "Can't reach Home ID" } }, { status: 502 }) }),
    /Can't reach Home ID/,
  );
});

test("says what came of an OIDC sign-in", () => {
  assert.deepEqual(oidcOutcome("linked", "Home ID"), { ok: true, message: "Linked: you can sign in with Home ID now." });
  assert.match(oidcOutcome("no_account", "Home ID").message, /No account here is linked to that Home ID sign-in/);
  assert.match(oidcOutcome("cancelled").message, /single sign-on was cancelled/);
  assert.match(oidcOutcome("something else", "Home ID").message, /didn't work/);
  assert.equal(oidcOutcome("failed").ok, false);
});

test("counts the service worker's copy, a server error or no network as offline", async () => {
  assert.deepEqual(await whoIsSignedIn(answer({ user: someone }, { headers: { "x-served-from": "cache" } })), { offline: true });
  assert.deepEqual(await whoIsSignedIn(answer({}, { status: 502 })), { offline: true });
  assert.deepEqual(await whoIsSignedIn(async () => { throw new TypeError("Failed to fetch"); }), { offline: true });
});

test("tells a sign-in in front of the app from offline", async () => {
  const gate = { signedOut: true, gate: true, setupRequired: false, signInWith: null };
  let init;
  // Redirects aren't followed: one is a proxy's sign-in page.
  await whoIsSignedIn(async (_path, options) => { init = options; return Response.json({ user: someone }); });
  assert.equal(init.redirect, "manual");
  const opaque = Object.defineProperty(new Response(null, { status: 200 }), "type", { value: "opaqueredirect" });
  assert.deepEqual(await whoIsSignedIn(async () => opaque), gate);
  // A sign-in challenge that isn't the app's JSON error.
  assert.deepEqual(await whoIsSignedIn(async () => new Response("<h1>Sign in</h1>", { status: 401, headers: { "content-type": "text/html" } })), gate);
  assert.deepEqual(await whoIsSignedIn(async () => new Response(null, { status: 407 })), gate);
  assert.deepEqual(await whoIsSignedIn(answer({ error: "Unauthorized" }, { status: 401 })), gate);
  // Any other refusal, or a page instead of the app's answer (a captive
  // portal, say), is no sign-in the app could show: offline.
  assert.deepEqual(await whoIsSignedIn(async () => new Response("Forbidden", { status: 403 })), { offline: true });
  assert.deepEqual(await whoIsSignedIn(async () => new Response("<form>", { status: 200, headers: { "content-type": "text/html" } })), { offline: true });
});

test("signs out on the server once it can after signing out on this device alone", async () => {
  const storage = memoryStorage({ account: JSON.stringify(someone), outbox: "[1]" });
  const caches = fakeCaches();
  await signOutHere({ storage, caches });
  assert.deepEqual(storage.keys(), ["signed-out-here"]);
  assert.deepEqual(caches.deleted, ["data"]);

  // Still offline: nothing to do yet.
  assert.deepEqual(await checkSignedIn({ storage, caches, fetchFn: async () => { throw new TypeError("offline"); } }), { offline: true });

  // The server still has the sign-in: it is ended, never taken up again.
  let signedIn = true;
  const asked = [];
  const server = async (path, init) => {
    asked.push(`${init?.method ?? "GET"} ${path}`);
    if (path === "/api/auth/logout") { signedIn = false; return Response.json({}); }
    return signedIn ? Response.json({ user: someone }) : Response.json({ error: { code: "unauthorized" }, setup_required: false }, { status: 401 });
  };
  assert.deepEqual(await checkSignedIn({ storage, caches, fetchFn: server }), { signedOut: true, setupRequired: false, signInWith: null });
  assert.deepEqual(asked, ["GET /api/me", "POST /api/auth/logout", "GET /api/me"]);
  assert.deepEqual(storage.keys(), []);

  // A server that can't sign out yet keeps the device out of the account.
  await signOutHere({ storage, caches });
  signedIn = true;
  assert.deepEqual(await checkSignedIn({ storage, caches, fetchFn: async (path) => (path === "/api/me" ? Response.json({ user: someone }) : new Response(null, { status: 502 })) }), { offline: true });
  assert.deepEqual(storage.keys(), ["signed-out-here"]);

  // An app that refuses to sign out doesn't leave the device stuck offline.
  assert.deepEqual(await checkSignedIn({ storage, caches, fetchFn: async (path) => (path === "/api/me" ? Response.json({ user: someone }) : Response.json({ error: { code: "forbidden" } }, { status: 403 })) }), { user: someone });
  assert.deepEqual(storage.keys(), []);

  // Signing in on purpose drops the note.
  await signOutHere({ storage, caches });
  await adoptAccount(someone, { storage, caches });
  assert.deepEqual(storage.keys(), ["account"]);
  assert.deepEqual(await checkSignedIn({ storage, caches, fetchFn: answer({ user: someone }) }), { user: someone });
});

// A sign-in the server ended (expired, signed out elsewhere, the user
// removed) leaves no copies of their answers to serve offline (#210).
test("forgets the copies of API answers when the app says nobody is signed in, and keeps what waits to sync", async () => {
  const storage = memoryStorage({ account: JSON.stringify(someone), outbox: "[1]", run: "{}", [AHEAD_KEY]: "1" });
  const caches = fakeCaches();
  const signedOut = answer({ error: { code: "unauthorized" }, setup_required: false }, { status: 401 });

  assert.equal((await checkSignedIn({ storage, caches, fetchFn: signedOut })).signedOut, true);
  assert.deepEqual(caches.deleted, ["data"]);
  assert.deepEqual(storage.keys(), ["account", "outbox", "run"]);

  // Someone else's sign-in in front of the app, or offline: nothing to go on.
  const kept = fakeCaches();
  await checkSignedIn({ storage, caches: kept, fetchFn: async () => new Response("proxy", { status: 401 }) });
  await checkSignedIn({ storage, caches: kept, fetchFn: async () => { throw new TypeError("offline"); } });
  await checkSignedIn({ storage, caches: kept, fetchFn: answer({ user: someone }) });
  assert.deepEqual(kept.deleted, []);
});

test("counts when the data was fetched ahead as the user's", () => {
  assert.ok(USER_KEYS.includes(AHEAD_KEY));
});

test("goes to the sign-in page through the network when a sign-in is in the way", () => {
  assert.equal(signInHref({ pathname: "/", search: "", hash: "" }, { gate: true }), "/signin.html?gate=1");
  assert.equal(signInHref({ pathname: "/coach.html", search: "", hash: "" }, { gate: true }), "/signin.html?gate=1&next=%2Fcoach.html");
  assert.equal(nextPath("?gate=1&next=%2Fcoach.html"), "/coach.html");
});

test("signs out on the server, then forgets the user's things", async () => {
  const storage = memoryStorage({ account: JSON.stringify(someone), outbox: "[]" });
  const caches = fakeCaches();
  let asked;

  const done = await signOut({ storage, caches, fetchFn: async (path, init) => { asked = { path, method: init.method }; return Response.json({}); } });

  assert.equal(done, "done");
  assert.deepEqual(asked, { path: "/api/auth/logout", method: "POST" });
  assert.deepEqual(storage.keys(), []);
  assert.deepEqual(caches.deleted, ["data"]);
});

test("keeps everything when signing out can't reach the server", async () => {
  const storage = memoryStorage({ account: JSON.stringify(someone), outbox: "[]" });

  assert.equal(await signOut({ storage, caches: fakeCaches(), fetchFn: async () => { throw new TypeError("offline"); } }), "unreachable");
  assert.equal(await signOut({ storage, caches: fakeCaches(), fetchFn: answer({}, { status: 503 }) }), "unreachable");
  assert.equal(await signOut({ storage, caches: fakeCaches(), fetchFn: answer({ error: { code: "forbidden" } }, { status: 403 }) }), "refused");
  // Something in front of the app answering is not the app signing out.
  const opaque = Object.defineProperty(new Response(null, { status: 200 }), "type", { value: "opaqueredirect" });
  assert.equal(await signOut({ storage, caches: fakeCaches(), fetchFn: async () => opaque }), "unreachable");
  assert.equal(await signOut({ storage, caches: fakeCaches(), fetchFn: async () => new Response("<h1>Sign in</h1>", { status: 401 }) }), "unreachable");
  assert.equal(await signOut({ storage, caches: fakeCaches(), fetchFn: async () => new Response("Forbidden", { status: 403 }) }), "unreachable");
  assert.deepEqual(storage.keys(), ["account", "outbox"]);
});

test("sends the sign-in page back where it came from, and only on this site", () => {
  assert.equal(signInHref({ pathname: "/", search: "", hash: "" }), "/signin.html");
  assert.equal(signInHref({ pathname: "/calendar.html", search: "?d=1", hash: "#x" }), "/signin.html?next=%2Fcalendar.html%3Fd%3D1%23x");
  assert.equal(nextPath("?next=%2Fcalendar.html%3Fd%3D1%23x"), "/calendar.html?d=1#x");
  assert.equal(nextPath(""), "/");
  assert.equal(nextPath("?next=https://elsewhere.example/"), "/");
  assert.equal(nextPath("?next=//elsewhere.example/"), "/");
  assert.equal(nextPath("?next=/\\elsewhere.example/"), "/");
  assert.equal(nextPath("?next=%2F%09%2Felsewhere.example%2F"), "/");
  assert.equal(nextPath("?next=%2F%0A%2Felsewhere.example%2F"), "/");
  assert.equal(nextPath("?next=javascript:alert(1)"), "/");
});

test("links the sync note to the sign-in page when changes wait for one", () => {
  const here = { pathname: "/calendar.html", search: "", hash: "" };

  assert.equal(syncNote(1, "offline", here), "1 change waiting to sync");
  assert.equal(syncNote(2, "auth", here), '<a href="/signin.html?next=%2Fcalendar.html">Sign in again</a> to sync 2 changes');
});

test("names a device by its browser and system", () => {
  assert.equal(deviceName("Mozilla/5.0 (Android 14; Mobile; rv:131.0) Gecko/131.0 Firefox/131.0"), "Firefox on Android");
  assert.equal(deviceName("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"), "Safari on iPhone");
  assert.equal(deviceName("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"), "Chrome on macOS");
  assert.equal(deviceName("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0"), "Edge on Windows");
  assert.equal(deviceName("curl/8.5.0"), "Unknown device");
  assert.equal(deviceName(null), "Unknown device");
});

test("a page keeps to the account it was opened for", () => {
  const storage = memoryStorage({ account: JSON.stringify(someone) });
  const page = pageAccount(storage);

  assert.equal(page.id(), 1);
  assert.equal(page.current(), true);
  storage.setItem("account", JSON.stringify({ id: 2, username: "other", owner: false }));
  assert.equal(page.id(), 1);
  assert.equal(page.current(), false);
  storage.removeItem("account");
  assert.equal(page.current(), false);
});

test("a page opened before anyone signed in takes the first account it sees", () => {
  const storage = memoryStorage();
  const page = pageAccount(storage);

  assert.equal(page.current(), true);
  storage.setItem("account", JSON.stringify(someone));
  assert.equal(page.id(), 1);
  assert.equal(page.current(), true);
});

test("reads an invite's token from the fragment, and nothing else", () => {
  const token = "a".repeat(40) + "-_9";
  assert.equal(inviteToken(`#invite/${token}`), token);
  assert.equal(inviteToken(`#invite/${token}x`), null);
  assert.equal(inviteToken("#invite/short"), null);
  assert.equal(inviteToken(""), null);
  assert.equal(inviteToken(undefined), null);
});

test("sends a first sign-in through the welcome screen, then on", () => {
  assert.equal(welcomeHref("/"), "/welcome.html");
  assert.equal(welcomeHref("/calendar.html#d"), "/welcome.html?next=%2Fcalendar.html%23d");
  assert.equal(nextPath(new URL(welcomeHref("/calendar.html#d"), "https://x.invalid").search), "/calendar.html#d");
  // Signed out on the welcome screen: back to it once, not twice.
  assert.equal(welcomeHref("/welcome.html?next=%2Fcalendar.html"), "/welcome.html?next=%2Fcalendar.html");
  assert.equal(welcomeHref("/welcome.html"), "/welcome.html");
});
