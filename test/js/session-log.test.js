import { test } from "node:test";
import assert from "node:assert/strict";
import { weightRequest, skipRequest, startRequest, setRequest, finishRequests, discardRequest } from "../../public/js/session-log.js";
import { createOutbox } from "../../public/js/outbox.js";

const squat = { id: 1, name: "Goblet squat" };
const lunge = { id: 4, name: "Reverse lunge" };
const plank = { id: 3, name: "Plank" };

const run = (overrides = {}) => ({
  id: "a1", ref: "session:a1", sessionId: null, workoutId: 2, date: "2026-10-24", parts: null,
  stage: "player", weights: {}, endedEarly: false, ...overrides,
});
const set = (overrides = {}) => ({
  type: "exercise", mode: "reps", step_id: 10, side: null, block: { label: "A", round: 2, rounds: 3 },
  exercise: squat, reps: 8, seconds: null, weight: { value: 40, unit: "lb" }, ...overrides,
});

const NOW = new Date("2026-10-24T07:30:00Z");

test("creates a new session the server can recognise when it is sent twice", () => {
  assert.deepEqual(startRequest(run({ parts: ["warmup", "workout"] }), NOW), {
    method: "POST", path: "/api/sessions", saveAs: "session:a1",
    body: {
      workout_id: 2, date: "2026-10-24", status: "in_progress", client_ref: "session:a1",
      started_at: "2026-10-24T07:30:00.000Z", parts: ["warmup", "workout"],
    },
  });
});

test("restarts the day's session when it has one, leaving parts out without framing", () => {
  assert.deepEqual(startRequest(run({ sessionId: 9 }), NOW), {
    method: "PATCH", path: "/api/sessions/{session:a1}", body: { status: "in_progress", started_at: "2026-10-24T07:30:00.000Z" },
  });
});

test("logs the round as the set number, with the reps done", () => {
  assert.deepEqual(setRequest(run(), set(), "done", { reps: 6 }), {
    method: "POST", path: "/api/sessions/{session:a1}/sets",
    body: {
      step_id: 10, set_number: 2, side: null, status: "done", weight: { value: 40, unit: "lb" }, reps: 6,
      planned_exercise_id: 1, block_label: "A", target: { reps: 8, seconds: null, weight: { value: 40, unit: "lb" } },
    },
  });
});

test("sends what the plan showed, the planned exercise's for a swap", () => {
  const planned = set();
  const swapped = set({ exercise: lunge, reps: 10, weight: { value: 20, unit: "lb" }, planned });
  const { body } = setRequest(run(), swapped, "done");

  assert.equal(body.planned_exercise_id, 1);
  assert.equal(body.exercise_id, 4);
  assert.deepEqual(body.target, { reps: 8, seconds: null, weight: { value: 40, unit: "lb" } });
});

test("uses the planned reps when none are given", () => {
  assert.equal(setRequest(run(), set(), "done").body.reps, 8);
});

test("names the exercise only for a swap", () => {
  assert.equal("exercise_id" in setRequest(run(), set(), "done").body, false);
  assert.equal(setRequest(run(), set({ exercise: lunge, planned: set() }), "done").body.exercise_id, 4);
});

test("logs seconds for a timed set and nothing done for a skipped one", () => {
  const hold = set({ mode: "timed", exercise: plank, reps: null, seconds: 45, side: "left", weight: null });

  assert.equal(setRequest(run(), hold, "done").body.seconds, 45);
  assert.equal(setRequest(run(), hold, "done", { seconds: 30 }).body.seconds, 30);
  assert.equal(setRequest(run(), hold, "done").body.side, "left");
  assert.equal(setRequest(run(), hold, "skipped").body.seconds, null);
  assert.equal(setRequest(run(), set(), "skipped").body.reps, null);
  assert.deepEqual(setRequest(run(), set(), "skipped").body.weight, { value: 40, unit: "lb" });
});

