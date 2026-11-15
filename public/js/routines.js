// Routines as the PWA shows and changes them, kept free of the DOM so node
// can test it: what a routine is called and when it runs, how a day of it
// reads on the device's today, the activities still in the outbox that
// fulfil one, and the requests a change sends.
//
// The server works the days out (RoutineCalendar) and says how each reads on
// the `today` the page sent. A tentative or confirmed day reads again here
// against the device's day, so one left open overnight turns missed, and an
// activity logged offline ticks its day off before the server has it.

import { sportFamily, normalSport, sportLabel, formatDistance, distanceInMetres } from "./activities.js";

export const WEEKDAY_SHORT = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const WEEKDAY_PLURAL = ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"];
export const EFFORTS = ["easy", "moderate", "hard"];

// The words a routine day reads as, the same as a session's (one
// vocabulary: Planned, Maybe, Done, Skipped, Missed).
export const STATE_LABELS = {
  tentative: "Maybe", confirmed: "Planned", done: "Done", skipped: "Skipped", missed: "Missed",
};

// 1 for Monday to 7 for Sunday, as the server counts weekdays.
export const isoWeekday = (iso) => ((new Date(`${iso}T00:00:00Z`).getUTCDay() + 6) % 7) + 1;

// What a routine is called: its title, else its workout or sport.
export const routineTitle = (routine) => routine.title || routine.workout?.title || sportLabel(routine.sport);

