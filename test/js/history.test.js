import { test } from "node:test";
import assert from "node:assert/strict";
import { setsSummary, sessionSummary, exerciseSummary } from "../../public/js/history.js";

const lb = (value) => ({ value, unit: "lb" });
const set = (set_number, reps, weight = null, extra = {}) => ({ set_number, side: null, reps, seconds: null, weight, ...extra });

test("counts equal sets at one weight", () => {
  assert.equal(setsSummary([set(1, 8, lb(35)), set(2, 8, lb(35)), set(3, 8, lb(35))]), "3 × 8 @ 35 lb");
});

test("lists reps that differ", () => {
  assert.equal(setsSummary([set(1, 8, lb(40)), set(2, 8, lb(40)), set(3, 6, lb(40))]), "8, 8, 6 @ 40 lb");
});

test("gives each weight used its own part", () => {
  assert.equal(setsSummary([set(1, 8, lb(35)), set(2, 8, lb(40)), set(3, 6, lb(40))]), "8 @ 35 lb · 8, 6 @ 40 lb");
});

test("leaves the weight out for bodyweight sets", () => {
  assert.equal(setsSummary([set(1, 12), set(2, 12)]), "2 × 12");
});

test("reads timed sets in seconds", () => {
  assert.equal(setsSummary([set(1, null, null, { seconds: 30 }), set(2, null, null, { seconds: 25 })]), "30 s, 25 s");
});

test("puts the two sides of a set together", () => {
  const sides = (n, left, right) => [set(n, left, lb(20), { side: "left" }), set(n, right, lb(20), { side: "right" })];
  assert.equal(setsSummary([...sides(1, 8, 8), ...sides(2, 8, 8)]), "2 × 8 each side @ 20 lb");
  assert.equal(setsSummary([...sides(1, 8, 8), ...sides(2, 8, 7)]), "8, 8/7 @ 20 lb");
});

test("shows the weights in the chosen unit", () => {
  assert.equal(setsSummary([set(1, 8, lb(40)), set(2, 8, lb(40))], "kg"), "2 × 8 @ 18 kg");
  assert.equal(setsSummary([set(1, 8, lb(40)), set(2, 8, { value: 18, unit: "kg" })], "kg"), "2 × 8 @ 18 kg");
});

test("sums up a finished session by its length and how it felt", () => {
  const session = { status: "done", minutes: 26, sets_done: 18, completion: { feedback: "right", rpe: 6 } };
  assert.equal(sessionSummary(session), "26 min · felt right · RPE 6");
});

test("falls back to the set count and says when a session is not done", () => {
  assert.equal(sessionSummary({ status: "in_progress", minutes: null, sets_done: 1, completion: null }), "in progress · 1 set");
  assert.equal(sessionSummary({ status: "done", sets_done: 12, completion: { feedback: "too_hard" } }), "12 sets · too hard");
});

test("splits an exercise of a past session into what was done and what was skipped", () => {
  const sets = [set(1, 8, lb(40), { status: "done" }), set(2, 7, lb(40), { status: "done" }), set(3, null, null, { status: "skipped" })];
  assert.deepEqual(exerciseSummary({ sets }, "lb"), { done: "8, 7 @ 40 lb", skipped: 1 });
  assert.deepEqual(exerciseSummary({ sets: [set(1, null, null, { status: "skipped" })] }, "lb"), { done: "", skipped: 1 });
});

test("counts a skipped per-side set once", () => {
  const sets = ["left", "right"].map((side) => set(1, null, null, { side, status: "skipped" }));
  assert.deepEqual(exerciseSummary({ sets }, "lb"), { done: "", skipped: 1 });
});

test("says when a session was ended early", () => {
  assert.equal(sessionSummary({ status: "done", minutes: 4, completion: { ended_early: true } }), "ended early · 4 min");
});

test("reads a hold ended early against its target", () => {
  const hold = (n, seconds) => set(n, null, null, { seconds, target: { seconds: 45 } });
  assert.equal(setsSummary([hold(1, 32), hold(2, 45)]), "32 of 45 s, 45 s");
});
