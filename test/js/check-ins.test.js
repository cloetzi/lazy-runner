import { test } from "node:test";
import assert from "node:assert/strict";
import {
  nightSummary, daySummary, nightTitle, dayTitle, groupFields, checkInRequest, clearRequest, withQueuedCheckIns, checkInsByDay, checkInItems,
} from "../../public/js/check-ins.js";

const today = "2026-11-21"; // a Saturday

test("sums up a night and a day in a line", () => {
  assert.equal(nightSummary({ sleep: "poor", drinks: "3+", tags: ["late_to_bed", "woke_a_lot"], note: "Birthday" }), "Slept poorly · 3+ drinks · Late to bed · Woke a lot");
  assert.equal(nightSummary({ sleep: null, drinks: "none", tags: [] }), "No drinks");
  assert.equal(nightSummary({ drinks: "1-2", tags: [] }), "1–2 drinks");
  assert.equal(nightSummary(null), "");

  assert.equal(daySummary({ feeling: "ok", stress: "high", sore: "a_bit", sore_areas: ["knees", "calves"], ill: false }), "Feeling OK · High stress · Knees, Calves a bit sore");
  assert.equal(daySummary({ feeling: "rough", stress: "normal", sore: "a_lot", sore_areas: [], ill: true }), "Feeling rough · Sore a lot · Ill");
  assert.equal(daySummary({ stress: "normal", sore: "no", sore_areas: [], ill: false }), "Normal stress · Nothing sore");
  assert.equal(daySummary({ stress: null, sore: null, sore_areas: [], ill: false, note: "Fine" }), "");
});

test("names today's night Last night, and another day's which night it was", () => {
  assert.equal(nightTitle(today, today), "Last night");
  assert.equal(nightTitle("2026-11-20", today), "Night, Thu to Fri");
  assert.equal(nightTitle("2026-11-16", today), "Night, Sun to Mon");
  assert.equal(dayTitle(today, today), "How I feel today");
  assert.equal(dayTitle("2026-11-20", today), "How I felt");
});

test("sends only what was said, and clears a group left empty", () => {
  assert.deepEqual(groupFields("night", { sleep: "good", drinks: null, tags: ["ate_late", "ate_late"], note: "  " }), { sleep: "good", tags: ["ate_late"] });
  assert.deepEqual(groupFields("day", { feeling: "ok", sore: "no", sore_areas: ["knees"], ill: false, note: " Heavy legs " }), { feeling: "ok", sore: "no", note: "Heavy legs" });
  assert.deepEqual(groupFields("day", { sore: "a_bit", sore_areas: ["knees"], ill: true }), { sore: "a_bit", sore_areas: ["knees"], ill: true });

  assert.deepEqual(checkInRequest(today, "night", { sleep: "poor", tags: [] }, today),
    { method: "PUT", path: "/api/check_ins/2026-11-21/night", body: { sleep: "poor", today } });
  assert.deepEqual(checkInRequest(today, "day", { ill: false, sore_areas: [], note: "" }, today), clearRequest(today, "day"));
  assert.deepEqual(clearRequest(today, "day"), { method: "DELETE", path: "/api/check_ins/2026-11-21/day" });
});

test("lays the queued check-ins over the server's", () => {
  const server = [
    { date: "2026-11-19", night: null, day: { feeling: "good", stress: null, sore: null, sore_areas: [], ill: false, note: null, logged_by: "manual" } },
    { date: "2026-11-20", night: { sleep: "ok", drinks: null, tags: [], note: null, logged_by: "llm" }, day: null },
  ];
  const queue = [
    checkInRequest(today, "night", { sleep: "poor", drinks: "3+" }, today),
    clearRequest("2026-11-19", "day"),
    checkInRequest("2026-11-20", "day", { stress: "high" }, today),
    { method: "POST", path: "/api/activities", body: { client_ref: "a" } },
  ];
  const shown = withQueuedCheckIns(server, queue);

  assert.deepEqual(shown.map((c) => c.date), ["2026-11-20", today]);
  assert.equal(shown[0].night.logged_by, "llm");
  assert.deepEqual(shown[0].day, { feeling: null, stress: "high", sore: null, sore_areas: [], ill: false, note: null, logged_by: "manual", pending: true });
  assert.deepEqual(shown[1].night, { sleep: "poor", drinks: "3+", tags: [], note: null, logged_by: "manual", pending: true });
  assert.equal(shown[1].day, null);
  assert.equal(server[1].day, null, "the server's copy is left as it was");
});

test("finds a day's check-in, and says what is on it in a word or two", () => {
  const list = [{ date: today, night: { sleep: "ok" }, day: { feeling: "ok" } }];
  assert.equal(checkInsByDay(list)[today], list[0]);
  assert.deepEqual(checkInItems(list[0]), ["night", "how you felt"]);
  assert.deepEqual(checkInItems({ night: null, day: { feeling: "ok" } }), ["how you felt"]);
  assert.deepEqual(checkInItems(undefined), []);
});