// "Wednesdays and Saturdays", "Every day", "Weekdays", or "Once" for a one-off.
export function weekdaysLabel(weekdays) {
  const days = [...new Set(weekdays)].sort((a, b) => a - b);
  if (days.length === 0) return "Once";
  if (days.length === 7) return "Every day";
  if (days.join() === "1,2,3,4,5") return "Weekdays";
  if (days.join() === "6,7") return "Weekends";
  const names = days.map((d) => WEEKDAY_PLURAL[d - 1]);
  return names.length === 1 ? names[0] : `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;
}

// What a routine plans, in order: when, how long, how far, how hard.
export function routineFacts(routine, unit) {
  return [
    weekdaysLabel(routine.weekdays),
    routine.minutes && `${routine.minutes} min`,
    routine.distance_m && formatDistance(routine.distance_m, unit),
    routine.effort && routine.effort[0].toUpperCase() + routine.effort.slice(1),
  ].filter(Boolean);
}

// How a day reads on `today`: done and skipped stay, as does a day planned
// as a session (which the calendar reads as the session); the others are
// tentative or confirmed from today on, missed before.
export function dayState(day, today) {
  if (day.state === "done" || day.state === "skipped" || day.session_id != null) return day.state;
  if (day.on < today) return "missed";
  return day.confirmed ? "confirmed" : "tentative";
}

// A sport's family, or the word itself when it has none, as the server
// matches them (Sport.family).
const family = (sport) => {
  const known = sportFamily(sport);
  return known === "activity" ? normalSport(String(sport ?? "").replace(/-+/g, " ")) : known;
};
export const sameSport = (a, b) => family(a) === family(b);

const activityRef = (activity) => (activity.id != null ? `id:${activity.id}` : `ref:${activity.client_ref}`);

// The days as they read on `today`, with the activities the outbox still
// holds (`activities` from withQueuedActivities) given to the open days of
// a sport routine they fulfil, as the server will once it has them: one
// linked by hand to a day first, then the earliest of the same sport family
// on the day, each activity to one day. A day done by an activity the
// outbox deletes (`removed`, from removedActivityIds) is open again. Days
// come in the server's order.
export function withActivities(days, routines, activities, today, removed = new Set()) {
  const byId = new Map(routines.map((r) => [r.id, r]));
  const claimed = new Set(days.filter((d) => d.activity_id != null).map((d) => `id:${d.activity_id}`));
  const pending = activities.filter((a) => a.pending && !claimed.has(activityRef(a)));
  return days.map((day) => {
    const routine = byId.get(day.routine_id);
    const reopened = day.activity_id != null && removed.has(day.activity_id)
      ? { activity_id: null, linked: false, state: "tentative" } : {};
    const shown = { ...day, ...reopened, state: dayState({ ...day, ...reopened }, today) };
    if (!routine?.sport || shown.state === "done" || shown.state === "skipped") return shown;
    const linked = pending.find((a) => a.routine_id === day.routine_id && a.routine_date === day.date && !claimed.has(activityRef(a)));
    const match = linked ?? pending.find((a) => a.date === day.on && a.routine_id == null && !claimed.has(activityRef(a)) && sameSport(a.sport, routine.sport));
    if (!match) return shown;
    claimed.add(activityRef(match));
    return { ...shown, state: "done", activity_key: match.id ?? match.client_ref, pending: true };
  });
}

// Days by the day they show on: { "2026-11-11": [...] }.
export function byDay(days) {
  const out = {};
  for (const day of days) (out[day.on] ??= []).push(day);
  return out;
}

// The days a calendar day lists as routine rows. A workout routine's day
// with a session shows as that session, and a done sport day as its
// activity, so neither shows twice.
export const listed = (days) => days.filter((d) => d.session_id == null && d.state !== "done");

// The days a day can move to: the week its day shows on (or this week, once
// it has gone by), each disabled when gone by or where it already is.
export function moveChoices(day, today, weekOf) {
  return weekOf(day.on < today ? today : day.on).map((date) => ({ date, disabled: date < today || date === day.on }));
}

// ---------- Requests ----------

const dayPath = (day) => `/api/routines/${day.routine_id}/days/${day.date}`;

export const confirmRequest = (day, today) => ({ method: "PUT", path: dayPath(day), body: { status: "confirmed", today } });
export const skipRequest = (day, today) => ({ method: "PUT", path: dayPath(day), body: { status: "skipped", today } });
export const moveRequest = (day, date, today) => ({ method: "PUT", path: dayPath(day), body: { status: "moved", moved_to: date, today } });
export const resetRequest = (day, today) => ({ method: "DELETE", path: `${dayPath(day)}?today=${today}` });

export const planRequest = (fields, today, confirmed = false) =>
  ({ method: "POST", path: "/api/routines", body: { ...fields, today, ...(confirmed ? { confirmed: true } : {}) } });
export const changeRequest = (routine, fields, today) => ({ method: "PATCH", path: `/api/routines/${routine.id}`, body: { ...fields, today } });
export const endRequest = (routine, today) => ({ method: "DELETE", path: `/api/routines/${routine.id}?today=${today}` });

// What the routine sheet's form holds, as the API takes it, and what is
// wrong with it. `once` plans a one-off on `startsOn`; else it runs weekly
// on `weekdays` from `startsOn`. Blank numbers are left out (or cleared,
// for a change); minutes are whole, distance is in `unit`.
export function readRoutine({ what, sport, workoutId, once, weekdays, startsOn, title, minutes, distance, effort, note }, unit) {
  const fields = { title: title.trim() || null, note: note.trim() || null, effort: EFFORTS.includes(effort) ? effort : null };
  if (what === "workout") {
    fields.workout_id = Number(workoutId) || null;
    fields.sport = null;
  } else {
    fields.sport = sport.trim();
    fields.workout_id = null;
  }
  fields.weekdays = once ? [] : [...new Set(weekdays.map(Number))].sort((a, b) => a - b);
  fields.starts_on = startsOn;
  const mins = minutes.trim() === "" ? null : Number(minutes);
  fields.minutes = mins;
  const metres = distance.trim() === "" ? null : distanceInMetres(distance, unit);
  fields.distance_m = metres;
  const problems = [
    what === "workout" ? !fields.workout_id && "Pick a workout." : !fields.sport && "Say what you'll do, such as run.",
    !once && fields.weekdays.length === 0 && "Pick at least one day of the week.",
    !startsOn && (once ? "Pick the day." : "Pick the first day."),
    mins !== null && !(Number.isInteger(mins) && mins > 0) && "Give the time as whole minutes.",
    metres !== null && !(metres > 0) && `Give the distance as a number of ${unit}.`,
  ].filter(Boolean);
  return { fields, problems };
}
