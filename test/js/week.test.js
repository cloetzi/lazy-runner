import { test } from "node:test";
import assert from "node:assert/strict";
import { weekSummary, summaryLine, watching, strengthWeekLine, nextSessionLine } from "../../public/js/week.js";

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

test("leads the Saved card with the week's strength sessions", () => {
  const workout = { kind: "workout", title: "Workout 1" };
  const sessions = [session("done", { date: "2026-11-09", workout }), session("done", { date: "2026-11-11", workout, completion: { ended_early: true } }), session("planned", { date: "2026-11-13", workout })];

  assert.equal(strengthWeekLine({ sessions }), "This week: 1 of 3 strength sessions done · 1 ended early");
  assert.equal(strengthWeekLine({ sessions: [session("done", { date: "2026-11-09", workout })] }), "This week: 1 strength session done");
  assert.equal(strengthWeekLine({ sessions: [] }), null);
});

test("says when the next workout session of the week is planned", () => {
  const w2 = { kind: "workout", title: "Workout 2" };
  const stretch = { kind: "cooldown", title: "Stretch" };
  const sessions = [
    session("done", { id: 1, date: "2026-11-11", position: 1, workout: { kind: "workout", title: "Workout 1" } }),
    session("planned", { id: 2, date: "2026-11-12", position: 1, workout: stretch }),
    session("planned", { id: 3, date: "2026-11-13", position: 1, workout: w2 }),
  ];

  assert.equal(nextSessionLine(sessions, "2026-11-11"), "Next: Workout 2, Friday");
  assert.equal(nextSessionLine(sessions, "2026-11-12"), "Next: Workout 2, tomorrow");
  assert.equal(nextSessionLine(sessions, "2026-11-13"), "Next: Workout 2, later today");
  assert.equal(nextSessionLine(sessions.slice(0, 2), "2026-11-11"), null);
  // One under way is not what comes next.
  const started = session("in_progress", { id: 4, date: "2026-11-11", position: 2, workout: { kind: "workout", title: "Workout 3" } });
  assert.equal(nextSessionLine([...sessions, started], "2026-11-11"), "Next: Workout 2, Friday");
});
