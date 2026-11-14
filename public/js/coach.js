// The Coach tab's logic, kept free of the DOM so node can test it: who wrote
// a note, the week as days, what a note or goal form sends, and the
// requests for goals and notes.
//
// Goals are the user's: the app adds, edits and orders them, and accepts or
// dismisses what an agent proposed. Notes are written by the user ("You"), a
// coach they name, or an agent (over MCP, never from here).

import { weekOf, shortDay, localToday } from "./calendar.js";

export const KINDS = ["status", "focus", "concern", "note"];
export const KIND_LABELS = { status: "Status", focus: "Focus", concern: "Concern", note: "Note" };
export const AGENT_NAME = "Trainer agent";

// "You", the coach's name, or the agent's (its own name, else Trainer agent).
export function authorLabel(note) {
  if (note.author_kind === "user") return "You";
  if (note.author_kind === "llm") return note.author_name || AGENT_NAME;
  return note.author_name || "Coach";
}

// Two letters for the author's badge: ME, AI, or a name's initials.
export function authorInitials(note) {
  if (note.author_kind === "user") return "ME";
  if (note.author_kind === "llm") return "AI";
  const words = (note.author_name ?? "").trim().split(/\s+/).filter(Boolean);
  const letters = words.length > 1 ? words[0][0] + words.at(-1)[0] : (words[0] ?? "?").slice(0, 2);
  return letters.toUpperCase();
}

// The day a time was in, on this device: "2026-11-03T22:30:00Z" on a phone
// west of UTC is still the 3rd.
export function localDate(time) {
  return localToday(new Date(time));
}

// "Nov 3", the day a note was written.
export function writtenOn(note) {
  return shortDay(localDate(note.created_at));
}

// The coaches named on notes so far, for "Written by", most recent first.
export function knownCoaches(notes) {
  const names = [];
  for (const note of [...notes].sort((a, b) => b.id - a.id)) {
    if (note.author_kind === "human" && note.author_name && !names.includes(note.author_name)) names.push(note.author_name);
  }
  return names;
}

// The board's week as seven days, Monday first, each with what is on it.
export function weekDays(week) {
  return weekOf(week.from).map((date) => ({
    date,
    sessions: week.sessions.filter((s) => s.date === date),
    activities: week.activities.filter((a) => a.date === date),
    notes: week.notes.filter((n) => n.date === date),
  }));
}

// Dated notes by day: { "2026-11-03": [note, ...] }, in the order written.
export function notesByDay(notes) {
  const days = {};
  for (const note of [...notes].sort((a, b) => a.id - b.id)) {
    if (note.date) (days[note.date] ??= []).push(note);
  }
  return days;
}

// What the note form sends, from its values: blanks left out of a new note
// and cleared (null) on an edit, "about" read as activity:3 or session:9.
// `problems` says what to fix before it can be sent.
export function noteFields({ kind, title = "", body = "", date = "", about = "", author = "user", authorName = "" }, { editing = false } = {}) {
  const blank = editing ? null : undefined;
  const [aboutType, aboutId] = about ? about.split(":") : [];
  const human = author !== "user";
  const name = (author === "other" ? authorName : human ? author : "").trim();
  const fields = {
    kind,
    title: title.trim() || blank,
    body: body.trim(),
    date: date || blank,
    activity_id: aboutType === "activity" ? Number(aboutId) : blank,
    session_id: aboutType === "session" ? Number(aboutId) : blank,
    author_kind: human ? "human" : "user",
    author_name: human ? name : blank,
  };
  const problems = [
    !KINDS.includes(kind) && "Pick what kind of note it is.",
    !fields.body && "Write something.",
    kind === "concern" && !fields.title && "Give the concern a short title.",
    human && !name && "Name the coach who wrote it.",
  ].filter(Boolean);
  return { fields: Object.fromEntries(Object.entries(fields).filter(([, value]) => value !== undefined)), problems };
}

// What the goal form sends: title, why and target date, blanks cleared.
export function goalFields({ title = "", why = "", target_date = "" }) {
  const fields = { title: title.trim(), why: why.trim() || null, target_date: target_date || null };
  return { fields, problems: fields.title ? [] : ["Name the goal."] };
}

// ---------- Requests ----------

export const noteRequest = (fields) => ({ method: "POST", path: "/api/coach/notes", body: fields });
export const changeNoteRequest = (note, changes) => ({ method: "PATCH", path: `/api/coach/notes/${note.id}`, body: changes });
export const resolveRequest = (note, resolution) => changeNoteRequest(note, { resolved: true, resolution: resolution?.trim() || null });
export const reopenRequest = (note) => changeNoteRequest(note, { resolved: false });
export const deleteNoteRequest = (note) => ({ method: "DELETE", path: `/api/coach/notes/${note.id}` });

export const addGoalRequest = (fields) => ({ method: "POST", path: "/api/goals", body: fields });
export const changeGoalRequest = (goal, changes) => ({ method: "PATCH", path: `/api/goals/${goal.id}`, body: changes });
export const deleteGoalRequest = (goal) => ({ method: "DELETE", path: `/api/goals/${goal.id}` });
export const acceptRequest = (goal) => ({ method: "POST", path: `/api/goals/${goal.id}/accept` });
export const dismissRequest = (goal) => ({ method: "POST", path: `/api/goals/${goal.id}/dismiss` });

// The board after `goals` in order, `id` moved up (-1) or down (+1) a place:
// the position to send, or null at either end.
export function movedPosition(goals, id, direction) {
  const index = goals.findIndex((g) => g.id === id);
  const target = index + direction;
  if (index < 0 || target < 0 || target >= goals.length) return null;
  return target + 1;
}
