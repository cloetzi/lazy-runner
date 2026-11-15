import { test } from "node:test";
import assert from "node:assert/strict";
import { weekSummary, summaryLine, watching } from "../../public/js/week.js";

const session = (status, fields = {}) => ({ status, completion: null, ...fields });
const run = { id: 1, sport: "run" };
const lift = { id: 2, sport: null, workout: { id: 9 } };

test("counts strength sessions done against planned, with what ended early, was missed or skipped", () => {
  const [strength] = weekSummary({
    sessions: [session("done"), session("done", { completion: { ended_early: true } }), session("missed"), session("planned"), session("skipped")],
  });
  assert.deepEqual(strength, { kind: "strength", done: 1, of: 4, distance_m: 0, facts: ["1 ended early", "1 missed", "1 skipped"] });
  assert.deepEqual(summaryLine(strength, "km"), { count: "1 of 4", label: "strength", facts: ["1 ended early", "1 missed", "1 skipped"] });
});

test("counts a sport's activities against its routine days, and sums the distance", () => {
  const summary = weekSummary({
    activities: [{ sport: "Trail run", distance_m: 9400 }, { sport: "run", distance_m: 5200 }, { sport: "hike", distance_m: null }],
    routines: [run, lift],
    routineDays: [
      { routine_id: 1, state: "done" }, { routine_id: 1, state: "missed" }, { routine_id: 1, state: "confirmed" },
      { routine_id: 1, state: "tentative" }, { routine_id: 1, state: "skipped" },
      { routine_id: 2, state: "tentative" }, { routine_id: 2, state: "confirmed", session_id: 5 },
    ],
  });
  assert.deepEqual(summary.map((s) => s.kind), ["strength", "run", "hike"]);
  const [strength, runs, hikes] = summary;
  assert.deepEqual(strength.facts, ["1 maybe"]);
  assert.deepEqual(runs, { kind: "run", done: 2, of: 4, distance_m: 14600, facts: ["1 missed", "1 skipped", "1 maybe"] });
  assert.deepEqual(summaryLine(runs, "km"), { count: "2 of 4", label: "runs", facts: ["14.6 km", "1 missed", "1 skipped", "1 maybe"] });
  assert.deepEqual(summaryLine(hikes, "mi"), { count: "1", label: "hike", facts: [] });
});

test("says just how many when nothing more was planned", () => {
  const [runs] = weekSummary({ activities: [{ sport: "run", distance_m: 8000 }, { sport: "run", distance_m: 6000 }] });
  assert.deepEqual(summaryLine(runs, "mi"), { count: "2", label: "runs", facts: ["8.7 mi"] });
  assert.deepEqual(weekSummary({}), []);
});

test("names what the coach is watching", () => {
  assert.deepEqual(watching([{ title: "Left knee", body: "On descents" }, { title: null, body: "Sleep" }]), ["Left knee", "Sleep"]);
  assert.deepEqual(watching(), []);
});

test("leaves out warm-ups done on their own, and a strength activity on a day a session was done", () => {
  const [strength] = weekSummary({
    sessions: [
      session("done", { date: "2026-11-10", workout: { kind: "workout" } }),
      session("done", { date: "2026-11-11", workout: { kind: "warmup" } }),
      session("planned", { date: "2026-11-13", workout: { kind: "workout" } }),
    ],
    activities: [{ sport: "Strength training", date: "2026-11-10" }, { sport: "gym", date: "2026-11-12" }],
  });
  assert.deepEqual(strength, { kind: "strength", done: 2, of: 3, distance_m: 0, facts: [] });
});
