import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import vm from "node:vm";

const PUBLIC = new URL("../../public/", import.meta.url).pathname;
const ORIGIN = "https://runner.test";
const source = readFileSync(join(PUBLIC, "sw.js"), "utf8");

// Runs sw.js against in-memory caches and a scripted network. `/api/version`
// answers with `release` unless the network script handles it.
function worker({ network, timeoutMs = 0, release = () => "r1", stores = new Map() }) {
  const url = (key) => (typeof key === "string" ? new URL(key, ORIGIN).href : key.url);
  const bare = (href) => { const u = new URL(href); u.search = ""; return u.href; };
  function cache(entries = new Map()) {
    const self = {
      entries,
      // Like a browser, a put replaces the old entry and goes to the end of the list.
      put: async (key, response) => { entries.delete(url(key)); entries.set(url(key), await response.clone()); },
      match: async (key, { ignoreSearch } = {}) => {
        if (!ignoreSearch) return entries.get(url(key))?.clone();
        for (const [href, response] of entries) if (bare(href) === bare(url(key))) return response.clone();
      },
      keys: async () => [...entries.keys()].map((href) => new Request(href)),
      delete: async (key) => entries.delete(url(key)),
      add: async (request) => {
        const response = await fetchFn(request);
        if (!response.ok) throw new TypeError("bad response");
        await self.put(request, response);
      },
      addAll: async (requests) => { for (const request of requests) await self.add(request); },
    };
    return self;
  }
  const caches = {
    open: async (name) => { if (!stores.has(name)) stores.set(name, cache()); return stores.get(name); },
    keys: async () => [...stores.keys()],
    delete: async (name) => stores.delete(name),
  };
  const fetchFn = (input, init) => {
    const request = typeof input === "string" ? new Request(`${ORIGIN}${input}`, init) : input;
    if (new URL(request.url).pathname === "/api/version") {
      return Promise.resolve(release()).then((id) => (id instanceof Response ? id : Response.json({ release: id })));
    }
    return network(request);
  };
  const listeners = {};
  const self = {
    location: new URL(ORIGIN),
    addEventListener: (type, fn) => { listeners[type] = fn; },
    skipWaiting: async () => {},
    clients: { claim: async () => {} },
  };
  // Relative URLs resolve against the worker's origin, as in a browser.
  const WorkerRequest = class extends Request {
    constructor(input, init) { super(typeof input === "string" ? new URL(input, ORIGIN).href : input, init); }
  };
  const context = vm.createContext({
    self, URL, Request: WorkerRequest, Response, Headers, Promise, Error, Set, Map,
    caches,
    fetch: fetchFn,
    // The network timeout fires straight away unless a test asks otherwise.
    setTimeout: (fn, ms) => setTimeout(fn, timeoutMs ?? ms),
  });
  vm.runInContext(source, context);

  async function get(path, { method = "GET", mode = "cors", client = "page", resultingClient } = {}) {
    let response;
    const waits = [];
    const request = new Request(`${ORIGIN}${path}`, { method });
    // Node's Request has no navigate mode.
    Object.defineProperty(request, "mode", { value: mode });
    listeners.fetch({
      request,
      clientId: client,
      resultingClientId: resultingClient,
      respondWith: (promise) => { response = promise; },
      waitUntil: (promise) => waits.push(promise),
    });
    if (!response) return null;
    const result = await response;
    await Promise.all(waits);
    return result;
  }

  // A page load: the page, then the modules it imports, as one client.
  async function open(id, paths = []) {
    const page = await get("/", { mode: "navigate", client: "", resultingClient: id });
    const files = [];
    for (const path of paths) files.push(await (await get(path, { client: id })).text());
    return { page: await page.text(), files };
  }

  async function lifecycle(type) {
    let done;
    listeners[type]({ waitUntil: (promise) => { done = promise; } });
    await done;
  }

  const data = () => stores.get("data")?.entries ?? new Map();
  return { get, open, install: () => lifecycle("install"), activate: () => lifecycle("activate"), stores, data, listeners };
}

const ok = (body) => new Response(body, { status: 200 });
const offline = () => Promise.reject(new TypeError("Failed to fetch"));
const delay = (ms, value) => new Promise((resolve) => setTimeout(() => resolve(value), ms));

// ---------- API: network first, capped cache ----------

