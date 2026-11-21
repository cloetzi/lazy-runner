// Service worker: lets the app open and run a session with no connection.
//
// The app shell (every file in public/) is kept as one unit per release, in a
// cache named after the release id the server gives at /api/version (a digest
// of public/, so there is no version to bump). A page and every module it
// imports come from the same release, even on a slow connection right after a
// deploy: mixing an old module with a new one breaks the page. On each page
// load the worker asks the server for its release; a new one is fetched whole
// in the background and used as soon as it is complete, straight away if
// that takes less than NETWORK_TIMEOUT_MS, otherwise from the next page load.
// The release before the current one stays for pages still open on it; older
// ones are deleted.
//
// Everything else (the API) is network first. Each good answer is copied
// into a separate cache that keeps the last DATA_LIMIT entries. The cache
// only answers when there is a copy and the network fails, answers with a
// server error or is slower than NETWORK_TIMEOUT_MS; in that last case the
// network answer still refreshes the cache in the background. While online,
// the pages fetch ahead what they read (offline.js), so the cache holds
// every workout, the calendar, the coach board and history. The copies are
// one user's: the pages delete the cache on a sign-out, on a switch to
// someone else and when the server says nobody is signed in (account.js).
// An answer still on its way then goes into the deleted cache, which a
// request keeps from before (`caches.open` at its start), not the new one.
//
// Writes (anything but GET) pass straight through; the outbox in the page
// queues them while offline.
//
// A sign-in page in front of the app (a proxy's) is never reached from the
// cache. When the page finds one in the way (account.js), it loads the
// sign-in page with `?gate`: that page load asks the network too, and a
// redirect or sign-in challenge goes to the browser, which shows the proxy's
// sign-in.
// Otherwise it comes from the release as usual.

const RELEASE_PREFIX = "release-";
const DATA_CACHE = "data";
const META_CACHE = "meta";
const CURRENT = "/current-release"; // keys in META_CACHE
const PREVIOUS = "/previous-release";
const COMPLETE = "/release-complete"; // put last into a release cache, once it holds the whole shell
// Room for 50 workouts fetched ahead (three entries each) and the rest.
const DATA_LIMIT = 200;
const NETWORK_TIMEOUT_MS = 3000;

// The app shell. test/js/sw.test.js checks it lists every file in public/.
const SHELL = [
  "/",
  "/index.html",
  "/calendar.html",
  "/coach.html",
  "/equipment.html",
  "/library.html",
  "/settings.html",
  "/signin.html",
  "/welcome.html",
  "/manifest.webmanifest",
  "/css/app.css",
  "/icons/icon.svg",
  "/icons/sprite.svg",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
  "/icons/apple-touch-icon.png",
  "/js/account.js",
  "/js/activities.js",
  "/js/api.js",
  "/js/app.js",
  "/js/beeper.js",
  "/js/builder.js",
  "/js/calendar-page.js",
  "/js/calendar-sheets.js",
  "/js/calendar.js",
  "/js/catalog.js",
  "/js/check-in-sheets.js",
  "/js/check-ins.js",
  "/js/coach-news.js",
  "/js/coach-page.js",
  "/js/coach-sheets.js",
  "/js/coach.js",
  "/js/countdown.js",
  "/js/editor.js",
  "/js/equipment-list.js",
  "/js/equipment.js",
  "/js/example-list.js",
  "/js/gear.js",
  "/js/figure-view.js",
  "/js/figure.js",
  "/js/howto.js",
  "/js/history.js",
  "/js/html.js",
  "/js/inventory.js",
  "/js/library.js",
  "/js/nav.js",
  "/js/offline.js",
  "/js/outbox.js",
  "/js/plan-changes.js",
  "/js/player.js",
  "/js/preferences.js",
  "/js/pwa.js",
  "/js/routes.js",
  "/js/routines.js",
  "/js/routine-sheets.js",
  "/js/rpe-picker.js",
  "/js/run-store.js",
  "/js/session-log.js",
  "/js/settings.js",
  "/js/setup.js",
  "/js/signin.js",
  "/js/skeleton.json",
  "/js/sports.json",
  "/js/swap.js",
  "/js/unit-setting.js",
  "/js/week.js",
  "/js/weights.js",
  "/js/welcome.js",
  "/js/workout.js",
];

const SHELL_PATHS = new Set(SHELL);

// Program data, cached on install too but allowed to fail (the server may be
// unreachable while the shell is served from somewhere that is not).
const DATA = ["/api/today", "/api/workouts", "/api/exercises", "/api/equipment"];

// The release each open page was loaded from, by client id. Lost when the
// worker stops; a page it does not know gets the current release.
const pages = new Map();
// Releases being fetched, so two page loads share one download.
const installs = new Map();

