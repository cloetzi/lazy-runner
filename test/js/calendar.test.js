import { test } from "node:test";
import assert from "node:assert/strict";
import {
  isDate, addDays, mondayOf, weekOf, monthWeeks, addMonths, rangeFor, dayName, shortDay, weekdayDay, longDay, localToday, weekLabel, monthLabel,
  shownStatus, movable, upNext, markFor, byDay, plannable, moveChoices, sessionPath,
  planRequest, moveRequest, skipSessionRequest, removeRequest, withQueued,
} from "../../public/js/calendar.js";

const TODAY = "2026-10-28"; // a Wednesday
const legs = { id: 7, title: "Session A", kind: "workout", estimated_minutes: 25, slug: "a" };
const session = (overrides = {}) => ({
  id: 40, client_ref: null, date: TODAY, position: 1, status: "planned", note: null,
  workout: { id: 7, title: "Session A" }, ...overrides,
});

test("counts days across months, years and a change of clocks", () => {
  assert.equal(addDays("2026-10-31", 1), "2026-11-01");
  assert.equal(addDays("2026-12-31", 1), "2027-01-01");
  assert.equal(addDays("2026-03-08", 1), "2026-03-09");
  assert.equal(addDays("2026-11-01", -7), "2026-10-25");
});

test("knows a real date from text that only looks like one", () => {
  assert.equal(isDate("2026-10-28"), true);
  assert.equal(isDate("2026-02-30"), false);
  assert.equal(isDate("next week"), false);
  assert.equal(isDate(undefined), false);
});

