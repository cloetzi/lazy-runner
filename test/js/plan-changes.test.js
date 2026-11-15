import { test } from "node:test";
import assert from "node:assert/strict";
import {
  changeLine, undoLabel, undoName, dayChangeLines, dayNear, changeHtml, undoButton, undoRequest,
  sessionChange, routineChangeOn, changeShownOn, withoutUndo,
} from "../../public/js/plan-changes.js";

const today = "2026-11-16"; // a Monday
const change = (fields = {}) => ({
  id: 7, changed_by: "llm", agent_name: "Coach agent", item_kind: "session", title: "Session B",
  action: "moved", from_date: "2026-11-21", to_date: "2026-11-19", was: { date: "2026-11-21", position: 1 }, now: { date: "2026-11-19", position: 1 },
  reason: "Legs fresh for Sunday", undoable: true, created_at: "2026-11-16T12:00:00Z", ...fields,
});

test("names a day by its weekday in the same week, and with its month further away", () => {
  assert.equal(dayNear("2026-11-21", "2026-11-19"), "Sat 21");
  assert.equal(dayNear("2026-11-24", "2026-11-19"), "Tue Nov 24");
});

test("says who moved a session, from which day and when", () => {
  assert.equal(changeLine(change(), { today }), "Coach agent moved this from Sat 21 · today");
  assert.equal(changeLine(change({ agent_name: null }), { today: "2026-11-17" }), "Coach agent moved this from Sat 21 · yesterday");
  assert.equal(changeLine(change({ agent_name: "Trainer" }), { today }), "Trainer moved this from Sat 21 · today");
});

test("says what an agent changed on a routine, before and after", () => {
  const routine = change({
    item_kind: "routine", title: "Long run", action: "changed",
    was: { distance_m: 16000, minutes: 100, effort: "easy" }, now: { distance_m: 18000, minutes: 110, effort: "moderate" },
  });
  assert.equal(changeLine(routine, { today }), "Coach agent · changed today: 16.0 km → 18.0 km, 100 min → 110 min, Easy → Moderate");
  assert.equal(changeLine(routine, { today, unit: "mi" }), "Coach agent · changed today: 9.9 mi → 11.2 mi, 100 min → 110 min, Easy → Moderate");
  const days = change({ item_kind: "routine", action: "changed", was: { weekdays: [3] }, now: { weekdays: [2, 4] } });
  assert.equal(changeLine(days, { today }), "Coach agent · changed today: Wednesdays → Tuesdays and Thursdays");
  const ends = change({ item_kind: "routine", action: "changed", was: { ends_on: null, note: "a" }, now: { ends_on: "2026-12-20", note: "b" } });
  assert.equal(changeLine(ends, { today }), "Coach agent · changed today: ends Dec 20, the note");
});

test("names a session's changed note and parts without their values", () => {
  const note = change({ action: "changed", was: { note: "Mine", parts: null }, now: { note: "Theirs", parts: ["main"] } });
  assert.equal(changeLine(note, { today }), "Coach agent · changed today: the note, the parts");
});

test("shows nothing for a plan, a change of yours, or none", () => {
  assert.equal(changeLine(null, { today }), null);
  assert.equal(changeLine(change({ action: "planned" }), { today }), null);
  assert.equal(changeLine(change({ changed_by: "manual" }), { today }), null);
  assert.equal(changeHtml(change({ action: "planned" }), { today }), null);
});

test("an ended routine says so", () => {
  assert.equal(changeLine(change({ item_kind: "routine", action: "ended" }), { today }), "Coach agent ended this · today");
});

test("offers the button that fits, only while the change can be taken back", () => {
  assert.equal(undoLabel(change()), "Move it back");
  assert.equal(undoLabel(change({ action: "removed" })), "Put it back");
  assert.equal(undoLabel(change({ action: "changed" })), "Change it back");
  assert.equal(undoLabel(change({ action: "ended" })), "Plan it again");
  assert.equal(undoLabel(change({ action: "planned" })), null);
  assert.equal(undoLabel(change({ undoable: false })), null);
  assert.equal(undoLabel(null), null);
});

