import { test } from "node:test";
import assert from "node:assert/strict";
import { offlineToday } from "../../public/js/offline.js";

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
