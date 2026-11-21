// The day's check-ins, kept free of the DOM: what the user said about the
// night that ended that morning (`night`, as Garmin dates sleep and HRV) and
// how they felt that day (`day`). Each is optional and written whole
// (PUT /api/check_ins/<date>/<group>), or cleared (DELETE), through the
// outbox, so a check-in made offline shows at once (withQueuedCheckIns).

import { addDays } from "./calendar.js";

const WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

// Each field's choices, as the API names them and as the sheets say them.
export const CHOICES = {
  sleep: [["poor", "Poor"], ["ok", "OK"], ["good", "Good"]],
  drinks: [["none", "None"], ["1-2", "1–2"], ["3+", "3+"]],
  feeling: [["rough", "Rough"], ["ok", "OK"], ["good", "Good"]],
  stress: [["low", "Low"], ["normal", "Normal"], ["high", "High"]],
  sore: [["no", "No"], ["a_bit", "A bit"], ["a_lot", "A lot"]],
};
export const NIGHT_TAGS = [["late_to_bed", "Late to bed"], ["ate_late", "Ate late"], ["travelling", "Travelling"], ["woke_a_lot", "Woke a lot"]];
export const SORE_AREAS = [["knees", "Knees"], ["calves", "Calves"], ["achilles", "Achilles"], ["shins", "Shins"],
  ["hamstrings", "Hamstrings"], ["hips", "Hips"], ["back", "Back"], ["other", "Other"]];
export const NOTE_LENGTH = 500;

// A group's fields, and their value when nothing was said.
export const FIELDS = {
  night: { sleep: null, drinks: null, tags: [], note: null },
  day: { feeling: null, stress: null, sore: null, sore_areas: [], ill: false, note: null },
};

const label = (list, value) => list.find(([v]) => v === value)?.[1] ?? value;
const weekdayOf = (iso) => WEEKDAYS[(new Date(`${iso}T12:00:00Z`).getUTCDay() + 6) % 7];

// "Slept poorly · 3+ drinks · Late to bed".
export function nightSummary(night) {
  if (!night) return "";
  return [
    night.sleep && { poor: "Slept poorly", ok: "Slept OK", good: "Slept well" }[night.sleep],
    night.drinks && (night.drinks === "none" ? "No drinks" : `${label(CHOICES.drinks, night.drinks)} drinks`),
    ...(night.tags ?? []).map((t) => label(NIGHT_TAGS, t)),
  ].filter(Boolean).join(" · ");
}

// "Feeling OK · High stress · Knees a bit sore · Ill". Normal stress and
// nothing sore are said only when there is nothing else.
export function daySummary(day) {
  if (!day) return "";
  const areas = (day.sore_areas ?? []).map((a) => label(SORE_AREAS, a));
  const sore = day.sore && day.sore !== "no" && `${areas.length ? areas.join(", ") : "Sore"} ${day.sore === "a_lot" ? "a lot" : "a bit"}${areas.length ? " sore" : ""}`;
  const said = [
    day.feeling && { rough: "Feeling rough", ok: "Feeling OK", good: "Feeling good" }[day.feeling],
    day.stress && day.stress !== "normal" && `${label(CHOICES.stress, day.stress)} stress`,
    sore,
    day.ill && "Ill",
  ].filter(Boolean);
  if (said.length) return said.join(" · ");
  return [day.stress === "normal" && "Normal stress", day.sore === "no" && "Nothing sore"].filter(Boolean).join(" · ");
}

// What each row is called on a day: today's night is "Last night", another
// day's says which ("Night, Thu to Fri").
export const nightTitle = (date, today) => (date === today ? "Last night" : `Night, ${weekdayOf(addDays(date, -1))} to ${weekdayOf(date)}`);
export const dayTitle = (date, today) => (date === today ? "How I feel today" : "How I felt");

// The fields of a group with something in them, from a sheet's values:
// text trimmed, lists without repeats, `ill` only when true.
export function groupFields(group, values) {
  const fields = {};
  for (const [name, empty] of Object.entries(FIELDS[group])) {
    let value = values[name];
    if (typeof value === "string") value = value.trim() || null;
    if (Array.isArray(value)) value = [...new Set(value)];
    if (value == null || value === empty || (Array.isArray(value) && value.length === 0)) continue;
    fields[name] = value;
  }
  // Where it is sore says nothing once it isn't.
  if (group === "day" && (!fields.sore || fields.sore === "no")) delete fields.sore_areas;
  return fields;
}

const path = (date, group) => `/api/check_ins/${date}/${group}`;

// Writes a group whole, or clears it when nothing is left in it. `today` is
// the device's, which the date may not be after.
export function checkInRequest(date, group, values, today) {
  const fields = groupFields(group, values);
  if (Object.keys(fields).length === 0) return clearRequest(date, group);
  return { method: "PUT", path: path(date, group), body: { ...fields, today } };
}

export const clearRequest = (date, group) => ({ method: "DELETE", path: path(date, group) });

const PATH = /^\/api\/check_ins\/(\d{4}-\d{2}-\d{2})\/(night|day)$/;

// The check-ins as they will be once the queued requests are sent: a group
// written whole or cleared, and a day with neither left out. A group not
// sent yet carries `pending: true`. Other requests are left out.
export function withQueuedCheckIns(checkIns, queue) {
  const days = new Map(checkIns.map((c) => [c.date, { ...c }]));
  for (const entry of queue) {
    const match = entry.path?.match(PATH);
    if (!match || !["PUT", "DELETE"].includes(entry.method)) continue;
    const [, date, group] = match;
    const day = days.get(date) ?? { date, night: null, day: null };
    if (entry.method === "DELETE") {
      day[group] = null;
    } else {
      const fields = Object.fromEntries(Object.entries(FIELDS[group]).map(([name, empty]) => [name, entry.body?.[name] ?? empty]));
      day[group] = { ...fields, logged_by: "manual", pending: true };
    }
    days.set(date, day);
  }
  return [...days.values()].filter((c) => c.night || c.day).sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
}

// The check-ins by their date.
export const checkInsByDay = (checkIns) => Object.fromEntries(checkIns.map((c) => [c.date, c]));

// What a folded day or a month cell says of them: "night", "how you felt".
export function checkInItems(checkIn) {
  return [checkIn?.night && "night", checkIn?.day && "how you felt"].filter(Boolean);
}
