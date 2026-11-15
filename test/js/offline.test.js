import { test } from "node:test";
import assert from "node:assert/strict";
import { offlineToday, aheadPaths, fetchAhead, AHEAD_KEY, AHEAD_EVERY_MS, AHEAD_RETRY_MS, AHEAD_WORKOUTS } from "../../public/js/offline.js";

const today = { date: "2026-10-24", source: "session", session: { id: 7, status: "in_progress" }, workout_id: 2 };

test("keeps a copy from the same day, session and all", () => {
  const result = offlineToday(today, "2026-10-24");
  assert.equal(result.session.id, 7);
  assert.equal(result.offline, true);
});

test("plans an older copy for the new day without reopening its session", () => {
  const result = offlineToday(today, "2026-10-25");
  assert.equal(result.date, "2026-10-25");
  assert.equal(result.session, null);
  assert.equal(result.source, "default");
  assert.equal(result.workout_id, 2);
});

test("drops the old day's sessions, keeping the next planned one only while it is ahead", () => {
  const planned = { ...today, day: [today.session], next_planned: { id: 8, date: "2026-10-26" } };
  assert.deepEqual(offlineToday(planned, "2026-10-25").day, []);
  assert.equal(offlineToday(planned, "2026-10-25").next_planned.id, 8);
  assert.equal(offlineToday(planned, "2026-10-26").next_planned, null);
  assert.equal(offlineToday(planned, "2026-10-27").next_planned, null);
});

function memoryStorage(entries = {}) {
  const items = new Map(Object.entries(entries));
  return { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, String(v)), removeItem: (k) => items.delete(k) };
}

const programs = [{ workouts: [{ id: 3 }, { id: 4 }] }, { workouts: [{ id: 9 }] }];

// The network as the page sees it through the service worker: `cached`
// paths answer from its copy, `status` paths with that status, `redirected`
// ones from a sign-in page in front of the app, and nothing answers when it
// is `down`.
function server({ cached = [], status = {}, redirected = [], down = false } = {}) {
  const asked = [];
  const fetchFn = async (path) => {
    asked.push(path);
    if (down) throw new TypeError("Failed to fetch");
    const headers = cached.includes(path) ? { "x-served-from": "cache" } : {};
    const response = Response.json(path === "/api/workouts" ? programs : {}, { headers, status: status[path] ?? 200 });
    if (redirected.includes(path)) Object.defineProperty(response, "redirected", { value: true });
    return response;
  };
  return { asked, fetchFn };
}

test("fetches ahead every page's reads, and each workout to view and to start", () => {
  const paths = aheadPaths("2026-11-14", [3, 4]);
  for (const path of [
    "/api/today?date=2026-11-14",
    // This week (phones) and this month (wide screens) on the calendar.
    "/api/calendar?from=2026-11-09&to=2026-11-15&today=2026-11-14",
    "/api/calendar?from=2026-10-26&to=2026-12-06&today=2026-11-14",
    "/api/sessions?status=planned,in_progress&from=2026-11-13",
    "/api/coach?today=2026-11-14",
    "/api/history?days=28&date=2026-11-14",
    "/api/history/exercises",
    "/api/workouts/3", "/api/today?date=2026-11-14&workout_id=3",
    "/api/workouts/4", "/api/today?date=2026-11-14&workout_id=4",
  ]) assert.ok(paths.includes(path), path);
  assert.equal(new Set(paths).size, paths.length);
  const many = Array.from({ length: AHEAD_WORKOUTS + 5 }, (_, i) => i + 1);
  assert.equal(aheadPaths("2026-11-14", many).filter((path) => path.startsWith("/api/workouts/")).length, AHEAD_WORKOUTS);
});

