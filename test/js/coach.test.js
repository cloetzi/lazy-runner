import { test } from "node:test";
import assert from "node:assert/strict";
import {
  authorLabel, authorBadge, agentName, plannedBy, writtenDay, knownCoaches, weekDays, notesByDay, notesAbout, howItFelt, journalPath, tidyRequest, noteFields, goalFields,
  noteRequest, changeNoteRequest, resolveRequest, reopenRequest, deleteNoteRequest,
  addGoalRequest, changeGoalRequest, acceptRequest, dismissRequest, movedPosition,
} from "../../public/js/coach.js";

const note = (fields = {}) => ({ id: 1, kind: "note", title: null, body: "Easy week", author_kind: "user", author_name: null, date: null, created_at: "2026-11-03T08:00:00Z", ...fields });

test("names who wrote a note: you, the coach, or the agent", () => {
  assert.equal(authorLabel(note()), "You");
  assert.equal(authorLabel(note({ author_kind: "human", author_name: "Mara" })), "Mara");
  assert.equal(authorLabel(note({ author_kind: "llm" })), "Coach agent");
  assert.equal(authorLabel(note({ author_kind: "llm", author_name: "Claude" })), "Claude");
});

test("badges a note with a person, the agent's icon, or a named coach's initials", () => {
  assert.deepEqual(authorBadge(note()), { icon: "person" });
  assert.deepEqual(authorBadge(note({ author_kind: "llm", author_name: "Claude" })), { icon: "agent" });
  assert.deepEqual(authorBadge(note({ author_kind: "human", author_name: "Mara van Keller" })), { initials: "MK" });
  assert.deepEqual(authorBadge(note({ author_kind: "human", author_name: "Mara" })), { initials: "MA" });
  assert.deepEqual(authorBadge(note({ author_kind: "human", author_name: "Dana (physio)" })), { initials: "DP" });
  assert.deepEqual(authorBadge(note({ author_kind: "human", author_name: "(?)" })), { initials: "?" });
  assert.deepEqual(authorBadge(note({ author_kind: "human", author_name: "दीपा शर्मा" })), { initials: "दीश" });
  assert.deepEqual(authorBadge(note({ author_kind: "human", author_name: "Émile" })), { initials: "ÉM" });
});

test("names the agent by what it wrote, else Coach agent", () => {
  assert.equal(agentName({ agent_name: "Claude" }), "Claude");
  assert.equal(agentName({ agent_name: null }), "Coach agent");
});

test("says when something was written: today, yesterday or the day", () => {
  const today = "2026-11-14";
  assert.equal(writtenDay(`${today}T12:00:00`, today), "today");
  assert.equal(writtenDay("2026-11-13T12:00:00", today), "yesterday");
  assert.equal(writtenDay("2026-11-02T12:00:00", today), "Nov 2");
  assert.equal(writtenDay("2025-11-02T12:00:00", today), "Nov 2, 2025");
});

test("marks what someone else planned, and leaves yours unmarked", () => {
  const today = "2026-11-14";
  assert.equal(plannedBy({ created_by: "manual", created_at: `${today}T08:00:00` }, today), null);
  assert.equal(plannedBy({ created_by: "seed" }, today), null);
  assert.equal(plannedBy({ created_by: "llm", agent_name: "Claude", created_at: `${today}T08:00:00` }, today), "Claude · planned today");
  assert.equal(plannedBy({ created_by: "llm", agent_name: null, created_at: "2026-11-10T08:00:00" }, today), "Coach agent · planned Nov 10");
  assert.equal(plannedBy({ created_by: "llm", agent_name: "Claude", created_at: `${today}T08:00:00`, routine_id: 3 }, today), "Planned by Claude");
  assert.equal(plannedBy(null, today), null);
});


test("lists the coaches named so far, latest first, once each", () => {
  const notes = [
    note({ id: 1, author_kind: "human", author_name: "Mara" }),
    note({ id: 2, author_kind: "human", author_name: "Jo" }),
    note({ id: 3, author_kind: "human", author_name: "Mara" }),
    note({ id: 4 }),
  ];
  assert.deepEqual(knownCoaches(notes), ["Mara", "Jo"]);
});