self.addEventListener("install", (event) => {
  event.waitUntil((async () => {
    await update(null);
    const cache = await caches.open(DATA_CACHE);
    await Promise.allSettled(DATA.map(async (path) => {
      const response = await fetch(path);
      if (keep(response)) await store(cache, new Request(path), response);
    }));
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    await dropOldCaches();
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const { request } = event;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin) return;
  // Asked of the server itself: the release, and who is signed in.
  if (url.pathname === "/api/version" || url.pathname === "/api/me") return;
  event.respondWith(SHELL_PATHS.has(url.pathname) ? fromRelease(event) : networkFirst(request, event));
});

// A shell file from the page's release. A page load picks the release (and
// checks for a new one); the files it then asks for come from the same one.
async function fromRelease(event) {
  const { request } = event;
  const navigate = request.mode === "navigate";
  // Asked together, so a slow network costs one wait, not two.
  const blocked = navigate && new URL(request.url).searchParams.has("gate") ? signInWall(request) : null;
  const page = navigate ? releaseForPage(event) : null;
  // Its update outlives this answer, even when a sign-in is handed back first.
  if (page) event.waitUntil(page.catch(() => {}));
  const signIn = await blocked;
  if (signIn) return signIn;
  let release;
  if (navigate) {
    release = await page;
    if (event.resultingClientId) pages.set(event.resultingClientId, release);
  } else {
    release = pages.get(event.clientId) ?? (await currentRelease());
  }
  const cached = release && (await (await caches.open(releaseCache(release))).match(request, { ignoreSearch: true }));
  // No complete release yet, or this one has been cleaned up: ask the server.
  return cached ?? fetch(request);
}

// The network's answer to a page load when it is a sign-in in the way: a
// redirect (a navigation doesn't follow it, the browser does) or a sign-in
// challenge. Null when the page comes through, or the network doesn't
// answer in time. Any other refusal (a 403 page) isn't shown: it would be
// all an installed app shows, with no way back to what it has offline.
async function signInWall(request) {
  try {
    const response = await Promise.race([fetch(request), timeout(NETWORK_TIMEOUT_MS)]);
    return response.type === "opaqueredirect" || response.status === 401 || response.status === 407 ? response : null;
  } catch {
    return null;
  }
}

async function releaseForPage(event) {
  const current = await currentRelease();
  const latest = update(current);
  event.waitUntil(latest.catch(() => {}));
  try {
    return await (current ? Promise.race([latest, timeout(NETWORK_TIMEOUT_MS)]) : latest);
  } catch {
    return current;
  }
}

// Asks the server for its release and, when it is new, fetches it whole and
// makes it current. Resolves to the release to use.
async function update(current) {
  const latest = await serverRelease();
  if (latest === current) return latest;
  if (!installs.has(latest)) {
    installs.set(latest, install(latest).finally(() => installs.delete(latest)));
  }
  await installs.get(latest);
  return latest;
}

async function install(release) {
  const name = releaseCache(release);
  const cache = await caches.open(name);
  if (!(await cache.match(COMPLETE))) {
    await cache.addAll(SHELL.map((path) => new Request(path, { cache: "no-cache" })));
    // A deploy while the files came in may have mixed two releases: drop them.
    if ((await serverRelease()) !== release) {
      await caches.delete(name);
      throw new Error("release changed while fetching it");
    }
    await cache.put(COMPLETE, new Response(release));
  }
  const meta = await caches.open(META_CACHE);
  const current = await currentRelease();
  if (current === release) return;
  if (current) await meta.put(PREVIOUS, new Response(current));
  await meta.put(CURRENT, new Response(release));
  await dropOldCaches();
}

// Deletes every cache but the data, the current release and the one before
// it, which a page opened just before the switch may still load modules from.
async function dropOldCaches() {
  const meta = await caches.open(META_CACHE);
  const releases = await Promise.all([CURRENT, PREVIOUS].map(async (key) => (await meta.match(key))?.text()));
  const keep = new Set([DATA_CACHE, META_CACHE, ...releases.filter(Boolean).map(releaseCache)]);
  for (const name of await caches.keys()) {
    if (!keep.has(name)) await caches.delete(name);
  }
}

async function serverRelease() {
  const response = await fetch("/api/version", { cache: "no-store" });
  if (!keep(response)) throw new Error(`HTTP ${response.status}`);
  return (await response.json()).release;
}

async function currentRelease() {
  const response = await (await caches.open(META_CACHE)).match(CURRENT);
  return response ? response.text() : null;
}

function releaseCache(release) {
  return `${RELEASE_PREFIX}${release}`;
}

async function networkFirst(request, event) {
  const cache = await caches.open(DATA_CACHE);
  const network = fetch(request).then(async (response) => {
    if (keep(response)) await store(cache, request, response.clone());
    return response;
  });
  // Keep the worker alive until the cache is refreshed, even after a cached answer.
  event.waitUntil(network.catch(() => {}));

  const cached = await lookup(cache, request);
  if (!cached) return network;

  try {
    const response = await Promise.race([network, timeout(NETWORK_TIMEOUT_MS)]);
    // The server is down behind a proxy that still answers.
    if (response.status >= 500) return fromCache(cached);
    return response;
  } catch {
    return fromCache(cached);
  }
}

// A redirect is most likely a sign-in page in front of the app: not worth keeping.
function keep(response) {
  return response.ok && !response.redirected;
}

// Keeps the answer, then trims the cache to the DATA_LIMIT entries written
// last (a cache lists its entries in the order they were put).
async function store(cache, request, response) {
  await cache.put(request, response.clone());
  const fallback = fallbackKey(request.url);
  if (fallback !== request.url) await cache.put(fallback, response);
  const keys = await cache.keys();
  for (const key of keys.slice(0, Math.max(0, keys.length - DATA_LIMIT))) await cache.delete(key);
}

async function lookup(cache, request) {
  return (await cache.match(request)) ?? (await cache.match(fallbackKey(request.url)));
}

// The URL without the day it was asked on (`date`, or `today`), so a day
// with no copy of its own falls back to the last one fetched:
// /api/today?date=2026-10-24 -> /api/today, and
// /api/coach?today=2026-10-24 -> /api/coach.
const DAY_PARAMS = ["date", "today"];
function fallbackKey(url) {
  const parsed = new URL(url);
  if (!DAY_PARAMS.some((name) => parsed.searchParams.has(name))) return url;
  for (const name of DAY_PARAMS) parsed.searchParams.delete(name);
  return parsed.href;
}

// Marks the response so the page can tell it may be out of date.
async function fromCache(response) {
  const headers = new Headers(response.headers);
  headers.set("x-served-from", "cache");
  return new Response(await response.blob(), { status: response.status, statusText: response.statusText, headers });
}

function timeout(ms) {
  return new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), ms));
}
