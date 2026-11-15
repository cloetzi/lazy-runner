import { test } from "node:test";
import assert from "node:assert/strict";
import {
  isoWeekday, routineTitle, weekdaysLabel, routineFacts, dayState, sameSport, withActivities, byDay, listed, moveChoices,
  confirmRequest, skipRequest, moveRequest, resetRequest, planRequest, changeRequest, endRequest, readRoutine, STATE_LABELS,
} from "../../public/js/routines.js";
import { weekOf, STATUS_LABELS } from "../../public/js/calendar.js";
import { removedActivityIds } from "../../public/js/activities.js";

const run = { id: 1, title: null, sport: "run", workout: null, weekdays: [3, 6], minutes: 40, distance_m: 8000, effort: "easy" };
const lift = { id: 2, title: null, sport: null, workout: { id: 9, title: "Strength A" }, weekdays: [5] };
const day = (fields = {}) => ({
  routine_id: 1, date: "2026-11-11", on: "2026-11-11", state: "tentative", confirmed: false, moved: false,
  session_id: null, activity_id: null, linked: false, ...fields,
});
const pendingRun = (fields = {}) => ({ id: null, client_ref: "activity:a", date: "2026-11-11", sport: "trail run", routine_id: null, routine_date: null, pending: true, ...fields });

test("counts weekdays from Monday 1, as the server does", () => {
  assert.equal(isoWeekday("2026-11-09"), 1);
  assert.equal(isoWeekday("2026-11-15"), 7);
});

test("names a routine by its title, else its workout or sport", () => {
  assert.equal(routineTitle(run), "Run");
  assert.equal(routineTitle(lift), "Strength A");
  assert.equal(routineTitle({ ...run, title: "Long run" }), "Long run");
});

test("says when a routine runs", () => {
  assert.equal(weekdaysLabel([6, 3]), "Wednesdays and Saturdays");
  assert.equal(weekdaysLabel([1, 3, 5]), "Mondays, Wednesdays and Fridays");
  assert.equal(weekdaysLabel([1, 2, 3, 4, 5]), "Weekdays");
  assert.equal(weekdaysLabel([1, 2, 3, 4, 5, 6, 7]), "Every day");
  assert.equal(weekdaysLabel([]), "Once");
  assert.deepEqual(routineFacts(run, "km"), ["Wednesdays and Saturdays", "40 min", "8.0 km", "Easy"]);
});

test("reads an open day against the device's today, and keeps done and skipped", () => {
  assert.equal(dayState(day(), "2026-11-11"), "tentative");
  assert.equal(dayState(day({ confirmed: true, state: "confirmed" }), "2026-11-11"), "confirmed");
  assert.equal(dayState(day({ confirmed: true, state: "confirmed" }), "2026-11-12"), "missed");
  assert.equal(dayState(day({ state: "missed" }), "2026-11-10"), "tentative");
  assert.equal(dayState(day({ state: "done" }), "2026-11-12"), "done");
  assert.equal(dayState(day({ state: "skipped" }), "2026-11-12"), "skipped");
  assert.equal(dayState(day({ state: "confirmed", confirmed: true, session_id: 4 }), "2026-11-12"), "confirmed");
});

test("matches sports by family, and a word in none only to itself", () => {
  assert.ok(sameSport("TrailRun", "run"));
  assert.ok(sameSport("kayak", "Kayak"));
  assert.ok(!sameSport("run", "ride"));
  assert.ok(sameSport("Cross-country ski", "ski"));
});

test("ticks a day off with an activity still in the outbox, each activity once", () => {
  const days = [day(), day({ routine_id: 3 })];
  const routines = [run, { ...run, id: 3, sport: "jog" }];
  const shown = withActivities(days, routines, [pendingRun()], "2026-11-11");

  assert.deepEqual(shown.map((d) => [d.state, d.activity_key ?? null]), [["done", "activity:a"], ["tentative", null]]);
});

test("gives an activity linked by hand to its day, and none of another sport or day", () => {
  const routines = [run];
  assert.equal(withActivities([day()], routines, [pendingRun({ sport: "ride" })], "2026-11-11")[0].state, "tentative");
  assert.equal(withActivities([day()], routines, [pendingRun({ date: "2026-11-10" })], "2026-11-11")[0].state, "tentative");
  const linked = pendingRun({ date: "2026-11-10", sport: "ride", routine_id: 1, routine_date: "2026-11-11" });
  assert.equal(withActivities([day()], routines, [linked], "2026-11-11")[0].state, "done");
});

