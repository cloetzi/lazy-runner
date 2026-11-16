import { test } from "node:test";
import assert from "node:assert/strict";
import { newsGroups, newsCount, hasNews, seenRequest, writtenAt } from "../../public/js/coach-news.js";

const today = "2026-11-16"; // a Monday
const at = (hour) => `2026-11-16T${String(hour).padStart(2, "0")}:35:00Z`;
const change = (fields) => ({
  id: 1, changed_by: "llm", agent_name: "Coach agent", item_kind: "session", title: "Session B", action: "planned",
  from_date: null, to_date: "2026-11-18", was: null, now: null, undoable: false, created_at: at(10), ...fields,
});

const empty = { since: at(1), latest: null, changes: [], notes: [], goals: [], activities: [] };

test("has nothing to show until an agent did something", () => {
  assert.equal(hasNews(null), false);
  assert.equal(hasNews(empty), false);
  assert.equal(newsCount(empty), 0);
  assert.deepEqual(newsGroups(empty, { today }), []);
});

test("says what each agent did, what it wrote first, the latest agent first", () => {
  const news = {
    ...empty, latest: at(11),
    changes: [
      change({ id: 5, action: "moved", from_date: "2026-11-21", to_date: "2026-11-19", was: { date: "2026-11-21" }, undoable: true, created_at: at(11) }),
      change({ id: 4, to_date: "2026-12-03", reason: "Base block." }),
      change({ id: 3, to_date: "2026-11-16", reason: "Base block." }),
      change({ id: 2, item_kind: "routine", title: "Long run", action: "changed", from_date: "2026-11-22", to_date: "2026-11-22", was: { distance_m: 16000 }, now: { distance_m: 18000 }, undoable: true, reason: "The 16 km felt easy." }),
      change({ id: 6, action: "removed", from_date: "2026-11-20", to_date: null, undoable: false, agent_name: "Trainer", created_at: at(9) }),
    ],
    notes: [{ kind: "status", author_name: "Coach agent", created_at: at(10) }, { kind: "status", author_name: "Coach agent", created_at: at(10) }, { kind: "note", author_name: "Coach agent", created_at: at(10) }, { kind: "note", author_name: "Coach agent", created_at: at(10) }],
    goals: [{ agent_name: "Coach agent", created_at: at(10) }, { agent_name: null, created_at: at(10) }],
    activities: [{ agent_name: "Coach agent", count: 8, from: "2026-10-27", to: "2026-11-15", sources: ["garmin"], created_at: at(8) }],
  };
  const groups = newsGroups(news, { today });
  assert.deepEqual(groups.map((g) => g.who), ["Coach agent", "Trainer"]);
  assert.equal(groups[0].when, writtenAt(at(11), today));
  // The goals it proposed are not said: they wait on the page until answered.
  assert.deepEqual(groups[0].items.map((i) => [i.kind, i.text]), [
    ["wrote", "Wrote 2 statuses and 2 notes"],
    ["change", "Planned 2 sessions, Nov 16 to Dec 3"],
    ["change", "Changed Long run: 16.0 km → 18.0 km"],
    ["change", "Moved Session B from Sat 21 to Thu 19"],
    ["copied", "Copied 8 activities from Garmin, Oct 27 to Nov 15"],
  ]);
  assert.deepEqual(groups[0].items.map((i) => i.href), [null, "/calendar.html#2026-11-16", "/calendar.html#2026-11-22", "/calendar.html#2026-11-19", "/calendar.html#2026-11-15"]);
  assert.deepEqual(groups[0].items.map((i) => i.undo?.id ?? null), [null, null, 2, 5, null]);
  // A change carries the reason the agent gave for it; sessions planned together say the one they share.
  assert.deepEqual(groups[0].items.map((i) => i.reason), [null, "Base block.", "The 16 km felt easy.", null, null]);
  assert.deepEqual(groups[1].items.map((i) => [i.text, i.undo]), [["Removed Session B from Fri 20", null]]);
  assert.equal(newsCount(news), 5 + 4 + 2 + 8);
});

test("sessions planned together for different reasons say none", () => {
  const groups = newsGroups({ ...empty, changes: [change({ reason: "Base block." }), change({ id: 2, to_date: "2026-11-20", reason: "Makes up for Friday." })] }, { today });
  assert.deepEqual(groups[0].items.map((i) => [i.text, i.reason]), [["Planned 2 sessions, Nov 18 to Nov 20", null]]);
});

test("one planned session or routine gets its own line", () => {
  const groups = newsGroups({ ...empty, changes: [change({}), change({ id: 2, item_kind: "routine", title: "Tempo run", to_date: "2026-11-24" })] }, { today });
  assert.deepEqual(groups[0].items.map((i) => i.text), ["Planned Tempo run from Tue Nov 24", "Planned Session B on Wed 18"]);
});

test("one of a kind reads as a or an", () => {
  const groups = newsGroups({ ...empty, notes: [{ kind: "focus", created_at: at(10) }], goals: [{ created_at: at(10) }], activities: [{ count: 1, from: "2026-11-15", to: "2026-11-15", sources: [], created_at: at(9) }] }, { today });
  assert.deepEqual(groups[0].items.map((i) => i.text), ["Wrote a focus", "Copied an activity, Nov 15"]);
});

test("an agent that only proposed goals has nothing to say: its proposals wait on the page", () => {
  const news = { ...empty, goals: [{ agent_name: "Trainer", created_at: at(10) }] };
  assert.deepEqual(newsGroups(news, { today }).map((g) => [g.who, g.items]), [["Trainer", []]]);
  assert.equal(hasNews(news), true);
  assert.equal(newsCount(news), 1);
});

test("marks it seen up to the newest thing shown", () => {
  assert.deepEqual(seenRequest({ latest: at(11) }), { method: "POST", path: "/api/coach/seen", body: { until: at(11) } });
  assert.deepEqual(seenRequest(empty), { method: "POST", path: "/api/coach/seen", body: {} });
});

test("says what an agent changed in a workout, linking to it, and the weights it set", () => {
  const news = {
    ...empty, latest: at(11),
    changes: [
      change({ id: 8, item_kind: "weight", exercise_id: 9, title: "Goblet squat", action: "changed", to_date: null, was: { value: 20, unit: "lb" }, now: { value: 25, unit: "lb" }, undoable: true, created_at: at(11) }),
      change({ id: 7, item_kind: "workout", workout_id: 3, title: "Workout 1", action: "changed", to_date: null, summary: "3 rounds in block B (was 2)", undoable: true }),
    ],
  };
  const [group] = newsGroups(news, { today, weightUnit: "lb" });
  assert.deepEqual(group.items.map((item) => [item.text, item.href, item.title, item.undo?.id ?? null]), [
    ["Changed Workout 1: 3 rounds in block B (was 2)", "/#workout/3", "Workout 1", 7],
    ["Set Goblet squat to 25 lb (was 20 lb)", null, "Goblet squat's weight", 8],
  ]);
  assert.equal(group.items[0].showLabel, "Show Workout 1");
});