test("starts weeks on Monday", () => {
  assert.equal(mondayOf(TODAY), "2026-10-26");
  assert.equal(mondayOf("2026-10-26"), "2026-10-26");
  assert.equal(mondayOf("2026-11-01"), "2026-10-26"); // a Sunday
  assert.deepEqual(weekOf(TODAY), ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01"]);
});

test("lays a month out in whole weeks", () => {
  const weeks = monthWeeks(TODAY);
  assert.equal(weeks.length, 5);
  assert.equal(weeks[0][0], "2026-09-28");
  assert.equal(weeks.at(-1).at(-1), "2026-11-01");
  assert.ok(weeks.every((week) => week.length === 7));
  // February 2027 starts on a Monday and ends on a Sunday: four rows.
  assert.equal(monthWeeks("2027-02-10").length, 4);
});

test("steps months, keeping to the shorter month's last day", () => {
  assert.equal(addMonths("2026-10-28", 1), "2026-11-28");
  assert.equal(addMonths("2026-01-31", 1), "2026-02-28");
  assert.equal(addMonths("2026-01-15", -1), "2025-12-15");
});

test("asks for the week or the month grid shown", () => {
  assert.deepEqual(rangeFor("week", TODAY), { from: "2026-10-26", to: "2026-11-01" });
  assert.deepEqual(rangeFor("month", TODAY), { from: "2026-09-28", to: "2026-11-01" });
});

test("names days and weeks", () => {
  assert.equal(dayName(TODAY, TODAY), "Today");
  assert.equal(dayName("2026-10-29", TODAY), "Tomorrow");
  assert.equal(dayName("2026-10-27", TODAY), "Yesterday");
  assert.equal(dayName("2026-10-30", TODAY), "Friday");
  assert.equal(shortDay("2026-11-01"), "Nov 1");
  assert.equal(weekdayDay(TODAY), "Wed 28");
  assert.equal(longDay(TODAY), "Wednesday, Oct 28");
  assert.equal(localToday(new Date(2026, 9, 28, 23, 30)), TODAY);
  assert.equal(weekLabel(TODAY, TODAY), "Oct 26 – Nov 1");
  assert.equal(weekLabel("2027-01-06", TODAY), "Jan 4 – Jan 10, 2027");
  assert.equal(monthLabel(TODAY), "October 2026");
});

test("reads a planned session before today as missed, and as planned again once moved", () => {
  assert.equal(shownStatus(session({ date: "2026-10-27" }), TODAY), "missed");
  assert.equal(shownStatus(session({ status: "missed", date: TODAY }), TODAY), "planned");
  assert.equal(shownStatus(session({ status: "done", date: "2026-10-27" }), TODAY), "done");
});

test("moves only planned and missed sessions", () => {
  assert.equal(movable(session()), true);
  assert.equal(movable(session({ status: "missed" })), true);
  for (const status of ["in_progress", "done", "skipped"]) assert.equal(movable(session({ status })), false);
});

test("puts a session under way up next, else the first planned from today on", () => {
  const missed = session({ id: 1, date: "2026-10-27", status: "missed" });
  const later = session({ id: 2, date: "2026-10-30" });
  const first = session({ id: 3, date: TODAY, position: 2 });
  const done = session({ id: 4, date: TODAY, position: 1, status: "done" });
  assert.equal(upNext([later, missed, first, done], TODAY).id, 3);
  assert.equal(upNext([later, session({ id: 5, date: TODAY, position: 2, status: "in_progress" }), first], TODAY).id, 5);
  // One started days ago and left is not what comes next.
  assert.equal(upNext([later, session({ id: 6, date: "2026-10-26", status: "in_progress" })], TODAY).id, 2);
  assert.equal(upNext([missed, done], TODAY), null);
});

test("marks the session up next apart from the other planned ones", () => {
  const next = session({ id: 3 });
  assert.equal(markFor(next, TODAY, next), "next");
  assert.equal(markFor(session({ id: 9 }), TODAY, next), "planned");
  assert.equal(markFor(session({ id: 9, date: "2026-10-20" }), TODAY, next), "missed");
  assert.equal(markFor(session({ id: 9, status: "skipped" }), TODAY, null), "skipped");
});

test("groups sessions by day, in order", () => {
  const days = byDay([session({ id: 2, position: 2 }), session({ id: 3, date: "2026-10-29" }), session({ id: 1 })]);
  assert.deepEqual(Object.keys(days), [TODAY, "2026-10-29"]);
  assert.deepEqual(days[TODAY].map((s) => s.id), [1, 2]);
});

test("plans and moves to today or later only", () => {
  assert.equal(plannable(TODAY, TODAY), true);
  assert.equal(plannable("2026-10-27", TODAY), false);
  const choices = moveChoices(session({ date: "2026-10-30" }), TODAY);
  assert.deepEqual(choices.filter((c) => !c.disabled).map((c) => c.date), ["2026-10-28", "2026-10-29", "2026-10-31", "2026-11-01"]);
  // A missed session from last week picks from this week; one further out from its own.
  assert.equal(moveChoices(session({ date: "2026-10-20" }), TODAY)[0].date, "2026-10-26");
  assert.equal(moveChoices(session({ date: "2026-11-11" }), TODAY)[0].date, "2026-11-09");
  assert.ok(moveChoices(session({ date: "2026-11-11" }), TODAY).every((c) => c.disabled === (c.date === "2026-11-11")));
});

test("names a session by its id, or by its create until it has one", () => {
  assert.equal(sessionPath(session()), "/api/sessions/40");
  assert.equal(sessionPath(session({ id: null, client_ref: "plan:a1" })), "/api/sessions/{plan:a1}");
});

test("plans a workout last on its day, under a name later changes can use", () => {
  assert.deepEqual(planRequest({ workout: legs, date: "2026-10-30", note: "  Easy legs  ", id: "a1", today: TODAY }), {
    method: "POST", path: "/api/sessions", saveAs: "plan:a1",
    body: { workout_id: 7, date: "2026-10-30", today: TODAY, status: "planned", created_by: "manual", client_ref: "plan:a1", note: "Easy legs" },
    workout: { id: 7, title: "Session A", kind: "workout", estimated_minutes: 25 },
  });
  assert.equal("note" in planRequest({ workout: legs, date: TODAY, note: " ", id: "a2" }).body, false);
});

test("moves, skips and removes through the session's path", () => {
  const planned = session({ id: null, client_ref: "plan:a1" });
  assert.deepEqual(moveRequest(planned, "2026-10-31", TODAY), { method: "PATCH", path: "/api/sessions/{plan:a1}", body: { date: "2026-10-31", today: TODAY } });
  assert.equal(moveRequest(planned, "2026-10-31").body.today, localToday());
  assert.deepEqual(skipSessionRequest(session()), { method: "PATCH", path: "/api/sessions/40", body: { status: "skipped" } });
  assert.deepEqual(removeRequest(session()), { method: "DELETE", path: "/api/sessions/40?only=planned" });
});

test("shows a plan made offline, and a move of it, before the server has them", () => {
  const sessions = [session({ id: 40, date: "2026-10-30" })];
  const plan = planRequest({ workout: legs, date: "2026-10-30", note: "Before the long run", id: "a1" });
  const shown = withQueued(sessions, [plan], TODAY);
  assert.deepEqual(shown.map((s) => [s.id, s.date, s.position, s.pending ?? false]), [[40, "2026-10-30", 1, false], [null, "2026-10-30", 2, true]]);
  assert.equal(shown[1].note, "Before the long run");
  assert.equal(shown[1].workout.title, "Session A");

  const moved = withQueued(sessions, [plan, moveRequest(shown[1], "2026-10-31")], TODAY);
  assert.deepEqual(moved.map((s) => [s.date, s.position]), [["2026-10-30", 1], ["2026-10-31", 1]]);
});

test("applies queued moves, skips and removals, closing the gaps they leave", () => {
  const sessions = [
    session({ id: 1, date: "2026-10-27", status: "missed" }),
    session({ id: 2, date: TODAY, position: 1 }),
    session({ id: 3, date: TODAY, position: 2 }),
    session({ id: 4, date: "2026-10-29" }),
  ];
  const queue = [
    moveRequest(sessions[0], TODAY),
    removeRequest(sessions[1]),
    skipSessionRequest(sessions[3]),
    { method: "POST", path: "/api/sessions/{session:x}/sets", body: {} },
  ];
  const shown = withQueued(sessions, queue, TODAY);
  assert.deepEqual(shown.map((s) => [s.id, s.date, s.position, s.status]), [
    [3, TODAY, 1, "planned"], [1, TODAY, 2, "planned"], [4, "2026-10-29", 1, "skipped"],
  ]);
  assert.equal(sessions[0].date, "2026-10-27", "leaves the sessions it was given as they were");
});

test("does not show a plan twice once the server has it", () => {
  const plan = planRequest({ workout: legs, date: TODAY, id: "a1" });
  const shown = withQueued([session({ id: 41, client_ref: "plan:a1" })], [plan, moveRequest({ id: null, client_ref: "plan:a1" }, "2026-10-30")], TODAY);
  assert.deepEqual(shown.map((s) => [s.id, s.date]), [[41, "2026-10-30"]]);
});
