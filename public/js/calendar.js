// The calendar's logic, kept free of the DOM so node can test it: days and
// weeks as YYYY-MM-DD text, the status each session reads as, the requests a
// change sends, and the calendar as it will be once the outbox has sent them.
//
// Weeks run Monday to Sunday. A planned session on a day before today reads
// as missed (the server keeps it planned), so moving it to today or later
// makes it planned again.

const DAY_MS = 24 * 60 * 60 * 1000;
const WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

// Days are counted in UTC so a change of clocks never shifts one.
const toTime = (iso) => Date.UTC(Number(iso.slice(0, 4)), Number(iso.slice(5, 7)) - 1, Number(iso.slice(8, 10)));
const toIso = (time) => new Date(time).toISOString().slice(0, 10);

export const isDate = (text) => typeof text === "string" && /^\d{4}-\d{2}-\d{2}$/.test(text) && toIso(toTime(text)) === text;

export function addDays(iso, days) {
  return toIso(toTime(iso) + days * DAY_MS);
}

// 1 for Monday to 7 for Sunday.
const weekday = (iso) => ((new Date(toTime(iso)).getUTCDay() + 6) % 7) + 1;

export function mondayOf(iso) {
  return addDays(iso, 1 - weekday(iso));
}

// The seven days of the week `iso` falls in, Monday first.
export function weekOf(iso) {
  const monday = mondayOf(iso);
  return Array.from({ length: 7 }, (_, i) => addDays(monday, i));
}

// The weeks a month grid shows for the month `iso` falls in: from the Monday
// on or before the 1st to the Sunday on or after the last day.
export function monthWeeks(iso) {
  const first = `${iso.slice(0, 7)}-01`;
  const next = addMonths(first, 1);
  const weeks = [];
  for (let monday = mondayOf(first); monday < next; monday = addDays(monday, 7)) weeks.push(weekOf(monday));
  return weeks;
}

// The same day `months` months on, or the month's last day when it is shorter.
export function addMonths(iso, months) {
  const year = Number(iso.slice(0, 4));
  const month = Number(iso.slice(5, 7)) - 1 + months;
  const last = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  return toIso(Date.UTC(year, month, Math.min(Number(iso.slice(8, 10)), last)));
}

// The days to ask the server for: the shown week, or the shown month's grid.
export function rangeFor(view, iso) {
  const days = view === "month" ? monthWeeks(iso).flat() : weekOf(iso);
  return { from: days[0], to: days.at(-1) };
}

// "Wednesday", "Today", "Tomorrow" or "Yesterday".
export function dayName(iso, today) {
  const relative = { [today]: "Today", [addDays(today, 1)]: "Tomorrow", [addDays(today, -1)]: "Yesterday" }[iso];
  return relative ?? WEEKDAYS[weekday(iso) - 1];
}

// "Wed 28", for a day picker.
export function weekdayDay(iso) {
  return `${WEEKDAYS[weekday(iso) - 1].slice(0, 3)} ${Number(iso.slice(8, 10))}`;
}

// "Wednesday, Oct 28".
export function longDay(iso) {
  return `${WEEKDAYS[weekday(iso) - 1]}, ${shortDay(iso)}`;
}

// The device's date today.
export function localToday(now = new Date()) {
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
}

// "Oct 28".
export function shortDay(iso) {
  return `${MONTHS[Number(iso.slice(5, 7)) - 1].slice(0, 3)} ${Number(iso.slice(8, 10))}`;
}

// "Oct 26 – Nov 1", or "Oct 26 – Nov 1, 2027" outside `today`'s year.
export function weekLabel(iso, today) {
  const days = weekOf(iso);
  const label = `${shortDay(days[0])} – ${shortDay(days[6])}`;
  return days[6].slice(0, 4) === today.slice(0, 4) ? label : `${label}, ${days[6].slice(0, 4)}`;
}

// "October 2026".
export function monthLabel(iso) {
  return `${MONTHS[Number(iso.slice(5, 7)) - 1]} ${iso.slice(0, 4)}`;
}

// The status a session reads as on `today`.
export function shownStatus(session, today) {
  if (session.status !== "planned" && session.status !== "missed") return session.status;
  return session.date < today ? "missed" : "planned";
}

// Only a planned (or missed) session can be moved, skipped or removed.
export const movable = (session) => session.status === "planned" || session.status === "missed";

// The session up next: the first one under way today, else the first
// planned from today on, in calendar order. One started on an earlier day and
// left is history, not what comes next.
export function upNext(sessions, today) {
  const ordered = inOrder(sessions);
  return ordered.find((s) => s.status === "in_progress" && s.date === today) ??
    ordered.find((s) => shownStatus(s, today) === "planned") ?? null;
}