test("names the button for a screen reader by what it does", () => {
  assert.equal(undoName(change()), "Move Session B back to Sat 21");
  assert.equal(undoName(change({ action: "removed", from_date: "2026-11-21" })), "Put Session B back on Sat 21");
  assert.equal(undoName(change({ action: "changed" }), "Long run"), "Change Long run back");
});

test("a row's button carries the change's id, a sheet's closes it with undo", () => {
  assert.match(undoButton(change(), "Session B"), /type="button" data-undo="7" aria-label="Move Session B back to Sat 21">Move it back</);
  assert.match(undoButton(change(), "Session B", { sheet: true }), /value="undo"/);
  assert.equal(undoButton(change({ undoable: false }), "Session B"), "");
});

test("shows the reason given with the change, escaped", () => {
  const html = changeHtml(change({ reason: "Legs <fresh>" }), { today, tag: "p" });
  assert.match(html, /<p class="author-line">.*Coach agent moved this from Sat 21 · today/);
  assert.match(html, /<p class="change-reason">Legs &#60;fresh&#62;<\/p>/);
  assert.doesNotMatch(changeHtml(change({ reason: null }), { today }), /change-reason/);
});

test("lines a day that lost a session, with Put it back for a removal", () => {
  const removed = change({ id: 8, action: "removed", from_date: "2026-11-18", to_date: null });
  const days = dayChangeLines([change(), removed, change({ id: 9, changed_by: "manual" })], { from: "2026-11-16", to: "2026-11-22" });
  assert.deepEqual(Object.keys(days).sort(), ["2026-11-18", "2026-11-21"]);
  assert.deepEqual(days["2026-11-21"], [{ text: "Session B moved to Thu 19 by Coach agent", reason: null, undo: null }]);
  const [line] = days["2026-11-18"];
  assert.equal(line.text, "Session B removed by Coach agent");
  assert.equal(line.reason, "Legs fresh for Sunday");
  assert.equal(line.undo, removed);
  assert.match(undoButton(line.undo, undefined, { classes: "quiet small" }), /class="quiet small" type="button" data-undo="8" aria-label="Put Session B back on Wed 18">Put it back</);
});

test("offers Move it back on the line when the session went outside the days shown", () => {
  const away = change({ to_date: "2026-11-26", now: { date: "2026-11-26" } });
  const [line] = dayChangeLines([away], { from: "2026-11-16", to: "2026-11-22" })["2026-11-21"];
  assert.equal(line.text, "Session B moved to Thu Nov 26 by Coach agent");
  assert.equal(undoLabel(line.undo), "Move it back");
  assert.equal(line.reason, "Legs fresh for Sunday");
  const [gone] = dayChangeLines([{ ...away, undoable: false }], { from: "2026-11-16", to: "2026-11-22" })["2026-11-21"];
  assert.equal(gone.undo, null);
});

test("undo sends the device's day", () => {
  assert.deepEqual(undoRequest({ id: 7 }, today), { method: "POST", path: "/api/plan_changes/7/undo", body: { today } });
});

test("a session's change gives way to a change of the user's still queued", () => {
  assert.equal(sessionChange({ change: change() }).id, 7);
  assert.equal(sessionChange({ change: change(), pending: true }), null);
  assert.equal(sessionChange({}), null);
});

test("a routine's change shows on its days from the one it took effect, once a week", () => {
  const changed = { id: 3, change: change({ item_kind: "routine", action: "changed", from_date: "2026-11-18" }) };
  const days = ["2026-11-16", "2026-11-18", "2026-11-20"].map((on) => ({ routine_id: 3, on }));
  assert.equal(routineChangeOn(days[0], changed), null);
  assert.equal(routineChangeOn(days[1], changed).id, 7);
  assert.deepEqual([...changeShownOn(days, () => changed)], [days[1]]);
  const ended = { id: 3, change: change({ item_kind: "routine", action: "ended", from_date: "2026-11-20" }) };
  assert.equal(routineChangeOn(days[0], ended).id, 7);
  assert.deepEqual([...changeShownOn(days, () => ended)], [days[0]]);
  assert.equal(routineChangeOn(days[0], { id: 3, change: null }), null);
});

test("a copy kept on the device offers no undo", () => {
  assert.equal(withoutUndo(change(), true).undoable, false);
  assert.equal(withoutUndo(change(), false).undoable, true);
  assert.equal(withoutUndo(null, true), null);
});
