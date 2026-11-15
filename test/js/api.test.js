import { test } from "node:test";
import assert from "node:assert/strict";
import { getJson, errorMessage, loadProblem, NEEDS_CONNECTION, offline, paths, send, sendChange, unreachable } from "../../public/js/api.js";

const answer = (body, init = {}) => async () => Response.json(body, init);

test("returns the data, fresh from the server", async () => {
  const result = await getJson("/api/workouts", answer([1, 2]));

  assert.deepEqual(result, { data: [1, 2], stale: false });
});

test("marks a copy from the service worker's cache as stale", async () => {
  const result = await getJson("/api/workouts", answer([1], { headers: { "x-served-from": "cache" } }));

  assert.deepEqual(result, { data: [1], stale: true });
});

test("throws on an error answer", async () => {
  await assert.rejects(getJson("/api/workouts", answer({}, { status: 503 })), /HTTP 503/);
  await assert.rejects(
    getJson("/api/today", answer({ error: { code: "no_workouts", message: "nothing yet" } }, { status: 404 })),
    (error) => error.status === 404 && error.code === "no_workouts",
  );
});

test("asks for the given path", async () => {
  let asked;
  await getJson("/api/history", async (path) => { asked = path; return Response.json({}); });

  assert.equal(asked, "/api/history");
});

test("errorMessage reads the message of an API error", () => {
  assert.equal(errorMessage({ error: { code: "not_found", message: "Workout 9 not found" } }, 404), "Workout 9 not found");
  assert.equal(errorMessage(undefined, 502), "HTTP 502");
  assert.equal(errorMessage({ error: { code: "invalid" } }, 422), "HTTP 422");
});

test("send writes JSON, and asks for JSON back", async () => {
  let asked;
  await send("/api/settings", { method: "PATCH", body: { unit: "kg" }, fetchFn: async (path, init) => { asked = { path, init }; return Response.json({}); } });

  assert.equal(asked.path, "/api/settings");
  assert.equal(asked.init.method, "PATCH");
  assert.equal(asked.init.body, '{"unit":"kg"}');
  assert.deepEqual(asked.init.headers, { "Content-Type": "application/json", Accept: "application/json" });
});

test("send posts without a body when given none", async () => {
  let asked;
  await send("/api/auth/logout", { fetchFn: async (path, init) => { asked = init; return Response.json({}); } });

  assert.equal(asked.method, "POST");
  assert.equal(asked.body, undefined);
  assert.deepEqual(asked.headers, { Accept: "application/json" });
});

test("sendChange answers null once saved, else the problem to show", async () => {
  const answer = (status, body) => async () => ({ ok: status < 300, status, json: async () => body });
  assert.equal(await sendChange({ method: "POST", path: "/api/goals", body: {} }, answer(201, {})), null);
  assert.equal(await sendChange({ method: "POST", path: "/api/goals" }, answer(422, { error: { message: "Title can't be blank" } })), "Title can't be blank");
  assert.equal(await sendChange({ method: "DELETE", path: "/api/goals/1" }, async () => { throw new TypeError("offline"); }), "Can't reach the server. Try again once you're online.");
});

test("tells no answer at all apart from an error answer", async () => {
  await assert.rejects(getJson("/api/calendar", async () => { throw new TypeError("Failed to fetch"); }), (error) => error.unreachable === true);
  await assert.rejects(getJson("/api/calendar", answer({}, { status: 404 })), (error) => !error.unreachable && error.status === 404);
});

test("puts a page it couldn't load in words, saying when it is offline with no copy", () => {
  const unreachable = Object.assign(new Error("Failed to fetch"), { unreachable: true });
  const away = { onLine: false };
  assert.equal(loadProblem("the calendar", unreachable, { nav: away }),
    "You're offline, and this device has no copy of the calendar yet. Today and your workouts still work offline.");
  assert.equal(loadProblem("the workouts", unreachable, { nav: away, hint: false }), "You're offline, and this device has no copy of the workouts yet.");
  // Online by the browser's lights, but no answer, or a proxy's for a server that is down.
  const down = Object.assign(new Error("HTTP 502"), { status: 502 });
  assert.match(loadProblem("the coach board", unreachable, { nav: { onLine: true } }), /^Can't reach the server, and this device has no copy of the coach board yet\./);
  assert.match(loadProblem("the coach board", down, { nav: { onLine: true } }), /^Can't reach the server/);
  // The app's own refusal is said as it was.
  assert.equal(loadProblem("this workout", Object.assign(new Error("HTTP 404"), { status: 404 })), "Could not load this workout (HTTP 404).");
});

test("counts no answer, or a proxy's for a server that is down, as unreachable", () => {
  assert.equal(unreachable({ unreachable: true }), true);
  assert.equal(unreachable({ status: 503 }), true);
  assert.equal(unreachable({ status: 500 }), false);
  assert.equal(unreachable(undefined), false);
});

test("says a change that isn't queued needs a connection, while offline", async () => {
  const navigator = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  Object.defineProperty(globalThis, "navigator", { value: { onLine: false }, configurable: true });
  try {
    assert.equal(offline(), true);
    assert.equal(await sendChange({ method: "POST", path: "/api/coach/notes", body: {} }, async () => { throw new TypeError("offline"); }),
      "You're offline, and this needs a connection. Try again once you're back online.");
    assert.match(NEEDS_CONNECTION, /^You're offline, and this needs a connection to save\./);
  } finally {
    if (navigator) Object.defineProperty(globalThis, "navigator", navigator);
    else delete globalThis.navigator;
  }
  assert.equal(offline({ onLine: true }), false);
  assert.equal(offline(undefined), false);
});

test("builds each page's address the one way, for what is fetched ahead to match", () => {
  assert.equal(paths.today({ date: "2026-11-14" }), "/api/today?date=2026-11-14");
  assert.equal(paths.today({ date: "2026-11-14", workoutId: 3, sessionId: 9 }), "/api/today?date=2026-11-14&workout_id=3");
  assert.equal(paths.today({ date: "2026-11-14", sessionId: 9 }), "/api/today?date=2026-11-14&session_id=9");
  assert.equal(paths.calendar({ from: "2026-11-09", to: "2026-11-15", today: "2026-11-14" }), "/api/calendar?from=2026-11-09&to=2026-11-15&today=2026-11-14");
  // Under way since yesterday counts too.
  assert.equal(paths.upcoming("2026-11-14"), "/api/sessions?status=planned,in_progress&from=2026-11-13");
  assert.equal(paths.coach("2026-11-14"), "/api/coach?today=2026-11-14");
  assert.equal(paths.history("2026-11-14"), "/api/history?days=28&date=2026-11-14");
  assert.equal(paths.workout(4), "/api/workouts/4");
});