test("sends kept weight changes before the finish, and drops undone ones", () => {
  const weights = {
    1: { name: "Goblet squat", from: { value: 40, unit: "lb" }, to: { value: 50, unit: "lb" }, keep: true },
    4: { name: "Reverse lunge", from: { value: 20, unit: "lb" }, to: { value: 10, unit: "lb" }, keep: false },
  };
  const { key, requests } = finishRequests(run({ weights, endedEarly: true }), { rpe: 7, feedback: "just_right", now: NOW });

  assert.equal(key, "complete:a1");
  assert.deepEqual(requests, [
    { method: "PATCH", path: "/api/exercises/1/weight", body: { value: 50, unit: "lb" } },
    { method: "POST", path: "/api/sessions/{session:a1}/complete", saveAs: "complete:a1", body: { rpe: 7, feedback: "just_right", ended_early: true, finished_at: "2026-10-24T07:30:00.000Z" } },
  ]);
});

test("finishes without feedback", () => {
  const { requests } = finishRequests(run(), { now: NOW });
  assert.deepEqual(requests.at(-1).body, { rpe: null, feedback: null, ended_early: false, finished_at: "2026-10-24T07:30:00.000Z" });
});

test("deletes a discarded session only once the player started it", () => {
  assert.equal(discardRequest(run({ stage: "ready" })), null);
  assert.deepEqual(discardRequest(run()), { method: "DELETE", path: "/api/sessions/{session:a1}" });
  assert.deepEqual(discardRequest(run({ stage: "finish" })), { method: "DELETE", path: "/api/sessions/{session:a1}" });
});

test("skips the day's session, or creates a skipped one", () => {
  assert.deepEqual(skipRequest({ session: { id: 5 }, workout_id: 2, date: "2026-10-24" }, "x"), {
    method: "PATCH", path: "/api/sessions/5", body: { status: "skipped" },
  });
  assert.deepEqual(skipRequest({ session: null, workout_id: 2, date: "2026-10-24" }, "x"), {
    method: "POST", path: "/api/sessions", body: { workout_id: 2, date: "2026-10-24", status: "skipped", client_ref: "skip:x" },
  });
});

test("remembers a weight", () => {
  assert.deepEqual(weightRequest(3, { value: 20, unit: "kg" }), { method: "PATCH", path: "/api/exercises/3/weight", body: { value: 20, unit: "kg" } });
  assert.deepEqual(weightRequest(3, null), { method: "PATCH", path: "/api/exercises/3/weight", body: { value: null } });
});

// The whole run through a real outbox: the session id from the create fills
// in every later path, in the order the player queued them.
test("sends a run in order once the server is back", async () => {
  const items = new Map();
  const storage = { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v), removeItem: (k) => items.delete(k) };
  const calls = [];
  let online = false;
  const fetch = async (path, options) => {
    if (!online) throw new TypeError("Failed to fetch");
    calls.push(`${options.method} ${path}`);
    const json = path === "/api/sessions" ? { id: 42 } : path.endsWith("/complete") ? { suggestions: [] } : {};
    return { ok: true, status: 200, redirected: false, json: async () => json };
  };
  const outbox = createOutbox({ storage, fetch });
  const r = run({ weights: { 1: { to: { value: 50, unit: "lb" }, keep: true } } });

  outbox.enqueue(startRequest(r));
  outbox.enqueue(setRequest(r, set(), "done"));
  outbox.enqueue(setRequest(r, set({ block: { label: "A", round: 3, rounds: 3 } }), "skipped"));
  const { key, requests } = finishRequests(r, { rpe: 6 });
  requests.forEach((request) => outbox.enqueue(request));
  assert.equal(await outbox.flush(), false);

  online = true;
  assert.equal(await outbox.flush(), true);
  assert.deepEqual(calls, [
    "POST /api/sessions",
    "POST /api/sessions/42/sets",
    "POST /api/sessions/42/sets",
    "PATCH /api/exercises/1/weight",
    "POST /api/sessions/42/complete",
  ]);
  assert.deepEqual(outbox.result(key), { suggestions: [] });
});
