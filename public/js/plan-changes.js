// What the calendar says about an agent's changes to the plan,
// kept free of the DOM so node can test it. The server records every change
// to a session or routine; the calendar gives each item the latest one an
// agent made, not taken back (`change`), and a line for each session an
// agent moved away from a day or removed from it (`plan_changes`). Each says
// whether it can be taken back now (`undoable`): only the latest change to
// an item, once, and only into a day that has not gone by. A change of
// yours is not shown: the mark means someone else changed it.
//
// Workout edits and remembered weights are recorded the same way:
// `item_kind` workout (with a `summary` of what changed) or weight (`was`
// and `now` the value and unit, both null while nothing was remembered),
// shown on the workout and on Get ready.

import { weekOf, weekdayDay, shortDay } from "./calendar.js";
import { agentName, writtenDay } from "./coach.js";
import { weekdaysLabel } from "./routines.js";
import { formatDistance, sportLabel } from "./activities.js";
import { escape, authorLine } from "./html.js";
import { formatWeight } from "./weights.js";

// "Sat 21" in the week of `near`, else "Sat Nov 21".
export function dayNear(iso, near) {
  return weekOf(near).includes(iso) ? weekdayDay(iso) : `${weekdayDay(iso).slice(0, 3)} ${shortDay(iso)}`;
}

// The old day of a moved session, from what the change recorded.
const oldDay = (change) => change.was?.date ?? change.from_date;

const capital = (text) => text[0].toUpperCase() + text.slice(1);

// How a routine's or session's changed fields read, before and after: "16
// km → 18 km", "the note". Fields a person would not recognise by their
// values (a note, a workout) are only named.
export function fieldChanges(change, unit) {
  const was = change.was ?? {};
  const now = change.now ?? {};
  const both = (format) => (key) => `${format(was[key])} → ${format(now[key])}`;
  const describe = {
    minutes: both((v) => (v == null ? "no time" : `${v} min`)),
    distance_m: both((v) => (v == null ? "no distance" : formatDistance(v, unit))),
    effort: both((v) => (v ? capital(v) : "no effort")),
    weekdays: both((v) => weekdaysLabel(v ?? [])),
    sport: both((v) => sportLabel(v)),
    starts_on: (key) => `starts ${shortDay(now[key])}`,
    ends_on: (key) => (now[key] ? `ends ${shortDay(now[key])}` : "no last day"),
    title: () => "the title",
    workout_id: () => "the workout",
    note: () => "the note",
    parts: () => "the parts",
    position: () => "its place in the day",
  };
  return Object.keys(now).filter((key) => describe[key]).map((key) => describe[key](key));
}

// A remembered weight as a change recorded it, shown in `unit` (lb or kg):
// "25 lb", "no weight", or "the workout's own" while nothing was remembered.
export function rememberedText(weight, unit) {
  if (!weight?.unit) return "the workout's own";
  return weight.value == null ? "no weight" : formatWeight(weight, unit ?? weight.unit);
}

// The line a workout or a weight shows for an agent's change: "Coach agent
// changed this workout · today: 3 rounds in block B (was 2)", "Coach agent
// set 25 lb · today (was 20 lb)".
function workoutLine(change, who, when, weightUnit) {
  if (change.item_kind === "weight") {
    return `${who} set ${rememberedText(change.now, weightUnit)} · ${when} (was ${rememberedText(change.was, weightUnit)})`;
  }
  if (change.action === "archived") return `${who} archived this workout · ${when}`;
  return `${who} changed this workout · ${when}${change.summary ? `: ${change.summary}` : ""}`;
}

// The line an item shows for the latest change an agent made to it: "Coach
// agent moved this from Sat 21 · today", "Coach agent · changed today: 16 km
// → 18 km". Null when there is none to show: none, or the agent planned it
// (which "planned by" already says).
export function changeLine(change, { today, unit = "km", weightUnit } = {}) {
  if (!change || change.changed_by !== "llm") return null;
  const who = agentName(change);
  const when = writtenDay(change.created_at, today);
  if (change.item_kind === "workout" || change.item_kind === "weight") return workoutLine(change, who, when, weightUnit);
  switch (change.action) {
    case "moved":
      return `${who} moved this from ${dayNear(oldDay(change), change.to_date ?? today)} · ${when}`;
    case "changed": {
      const fields = fieldChanges(change, unit);
      return `${who} · changed ${when}${fields.length ? `: ${fields.join(", ")}` : ""}`;
    }
    case "ended":
      return `${who} ended this · ${when}`;
    default:
      return null;
  }
}

// The button that takes a change back, while it can be: Move it back, Put
// it back, Change it back, Plan it again. Null when it can't (the old day
// has gone by, it changed again since, it was taken back already).
export function undoLabel(change) {
  if (!change?.undoable) return null;
  return { moved: "Move it back", removed: "Put it back", changed: "Change it back", ended: "Plan it again" }[change.action] ?? null;
}

