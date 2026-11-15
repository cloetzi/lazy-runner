// The Coach tab's logic, kept free of the DOM so node can test it: who wrote
// a note, the week as days, what a note or goal form sends, and the
// requests for goals and notes.
//
// Goals are the user's: the app adds, edits and orders them, and accepts or
// dismisses what an agent proposed. Notes are written by the user ("You"), a
// coach they name, or an agent (over MCP, never from here).

import { weekOf, shortDay, localToday, addDays } from "./calendar.js";
import { FEEDBACK } from "./history.js";

export const KINDS = ["status", "focus", "concern", "note"];
export const KIND_LABELS = { status: "Status", focus: "Focus", concern: "Concern", note: "Note" };
// What an agent is called when what it wrote carries no name (written
// before agents were named after their API token).
export const AGENT_NAME = "Coach agent";

// "You", the coach's name, or the agent's (its token's name, else Coach agent).
export function authorLabel(note) {
  if (note.author_kind === "user") return "You";
  if (note.author_kind === "llm") return note.author_name || AGENT_NAME;
  return note.author_name || "Coach";
}

// The agent's name on a session, routine, activity or goal it wrote.
export const agentName = (item) => item.agent_name || AGENT_NAME;

// The author's badge: a person for you, the agent's icon for an agent, and a
// named coach's initials (letters only, so "Dana (physio)" is DP; ? when
// the name has none). A letter keeps its accents, and one outside the
// basic plane stays whole.
export function authorBadge(note) {
  if (note.author_kind === "user") return { icon: "person" };
  if (note.author_kind === "llm") return { icon: "agent" };
  const words = (note.author_name ?? "").split(/\s+/).map((w) => w.replace(/[^\p{L}\p{M}\p{N}]/gu, "")).filter(Boolean);
  const first = (word) => word.match(/^[\p{L}\p{N}]\p{M}*/u)?.[0] ?? "";
  const letters = words.length > 1 ? first(words[0]) + first(words.at(-1)) : (words[0]?.match(/^(?:[\p{L}\p{N}]\p{M}*){1,2}/u)?.[0] ?? "");
  return { initials: letters ? letters.toUpperCase() : "?" };
}

// When something was written, as a day on this device: "today",
// "yesterday", "Nov 3", or "Nov 3, 2025" in another year.
export function writtenDay(time, today = localToday()) {
  const day = localDate(time);
  if (day === today) return "today";
  if (day === addDays(today, -1)) return "yesterday";
  return day.slice(0, 4) === today.slice(0, 4) ? shortDay(day) : `${shortDay(day)}, ${day.slice(0, 4)}`;
}

// Who planned a session or routine, when it was not you: "Coach agent ·
// planned today". Null for your own, so the mark means someone else put it
// there.
// A session made from a routine's day was made when you said you're going,
// not when the agent planned it, so it names the agent only.
export function plannedBy(item, today = localToday()) {
  if (item?.created_by !== "llm") return null;
  if (!item.created_at || item.routine_id != null) return `Planned by ${agentName(item)}`;
  return `${agentName(item)} · planned ${writtenDay(item.created_at, today)}`;
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
    notes: week.notes.filter((n) => noteDay(n) === date),
  }));
}

// The day a note shows on: its session's or activity's, wherever that is
// now, else the day it is dated to (null for neither). `sessions` are the
// sessions as shown, a move still queued included, so the note goes with it.
export function noteDay(note, sessions = []) {
  if (note.about?.type === "session") {
    const session = sessions.find((s) => s.id === note.about.id);
    if (session) return session.date;
  }
  return note.about?.date ?? note.date ?? null;
}

// Notes by the day they show on: { "2026-11-03": [note, ...] }, in the
// order written. `sessions` as noteDay takes them.
export function notesByDay(notes, sessions = []) {
  const days = {};
  for (const note of [...notes].sort((a, b) => a.id - b.id)) {
    const day = noteDay(note, sessions);
    if (day) (days[day] ??= []).push(note);
  }
  return days;
}

// The notes about one session or activity (`type` "session" or
// "activity"), newest first.
export const notesAbout = (notes, type, id) =>
  id == null ? [] : notes.filter((n) => n.about?.type === type && n.about.id === id).sort((a, b) => b.id - a.id);

// How a done session felt, from its completion: "RPE 8 · too hard · ended
// early", or "" when nothing was said.
export function howItFelt(completion) {
  if (!completion) return "";
  return [completion.rpe && `RPE ${completion.rpe}`, FEEDBACK[completion.feedback], completion.ended_early && "ended early"].filter(Boolean).join(" · ");
}

// The journal's filters, each the query that keeps its notes. Statuses and
// focus are left out: the journal folds the earlier ones into one line.
export const JOURNAL_FILTERS = [
  { key: "all", label: "All", query: "kind=note,concern" },
  { key: "you", label: "Yours", query: "kind=note,concern&author=user" },
  { key: "coach", label: "Your coach", query: "kind=note,concern&author=human,llm" },
  { key: "concerns", label: "Concerns", query: "kind=concern" },
];

// A page of the journal under `filter` (a key of JOURNAL_FILTERS), written
// before the note `before` when given.
export function journalPath(filter, before = null) {
  const { query } = JOURNAL_FILTERS.find((f) => f.key === filter) ?? JOURNAL_FILTERS[0];
  return `/api/coach/notes?journal=true&limit=20&${query}${before == null ? "" : `&before=${before}`}`;
}

export const tidyCountPath = (before) => `/api/coach/tidy?before=${before}`;
export const tidyRequest = (before) => ({ method: "POST", path: "/api/coach/tidy", body: { before } });

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