test("serves the network answer and keeps a copy", async () => {
  const sw = worker({ network: async () => ok("v2") });

  const response = await sw.get("/api/programs");

  assert.equal(await response.text(), "v2");
  assert.equal(await sw.data().get(`${ORIGIN}/api/programs`).text(), "v2");
});

test("prefers a fresh answer over the copy whenever the server answers", async () => {
  let version = "v1";
  const sw = worker({ network: async () => ok(version), timeoutMs: 1000 });
  await sw.get("/api/programs");
  version = "v2";

  const response = await sw.get("/api/programs");

  assert.equal(await response.text(), "v2");
  assert.equal(response.headers.get("x-served-from"), null);
});

test("answers from the cache when offline, marked as such", async () => {
  let up = true;
  const sw = worker({ network: async () => (up ? ok("plan") : offline()) });
  await sw.get("/api/programs");
  up = false;

  const response = await sw.get("/api/programs");

  assert.equal(await response.text(), "plan");
  assert.equal(response.headers.get("x-served-from"), "cache");
});

test("answers from the cache when the server errors", async () => {
  let status = 200;
  const sw = worker({ network: async () => new Response("x", { status }) });
  await sw.get("/api/workouts");
  status = 502;

  const response = await sw.get("/api/workouts");

  assert.equal(response.headers.get("x-served-from"), "cache");
});

test("does not wait for a slow network when there is a copy, but still refreshes it", async () => {
  let reply = async () => ok("old");
  const sw = worker({ network: (request) => reply(request) });
  await sw.get("/api/history");
  reply = () => delay(20, ok("new"));

  const response = await sw.get("/api/history");

  assert.equal(await response.text(), "old");
  assert.equal(await sw.data().get(`${ORIGIN}/api/history`).text(), "new");
});

test("falls back to the last day fetched when a date has no copy", async () => {
  let up = true;
  const sw = worker({ network: async () => (up ? ok("friday") : offline()) });
  await sw.get("/api/today?date=2026-10-23");
  up = false;

  const response = await sw.get("/api/today?date=2026-10-24");

  assert.equal(await response.text(), "friday");
});

test("falls back the same way for a page that sends the day as today", async () => {
  let up = true;
  const sw = worker({ network: async () => (up ? ok("friday") : offline()) });
  await sw.get("/api/coach?today=2026-10-23");
  await sw.get("/api/calendar?from=2026-10-19&to=2026-10-25&today=2026-10-23");
  up = false;

  assert.equal(await (await sw.get("/api/coach?today=2026-10-24")).text(), "friday");
  assert.equal(await (await sw.get("/api/calendar?from=2026-10-19&to=2026-10-25&today=2026-10-24")).text(), "friday");
  // Another range is another answer: no copy.
  await assert.rejects(sw.get("/api/calendar?from=2026-10-26&to=2026-11-01&today=2026-10-24"));
});

test("keeps a picked workout apart from the default plan", async () => {
  let body = "default";
  let up = true;
  const sw = worker({ network: async () => (up ? ok(body) : offline()) });
  await sw.get("/api/today?date=2026-10-23");
  body = "picked";
  await sw.get("/api/today?date=2026-10-23&workout_id=3");
  up = false;

  assert.equal(await (await sw.get("/api/today?date=2026-10-24")).text(), "default");
  assert.equal(await (await sw.get("/api/today?workout_id=3&date=2026-10-24")).text(), "picked");
});

test("does not keep redirects or errors", async () => {
  const sw = worker({
    network: async (request) => {
      if (request.url.endsWith("/login")) {
        const response = ok("sign in");
        Object.defineProperty(response, "redirected", { value: true });
        return response;
      }
      return new Response("nope", { status: 404 });
    },
  });

  await sw.get("/login");
  await sw.get("/missing");

  assert.equal(sw.data().size, 0);
});

// Room for 50 workouts fetched ahead, three entries each, and the rest.
test("never holds more than the last 200 answers", async () => {
  const sw = worker({ network: async (request) => ok(request.url) });

  for (let id = 1; id <= 220; id++) await sw.get(`/api/exercises/${id}/history`);

  assert.equal(sw.data().size, 200);
  assert.ok(!sw.data().has(`${ORIGIN}/api/exercises/20/history`));
  assert.ok(sw.data().has(`${ORIGIN}/api/exercises/21/history`));
  assert.ok(sw.data().has(`${ORIGIN}/api/exercises/220/history`));
});