// What the button says to a screen reader, which hears it away from its
// row: "Move Session B back to Sat 21", "Put Session B back on Sat 21".
export function undoName(change, title = change.title) {
  const name = title || "it";
  switch (change.action) {
    case "moved": return `Move ${name} back to ${dayNear(oldDay(change), change.to_date)}`;
    case "removed": return `Put ${name} back on ${dayNear(change.from_date, change.from_date)}`;
    case "changed": return `Change ${name} back`;
    case "ended": return `Plan ${name} again`;
    default: return undoLabel(change) ?? "";
  }
}

// The lines for the sessions an agent moved away from a day or removed
// from it, by the day they left: "Session B moved to Thu 19 by Coach
// agent", "Session B removed by Coach agent". A removal offers Put it back,
// and a move offers Move it back when the session now sits outside the days
// shown (`from`..`to`), where its own row with that button can't be seen;
// the reason given shows on the line then too, and otherwise on the row.
export function dayChangeLines(changes, { from, to } = {}) {
  const days = {};
  for (const change of changes ?? []) {
    if (change.changed_by !== "llm" || !["moved", "removed"].includes(change.action)) continue;
    const title = change.title || "A session";
    const who = agentName(change);
    const text = change.action === "moved"
      ? `${title} moved to ${dayNear(change.to_date, change.from_date)} by ${who}`
      : `${title} removed by ${who}`;
    const away = change.action === "moved" && from && to && (change.to_date < from || change.to_date > to);
    const offered = change.action === "removed" || away;
    (days[change.from_date] ??= []).push({ text, reason: offered ? change.reason ?? null : null, undo: offered && undoLabel(change) ? change : null });
  }
  return days;
}

// The agent's edits of the workouts in `workoutIds` and the weights it set
// for `exerciseIds`, from the `changes` the workout or Today gives: what
// Get ready and the workout page show.
export const workoutChanges = (changes, workoutIds) => (changes ?? []).filter((c) => c.item_kind === "workout" && workoutIds.includes(c.workout_id));
export const weightChange = (changes, exerciseId) => (changes ?? []).find((c) => c.item_kind === "weight" && c.exercise_id === exerciseId) ?? null;

// The latest change an agent made to a session, unless one of the user's
// is still queued for it, which comes after it.
export const sessionChange = (session) => (session.pending ? null : session.change ?? null);

// The latest change an agent made to `routine`, as one of its days shows
// it: from the day the change took effect on (an ended routine's on any of
// its days), else null.
export function routineChangeOn(day, routine) {
  const change = routine?.change;
  if (!change) return null;
  return change.action === "ended" || day.on >= (change.from_date ?? day.on) ? change : null;
}

// The routine days that show their routine's change: the first of each
// routine's `days` (in order) it applies to, so a run three times a week
// says it once. A Set of the days.
export function changeShownOn(days, routineOf) {
  const seen = new Set();
  const shown = new Set();
  for (const day of days) {
    if (seen.has(day.routine_id) || !routineChangeOn(day, routineOf(day))) continue;
    seen.add(day.routine_id);
    shown.add(day);
  }
  return shown;
}

// What the calendar offers while it shows a copy kept on the device rather
// than the server's answer (`stale`): the changes without their undo, which
// may no longer hold.
export const withoutUndo = (change, stale) => (change && stale ? { ...change, undoable: false } : change);

// An item's latest change by an agent, as rows and sheets show it: its line
// with the agent's icon, then the reason given with it. Null when there is
// nothing to say, so the caller can show who planned it instead.
export function changeHtml(change, { today, unit, weightUnit, tag = "span" } = {}) {
  const line = changeLine(change, { today, unit, weightUnit });
  if (!line) return null;
  return `${authorLine(line, tag)}${change.reason ? `<${tag} class="change-reason">${escape(change.reason)}</${tag}>` : ""}`;
}

// The button that takes `change` back, named for a screen reader by what
// it does to `title`; empty when it can't be taken back. On a row it
// carries the change's id in data-undo; in a sheet (`sheet`) it closes the
// sheet with "undo". `classes` are the button's (quiet on a day's line);
// `disabled` while another change is on its way.
export function undoButton(change, title = change?.title, { sheet = false, classes = "secondary small", disabled = false } = {}) {
  const label = undoLabel(change);
  if (!label) return "";
  const how = sheet ? `value="undo"` : `type="button" data-undo="${change.id}"`;
  return `<button class="${classes}" ${how}${disabled ? " disabled" : ""} aria-label="${escape(undoName(change, title))}">${escape(label)}</button>`;
}

// Taking a change back, on the device's own day (sent now, not queued: it
// answers whether it could).
export const undoRequest = (change, today) => ({ method: "POST", path: `/api/plan_changes/${change.id}/undo`, body: { today } });