// The mark a session row shows: done filled, planned outlined, up next in the
// accent colour, missed dashed, skipped struck through.
export function markFor(session, today, next) {
  const status = shownStatus(session, today);
  if (next && sameSession(session, next)) return "next";
  return status;
}

export const STATUS_LABELS = {
  planned: "Planned", next: "Up next", missed: "Missed", in_progress: "Under way", done: "Done", skipped: "Skipped",
};

export function inOrder(sessions) {
  return [...sessions].sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : a.position - b.position));
}

// Sessions by day, each day in order: { "2026-10-28": [...] }.
export function byDay(sessions) {
  const days = {};
  for (const session of inOrder(sessions)) (days[session.date] ??= []).push(session);
  return days;
}

// Planning and moving go to today or later only.
export const plannable = (iso, today) => iso >= today;

// The days a session can move to: the week of its day, or this week once its
// day has gone by, each disabled when it is gone by or is the session's own day.
export function moveChoices(session, today) {
  return weekOf(session.date < today ? today : session.date)
    .map((date) => ({ date, disabled: date < today || date === session.date }));
}

// Where a session is on the server: its id, or until it has one the name its
// create is saved under in the outbox.
export function sessionPath(session) {
  return session.id != null ? `/api/sessions/${session.id}` : `/api/sessions/{${session.client_ref}}`;
}

const sameSession = (a, b) => (a.id != null && a.id === b.id) || (a.client_ref != null && a.client_ref === b.client_ref);

// Plans a workout last on a day. `id` names the create, so a retry is
// recognised and later changes can refer to it before the server answers.
// `workout` rides along (unsent) so the calendar can show it straight away.
// `today` is the device's, which the server checks "today or later" against.
export function planRequest({ workout, date, note, id, today = localToday() }) {
  const ref = `plan:${id}`;
  const body = { workout_id: workout.id, date, today, status: "planned", created_by: "manual", client_ref: ref };
  if (note?.trim()) body.note = note.trim();
  return { method: "POST", path: "/api/sessions", saveAs: ref, body, workout: summaryOf(workout) };
}

// Moves a session to another day, last there, from the device's today on.
export function moveRequest(session, date, today = localToday()) {
  return { method: "PATCH", path: sessionPath(session), body: { date, today } };
}

export function skipSessionRequest(session) {
  return { method: "PATCH", path: sessionPath(session), body: { status: "skipped" } };
}

// Takes a planned session off the calendar. `only=planned` makes the server
// refuse (409) once the session has started elsewhere, rather than erase it.
export function removeRequest(session) {
  return { method: "DELETE", path: `${sessionPath(session)}?only=planned` };
}

const summaryOf = ({ id, title, kind, estimated_minutes }) => ({ id, title, kind, estimated_minutes });

// The sessions as they will be once the queued requests are sent: plans
// added, moves, skips and removals applied, each day numbered 1..n again.
// Requests that are not about the calendar are left out. A session shown
// before the server has it carries `pending: true`.
export function withQueued(sessions, queue, today) {
  let list = sessions.map((s) => ({ ...s }));
  const find = (path) => {
    const match = path.match(/^\/api\/sessions\/(?:(\d+)|\{([^}]+)\})(?:\?.*)?$/);
    if (!match) return null;
    return list.find((s) => (match[1] ? s.id === Number(match[1]) : s.client_ref === match[2])) ?? null;
  };
  const last = (date, except) => Math.max(0, ...list.filter((s) => s.date === date && s !== except).map((s) => s.position));

  for (const entry of queue) {
    if (entry.method === "POST" && entry.path === "/api/sessions" && entry.body?.status === "planned" && entry.workout) {
      const { client_ref, date, note = null } = entry.body;
      if (list.some((s) => s.client_ref === client_ref)) continue;
      list.push({
        id: null, client_ref, date, position: last(date) + 1, status: "planned", created_by: "manual",
        note, parts: null, workout: entry.workout, sets_done: 0, completion: null, pending: true,
      });
      continue;
    }
    const session = find(entry.path);
    if (!session) continue;
    if (entry.method === "DELETE") {
      list = list.filter((s) => s !== session);
    } else if (entry.method === "PATCH") {
      const { date, status } = entry.body ?? {};
      if (date && date !== session.date) {
        session.position = last(date, session) + 1;
        session.date = date;
      }
      if (status) session.status = status;
      if (entry.body && "note" in entry.body) session.note = entry.body.note;
      session.pending = true;
    }
  }

  // Close the gaps a move or removal left.
  const days = byDay(list);
  for (const day of Object.values(days)) day.forEach((s, i) => { s.position = i + 1; });
  return inOrder(list).map((s) => ({ ...s, status: shownStatus(s, today) }));
}