test("counts a refreshed answer as new", async () => {
  const sw = worker({ network: async (request) => ok(request.url) });
  for (let id = 1; id <= 200; id++) await sw.get(`/api/exercises/${id}/history`);

  await sw.get("/api/exercises/1/history");
  await sw.get("/api/exercises/201/history");

  assert.ok(sw.data().has(`${ORIGIN}/api/exercises/1/history`));
  assert.ok(!sw.data().has(`${ORIGIN}/api/exercises/2/history`));
});

test("leaves writes and the release check to the page", async () => {
  const sw = worker({ network: async () => ok("") });

  assert.equal(await sw.get("/api/sessions", { method: "POST" }), null);
  assert.equal(await sw.get("/api/version"), null);
});

// ---------- The shell: one release at a time ----------

test("caches the shell under the server's release on install, even with the API down", async () => {
  const sw = worker({ network: async (request) => (request.url.includes("/api/") ? offline() : ok("file")), release: () => "abc" });

  await sw.install();

  const shell = sw.stores.get("release-abc").entries;
  assert.ok(shell.has(`${ORIGIN}/`));
  assert.ok(shell.has(`${ORIGIN}/js/app.js`));
  assert.equal(sw.data().size, 0);
});

test("caches program data on install when the API answers", async () => {
  const sw = worker({ network: async () => ok("data") });

  await sw.install();

  assert.equal(await sw.data().get(`${ORIGIN}/api/today`).text(), "data");
});

test("serves shell files from the cache once installed, without waiting for the network", async () => {
  let network = async () => ok("r1");
  const sw = worker({ network: (request) => network(request) });
  await sw.install();
  network = offline;

  const { page, files } = await sw.open("tab", ["/js/app.js", "/css/app.css"]);

  assert.equal(page, "r1");
  assert.deepEqual(files, ["r1", "r1"]);
});

test("serves every module of a page from the same release on a slow network after a deploy", async () => {
  let release = "r1";
  let network = async () => ok("r1");
  const sw = worker({ network: (request) => network(request), release: () => release, timeoutMs: 5 });
  await sw.install();
  release = "r2";
  network = () => delay(30, ok("r2"));

  const slow = await sw.open("tab-1", ["/js/app.js", "/js/workout.js", "/js/player.js"]);

  assert.equal(slow.page, "r1");
  assert.deepEqual(slow.files, ["r1", "r1", "r1"]);

  // The new release was fetched whole in the background: the next load uses it.
  const next = await sw.open("tab-2", ["/js/app.js", "/js/workout.js"]);
  assert.equal(next.page, "r2");
  assert.deepEqual(next.files, ["r2", "r2"]);
  // The page opened on r1 keeps getting r1.
  assert.equal(await (await sw.get("/js/history.js", { client: "tab-1" })).text(), "r1");
});

test("switches to a new release on the same load when it arrives in time", async () => {
  let release = "r1";
  let body = "r1";
  const sw = worker({ network: async () => ok(body), release: () => release, timeoutMs: 1000 });
  await sw.install();
  release = "r2";
  body = "r2";

  const { page, files } = await sw.open("tab", ["/js/app.js"]);

  assert.equal(page, "r2");
  assert.deepEqual(files, ["r2"]);
});

test("keeps the current release when the server cannot say which is current", async () => {
  let release = () => "r1";
  let network = async () => ok("r1");
  const sw = worker({ network: (request) => network(request), release: () => release() });
  await sw.install();
  release = offline;
  network = offline;

  const { page, files } = await sw.open("tab", ["/js/app.js"]);

  assert.equal(page, "r1");
  assert.deepEqual(files, ["r1"]);
});

test("throws away a release that changed while it was being fetched", async () => {
  // Asked before and after fetching the files: r2 is replaced by r3 in between.
  const ids = ["r1", "r1", "r2", "r3"];
  const sw = worker({ network: async () => ok("file"), release: () => ids.shift() ?? "r3" });
  await sw.install();

  await assert.rejects(sw.install());
  assert.ok(!sw.stores.has("release-r2"));
  assert.equal(await (await sw.stores.get("meta").match("/current-release")).text(), "r1");
});