test("fetches the workout list first, then the rest, and not again that day for a while", async () => {
  const storage = memoryStorage();
  const network = server();
  assert.equal(await fetchAhead({ storage, date: "2026-11-14", fetchFn: network.fetchFn, now: 1000 }), "done");
  assert.equal(network.asked[0], "/api/workouts");
  assert.deepEqual(new Set(network.asked.slice(1)), new Set(aheadPaths("2026-11-14", [3, 4, 9])));
  assert.equal(storage.getItem(AHEAD_KEY), "2026-11-14 1000");

  const again = server();
  assert.equal(await fetchAhead({ storage, date: "2026-11-14", fetchFn: again.fetchFn, now: 1000 + AHEAD_EVERY_MS - 1 }), "skipped");
  assert.deepEqual(again.asked, []);
  assert.equal(await fetchAhead({ storage, date: "2026-11-14", fetchFn: again.fetchFn, now: 1000 + AHEAD_EVERY_MS - 1, force: true }), "done");
  // A new day's addresses are new: fetched at once.
  assert.equal(await fetchAhead({ storage, date: "2026-11-15", fetchFn: server().fetchFn, now: 1000 + AHEAD_EVERY_MS }), "done");
  // A clock set back doesn't hold it off.
  assert.equal(await fetchAhead({ storage, date: "2026-11-15", fetchFn: server().fetchFn, now: 10 }), "done");
});

test("stops when the server is out of reach, slow or wants a sign-in, and tries again a little later", async () => {
  const start = 10 * AHEAD_EVERY_MS;
  for (const network of [
    server({ down: true }),
    server({ cached: ["/api/workouts"] }),
    server({ cached: ["/api/coach?today=2026-11-14"] }),
    server({ status: { "/api/workouts": 401 } }),
    server({ status: { "/api/coach?today=2026-11-14": 401 } }),
    server({ redirected: ["/api/coach?today=2026-11-14"] }),
  ]) {
    const storage = memoryStorage();
    assert.equal(await fetchAhead({ storage, date: "2026-11-14", fetchFn: network.fetchFn, now: start }), "stopped");
    assert.equal(await fetchAhead({ storage, date: "2026-11-14", fetchFn: server().fetchFn, now: start + AHEAD_RETRY_MS - 1 }), "skipped");
    assert.equal(await fetchAhead({ storage, date: "2026-11-14", fetchFn: server().fetchFn, now: start + AHEAD_RETRY_MS }), "done");
  }
  // Once one request stops it, no more go out.
  const slow = server({ cached: ["/api/today?date=2026-11-14"] });
  await fetchAhead({ storage: memoryStorage(), date: "2026-11-14", fetchFn: slow.fetchFn });
  assert.ok(slow.asked.length <= 3, slow.asked.join(" "));
  // A session started meanwhile stops it too.
  let session = false;
  const busy = server();
  const fetchFn = async (path) => { session = busy.asked.length >= 4; return busy.fetchFn(path); };
  assert.equal(await fetchAhead({ storage: memoryStorage(), date: "2026-11-14", fetchFn, halt: () => session }), "stopped");
  assert.ok(busy.asked.length <= 6, busy.asked.join(" "));
  // A copy of the list means no network: nothing else is asked.
  const copy = server({ cached: ["/api/workouts"] });
  await fetchAhead({ storage: memoryStorage(), date: "2026-11-14", fetchFn: copy.fetchFn });
  assert.deepEqual(copy.asked, ["/api/workouts"]);
  // A workout deleted meanwhile is no reason to stop.
  assert.equal(await fetchAhead({ storage: memoryStorage(), date: "2026-11-14", fetchFn: server({ status: { "/api/workouts/4": 404 } }).fetchFn }), "done");
});

test("fetches ahead on every load where storage is blocked", async () => {
  const blocked = { getItem: () => { throw new Error("blocked"); }, setItem: () => { throw new Error("blocked"); }, removeItem: () => { throw new Error("blocked"); } };
  assert.equal(await fetchAhead({ storage: blocked, date: "2026-11-14", fetchFn: server().fetchFn }), "done");
  assert.equal(await fetchAhead({ storage: null, date: "2026-11-14", fetchFn: server().fetchFn }), "done");
});