test("opens a day again when the outbox deletes the activity that did it", () => {
  const done = day({ state: "done", activity_id: 7, confirmed: true });
  assert.deepEqual(withActivities([done], [run], [], "2026-11-11", new Set([7])).map((d) => [d.state, d.activity_id]), [["confirmed", null]]);
  assert.equal(withActivities([done], [run], [], "2026-11-11", new Set([8]))[0].state, "done");
  assert.equal(withActivities([done], [run], [pendingRun()], "2026-11-11", new Set([7]))[0].activity_key, "activity:a");
  assert.deepEqual([...removedActivityIds([{ method: "DELETE", path: "/api/activities/7" }, { method: "PATCH", path: "/api/activities/8" }])], [7]);
});

test("leaves workout routines and settled days to the server", () => {
  const shown = withActivities([day({ routine_id: 2 }), day({ state: "skipped" })], [run, lift], [pendingRun(), pendingRun({ client_ref: "b" })], "2026-11-11");
  assert.deepEqual(shown.map((d) => d.state), ["tentative", "skipped"]);
});

test("lists the days without a session or an activity of their own, by the day they show on", () => {
  const days = [day(), day({ session_id: 4, routine_id: 2 }), day({ state: "done", activity_id: 5 }), day({ on: "2026-11-12", moved: true })];
  assert.equal(listed(days).length, 2);
  assert.deepEqual(Object.keys(byDay(days)), ["2026-11-11", "2026-11-12"]);
});

test("offers to move a day within its week, from today on", () => {
  const choices = moveChoices(day(), "2026-11-11", weekOf);
  assert.deepEqual(choices.filter((c) => !c.disabled).map((c) => c.date), ["2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15"]);
});

test("sends day changes with the device's today", () => {
  assert.deepEqual(confirmRequest(day(), "2026-11-11"), { method: "PUT", path: "/api/routines/1/days/2026-11-11", body: { status: "confirmed", today: "2026-11-11" } });
  assert.equal(skipRequest(day(), "2026-11-11").body.status, "skipped");
  assert.deepEqual(moveRequest(day(), "2026-11-13", "2026-11-11").body, { status: "moved", moved_to: "2026-11-13", today: "2026-11-11" });
  assert.deepEqual(resetRequest(day(), "2026-11-11"), { method: "DELETE", path: "/api/routines/1/days/2026-11-11?today=2026-11-11" });
  assert.equal(planRequest({ sport: "run" }, "2026-11-11", true).body.confirmed, true);
  assert.equal("confirmed" in planRequest({ sport: "run" }, "2026-11-11").body, false);
  assert.equal(changeRequest(run, { title: "x" }, "2026-11-11").path, "/api/routines/1");
  assert.deepEqual(endRequest(run, "2026-11-11"), { method: "DELETE", path: "/api/routines/1?today=2026-11-11" });
});

const form = (fields = {}) => ({
  what: "sport", sport: " Run ", workoutId: "", once: false, weekdays: ["6", "3"], startsOn: "2026-11-11",
  title: "", minutes: "40", distance: "8", effort: "easy", note: "", ...fields,
});

test("reads the routine sheet as the API takes it", () => {
  assert.deepEqual(readRoutine(form(), "km"), {
    fields: { title: null, note: null, effort: "easy", sport: "Run", workout_id: null, weekdays: [3, 6], starts_on: "2026-11-11", minutes: 40, distance_m: 8000 },
    problems: [],
  });
  const once = readRoutine(form({ once: true, what: "workout", workoutId: "9", minutes: "", distance: "", effort: "" }), "km").fields;
  assert.deepEqual([once.weekdays, once.workout_id, once.sport, once.minutes, once.distance_m, once.effort], [[], 9, null, null, null, null]);
});

test("says what is missing from the routine sheet", () => {
  assert.deepEqual(readRoutine(form({ sport: " ", weekdays: [], minutes: "4.5", distance: "far" }), "mi").problems, [
    "Say what you'll do, such as run.", "Pick at least one day of the week.", "Give the time as whole minutes.", "Give the distance as a number of mi.",
  ]);
  assert.deepEqual(readRoutine(form({ what: "workout" }), "km").problems, ["Pick a workout."]);
});

test("routine days and sessions read in one vocabulary", () => {
  assert.deepEqual(Object.values(STATE_LABELS), ["Maybe", "Planned", "Done", "Skipped", "Missed"]);
  for (const state of ["done", "skipped", "missed"]) assert.equal(STATE_LABELS[state], STATUS_LABELS[state]);
  assert.equal(STATE_LABELS.confirmed, STATUS_LABELS.planned);
});