test("keeps the release before the current one and deletes older ones", async () => {
  let release = "r1";
  const sw = worker({ network: async () => ok(release), release: () => release, timeoutMs: 1000 });
  await sw.install();
  for (const next of ["r2", "r3"]) {
    release = next;
    await sw.open(`tab-${next}`);
  }

  const releases = [...sw.stores.keys()].filter((name) => name.startsWith("release-")).sort();
  assert.deepEqual(releases, ["release-r2", "release-r3"]);
});

test("activate deletes the caches of other releases and the old unversioned cache", async () => {
  const stores = new Map();
  const old = worker({ network: async () => ok("x"), release: () => "r1", stores });
  await old.install();
  stores.set("release-r0", stores.get("release-r1"));
  stores.set("lazy-runner", stores.get("release-r1"));

  await old.activate();

  assert.deepEqual([...stores.keys()].sort(), ["data", "meta", "release-r1"]);
});

test("asks the server when no release is cached yet", async () => {
  const sw = worker({ network: async () => ok("live"), release: offline });

  const response = await sw.get("/js/app.js");

  assert.equal(await response.text(), "live");
});

// ---------- A sign-in in front of the app ----------

test("hands a page load with ?gate the redirect to a sign-in page in front of the app", async () => {
  let walled = false;
  const sw = worker({
    network: async (request) => {
      // A navigation doesn't follow redirects: the browser sees an opaque one.
      if (walled && request.url.includes("signin.html")) return Object.defineProperty(new Response(null, { status: 200 }), "type", { value: "opaqueredirect" });
      return ok(`net ${new URL(request.url).pathname}`);
    },
    timeoutMs: 1000,
  });
  await sw.install();
  walled = true;

  const page = await sw.get("/signin.html?gate=1", { mode: "navigate", client: "", resultingClient: "a" });
  assert.equal(page.type, "opaqueredirect");

  // Without ?gate the page comes from the release, wall or not.
  assert.equal(await (await sw.get("/signin.html", { mode: "navigate", client: "", resultingClient: "b" })).text(), "net /signin.html");
});

test("hands a page load with ?gate a sign-in challenge, but not another refusal", async () => {
  let answer = ok("page");
  const sw = worker({ network: async (request) => (request.url.includes("gate") ? answer : ok(`net ${new URL(request.url).pathname}`)), timeoutMs: 1000 });
  await sw.install();

  answer = new Response("who are you", { status: 401, headers: { "www-authenticate": "Basic" } });
  assert.equal((await sw.get("/signin.html?gate=1", { mode: "navigate", client: "", resultingClient: "a" })).status, 401);
  // A 403 page would be all an installed app shows: the release copy instead.
  answer = new Response("go away", { status: 403 });
  assert.equal(await (await sw.get("/signin.html?gate=1", { mode: "navigate", client: "", resultingClient: "b" })).text(), "net /signin.html");
});

test("serves a ?gate page load from the release when nothing is in the way, or offline", async () => {
  let up = true;
  let version = "v1";
  const sw = worker({ network: async (request) => (up ? ok(`${version} ${new URL(request.url).pathname}`) : offline()), timeoutMs: 1000 });
  await sw.install();
  version = "v2"; // the network's copy is not mixed into the release

  assert.equal(await (await sw.get("/signin.html?gate=1", { mode: "navigate", client: "", resultingClient: "a" })).text(), "v1 /signin.html");
  up = false;
  assert.equal(await (await sw.get("/signin.html?gate=1", { mode: "navigate", client: "", resultingClient: "b" })).text(), "v1 /signin.html");
});

test("lists every file in public/ in the shell", async () => {
  const paths = [];
  const sw = worker({ network: async (request) => { paths.push(new URL(request.url).pathname); return ok(""); } });
  await sw.install();

  const files = (function walk(dir) {
    return readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
      entry.isDirectory() ? walk(join(dir, entry.name)) : [`/${relative(PUBLIC, join(dir, entry.name))}`]);
  })(PUBLIC).filter((path) => path !== "/sw.js");

  assert.deepEqual(files.filter((path) => !paths.includes(path)), []);
  assert.deepEqual(paths.filter((path) => !path.startsWith("/api/") && path !== "/" && !files.includes(path)), []);
});