test("lays the week out Monday to Sunday with what is on each day", () => {
  const days = weekDays({
    from: "2026-11-02", to: "2026-11-08",
    sessions: [{ id: 1, date: "2026-11-04", status: "planned", position: 1 }], activities: [{ id: 2, date: "2026-11-02" }], notes: [note({ date: "2026-11-04" })],
  }, "2026-11-03");
  assert.deepEqual(days.map((d) => d.date), ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08"]);
  assert.equal(days[0].activities.length, 1);
  assert.equal(days[2].sessions[0].mark, "next");
  assert.equal(days[2].notes.length, 1);
  assert.deepEqual(days[1], { date: "2026-11-03", sessions: [], routineDays: [], activities: [], notes: [] });
});

test("puts the planned runs on the week, and a run that ticked its day off once, as the run", () => {
  const routines = [{ id: 7, sport: "running", title: "Easy run", weekdays: [1, 3] }];
  const days = weekDays({
    from: "2026-11-02", to: "2026-11-08", sessions: [], notes: [],
    activities: [{ id: 2, date: "2026-11-02", sport: "running" }],
    routines,
    routine_days: [
      { routine_id: 7, on: "2026-11-02", state: "done", activity_id: 2 },
      { routine_id: 7, on: "2026-11-04", state: "tentative" },
      { routine_id: 7, on: "2026-11-06", state: "tentative" },
    ],
  }, "2026-11-05");
  assert.deepEqual(days[0].routineDays, []);
  assert.equal(days[0].activities[0].fulfils.id, 7);
  // Read on the device's today: Wednesday's has gone by, Friday's is ahead.
  assert.equal(days[2].routineDays[0].day.state, "missed");
  assert.equal(days[4].routineDays[0].day.state, "tentative");
  assert.equal(days[4].routineDays[0].routine.id, 7);
});

test("puts dated notes under their day, in the order written", () => {
  const days = notesByDay([note({ id: 2, date: "2026-11-03" }), note({ id: 1, date: "2026-11-03" }), note({ id: 3 })]);
  assert.deepEqual(Object.keys(days), ["2026-11-03"]);
  assert.deepEqual(days["2026-11-03"].map((n) => n.id), [1, 2]);
});

test("puts a note about a session or activity on its day, wherever it is now", () => {
  const moved = note({ id: 4, date: "2026-11-03", about: { type: "session", id: 9, date: "2026-11-05" } });
  const days = notesByDay([moved, note({ id: 5, about: { type: "activity", id: 2, date: "2026-11-02" } })]);
  assert.deepEqual(Object.keys(days).sort(), ["2026-11-02", "2026-11-05"]);
  // A move still queued takes the note along.
  assert.deepEqual(Object.keys(notesByDay([moved], [{ id: 9, date: "2026-11-06" }])), ["2026-11-06"]);
  assert.deepEqual(notesAbout([moved, note({ id: 6, about: { type: "session", id: 9, date: "2026-11-05" } }), note({ id: 7 })], "session", 9).map((n) => n.id), [6, 4]);
  assert.deepEqual(notesAbout([moved], "session", null), []);
});

test("says how a done session felt", () => {
  assert.equal(howItFelt({ rpe: 8, feedback: "too_hard", ended_early: true }), "RPE 8 · too hard · ended early");
  assert.equal(howItFelt({ rpe: null, feedback: "right", ended_early: false }), "felt right");
  assert.equal(howItFelt(null), "");
});

test("pages the journal under a filter, statuses and focus left to their own line", () => {
  assert.equal(journalPath("all"), "/api/coach/notes?journal=true&limit=20&kind=note,concern");
  assert.equal(journalPath("coach", 41), "/api/coach/notes?journal=true&limit=20&kind=note,concern&author=human,llm&before=41");
  assert.equal(journalPath("nonsense"), journalPath("all"));
  assert.deepEqual(tidyRequest("2026-11-01"), { method: "POST", path: "/api/coach/tidy", body: { before: "2026-11-01" } });
});

test("reads the note form: blanks left out of a new note, cleared on an edit", () => {
  assert.deepEqual(noteFields({ kind: "note", body: " Felt easy ", about: "activity:3" }), {
    fields: { kind: "note", body: "Felt easy", activity_id: 3, author_kind: "user" }, problems: [],
  });
  assert.deepEqual(noteFields({ kind: "note", body: "Felt easy" }, { editing: true }).fields, {
    kind: "note", title: null, body: "Felt easy", date: null, activity_id: null, session_id: null, author_kind: "user", author_name: null,
  });
  assert.deepEqual(noteFields({ kind: "status", body: "Week 3", author: "Mara", date: "2026-11-03", about: "session:9" }).fields, {
    kind: "status", body: "Week 3", date: "2026-11-03", session_id: 9, author_kind: "human", author_name: "Mara",
  });
  assert.equal(noteFields({ kind: "note", body: "Hi", author: "other", authorName: " Jo " }).fields.author_name, "Jo");
});

test("says what a note needs before it can be sent", () => {
  assert.deepEqual(noteFields({ kind: "concern", body: " " }).problems, ["Write something.", "Give the concern a short title."]);
  assert.deepEqual(noteFields({ kind: "note", body: "Hi", author: "other", authorName: "" }).problems, ["Name the coach who wrote it."]);
  assert.deepEqual(noteFields({ kind: "mood", body: "Hi" }).problems, ["Pick what kind of note it is."]);
});

test("reads the goal form", () => {
  assert.deepEqual(goalFields({ title: " Ski season ", why: "", target_date: "2026-12-15" }), {
    fields: { title: "Ski season", why: null, target_date: "2026-12-15" }, problems: [],
  });
  assert.deepEqual(goalFields({ title: "" }).problems, ["Name the goal."]);
});

test("builds the requests for notes and goals", () => {
  assert.deepEqual(noteRequest({ kind: "note", body: "Hi" }), { method: "POST", path: "/api/coach/notes", body: { kind: "note", body: "Hi" } });
  assert.deepEqual(changeNoteRequest({ id: 4 }, { body: "Hey" }), { method: "PATCH", path: "/api/coach/notes/4", body: { body: "Hey" } });
  assert.deepEqual(resolveRequest({ id: 4 }, " gone "), { method: "PATCH", path: "/api/coach/notes/4", body: { resolved: true, resolution: "gone" } });
  assert.deepEqual(resolveRequest({ id: 4 }, ""), { method: "PATCH", path: "/api/coach/notes/4", body: { resolved: true, resolution: null } });
  assert.deepEqual(reopenRequest({ id: 4 }).body, { resolved: false });
  assert.deepEqual(deleteNoteRequest({ id: 4 }), { method: "DELETE", path: "/api/coach/notes/4" });
  assert.deepEqual(addGoalRequest({ title: "Ski" }), { method: "POST", path: "/api/goals", body: { title: "Ski" } });
  assert.deepEqual(changeGoalRequest({ id: 2 }, { status: "achieved" }), { method: "PATCH", path: "/api/goals/2", body: { status: "achieved" } });
  assert.deepEqual(acceptRequest({ id: 2 }), { method: "POST", path: "/api/goals/2/accept" });
  assert.deepEqual(dismissRequest({ id: 2 }), { method: "POST", path: "/api/goals/2/dismiss" });
});

test("moves a goal a place up or down, not past either end", () => {
  const goals = [{ id: 5 }, { id: 6 }, { id: 7 }];
  assert.equal(movedPosition(goals, 6, -1), 1);
  assert.equal(movedPosition(goals, 6, 1), 3);
  assert.equal(movedPosition(goals, 5, -1), null);
  assert.equal(movedPosition(goals, 7, 1), null);
});
