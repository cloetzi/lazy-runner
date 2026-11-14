// Activities as the PWA shows and changes them, kept free of the DOM so node
// can test it: which icon a sport gets, distances and times as text, the
// requests a change sends, the activities as they will be once the outbox has
// sent them, and when Today asks how hard one was.
//
// The server keeps what was sent, distances in metres and times in seconds;
// nothing is worked out from them here either, beyond the units shown.

import SPORTS from "./sports.json" with { type: "json" };
import { agentName, writtenDay } from "./coach.js";
import { localToday } from "./calendar.js";

export const DISTANCE_UNITS = ["km", "mi"];
const DISTANCE_KEY = "distanceUnit";
const SETTINGS_PATH = "/api/settings";
const METRES_PER_MILE = 1609.344;
const FEET_PER_METRE = 3.28084;

// Suggested in the sport field, one word per icon.
export const KNOWN_SPORTS = Object.keys(SPORTS);

// A sport as the server keeps it (Activity.sport): "TrailRun" or
// "trail_run" as plain words, trimmed, lowercase, single spaces.
export const normalSport = (text) =>
  String(text ?? "").replace(/([a-z])([A-Z])/g, "$1 $2").replace(/_/g, " ").trim().toLowerCase().replace(/\s+/g, " ");

// The words of a sport, hyphens as spaces: "e-bike" reads as "e bike".
const words = (sport) => normalSport(String(sport ?? "").replace(/-+/g, " "));

// The sports that have their own icon, each with the words that mean it
// (sports.json, which the server matches routines by too). Anything else
// gets the general activity icon.
const FAMILY = new Map(Object.entries(SPORTS).flatMap(([family, list]) => list.map((word) => [words(word), family])));

// The icon family a sport belongs to (run, ride, ...), or "activity".
export const sportFamily = (sport) => FAMILY.get(words(sport)) ?? "activity";

// The sprite id of a sport's icon.
export const sportIcon = (sport) => `sport-${sportFamily(sport)}`;

// "Trail run", also for "trail_run" as another app may send it.
export function sportLabel(sport) {
  const text = words(sport);
  return text ? text[0].toUpperCase() + text.slice(1) : "Activity";
}

// What a row calls an activity: its title, else its sport.
export const activityTitle = (activity) => activity.title || sportLabel(activity.sport);

// "5.2 km" or "3.2 mi", one decimal (none from 100 on).
export function formatDistance(metres, unit) {
  if (metres == null) return "";
  const value = unit === "mi" ? metres / METRES_PER_MILE : metres / 1000;
  const shown = value >= 100 ? Math.round(value).toString() : value.toFixed(1);
  return `${shown} ${unit === "mi" ? "mi" : "km"}`;
}

// Climb goes with the distance unit: metres with km, feet with mi.
export function formatClimb(metres, unit) {
  if (metres == null) return "";
  return unit === "mi" ? `${Math.round(metres * FEET_PER_METRE)} ft` : `${Math.round(metres)} m`;
}

// "45 min", "1 h 05", or "40 s" under a minute.
export function formatDuration(seconds) {
  if (seconds == null) return "";
  if (seconds < 60) return `${Math.round(seconds)} s`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min`;
  return `${Math.floor(minutes / 60)} h ${String(minutes % 60).padStart(2, "0")}`;
}

// The numbers a row shows, in order: distance, time, climb.
export function activityFacts(activity, unit) {
  return [
    formatDistance(activity.distance_m, unit),
    formatDuration(activity.moving_seconds ?? activity.elapsed_seconds),
    activity.climb_m ? `${formatClimb(activity.climb_m, unit)} climb` : "",
  ].filter(Boolean);
}

// A distance typed in the shown unit, as whole metres; null when blank,
// NaN when it isn't a number of 0 or more.
export function distanceInMetres(text, unit) {
  const value = number(text);
  if (value == null || Number.isNaN(value)) return value;
  return Math.round(unit === "mi" ? value * METRES_PER_MILE : value * 1000);
}

// A climb typed in m (with km) or ft (with mi), as whole metres.
export function climbInMetres(text, unit) {
  const value = number(text);
  if (value == null || Number.isNaN(value)) return value;
  return Math.round(unit === "mi" ? value / FEET_PER_METRE : value);
}

// A time typed as minutes ("45"), or as a watch shows it: m:ss ("25:13")
// or h:mm:ss ("1:05:30"); as seconds, null when blank, NaN when it can't be
// read.
export function durationInSeconds(text) {
  const value = String(text ?? "").trim();
  if (!value) return null;
  if (/^\d+(\.\d+)?$/.test(value)) return Math.round(Number(value) * 60);
  const parts = value.split(":");
  if (parts.length > 3 || parts.some((p) => !/^\d+$/.test(p)) || parts.slice(1).some((p) => Number(p) >= 60)) return NaN;
  return parts.reduce((total, part) => total * 60 + Number(part), 0);
}

function number(text) {
  const value = String(text ?? "").trim().replace(",", ".");
  if (!value) return null;
  return /^\d+(\.\d+)?$/.test(value) ? Number(value) : NaN;
}

// ---------- Requests ----------

// How an activity is told apart before it has an id: by its client_ref.
export const activityKey = (activity) => (activity.id != null ? String(activity.id) : activity.client_ref);

// Where an activity is on the server: its id, or until it has one the name
// its create is saved under in the outbox.
export function activityPath(activity) {
  return activity.id != null ? `/api/activities/${activity.id}` : `/api/activities/{${activity.client_ref}}`;
}

// Logs an activity done on `date`. `id` names the create, so a retry is
// recognised and later changes can refer to it before the server answers.
// `today` is the device's, which the date may not be after. Blank fields
// are left out.
export function logRequest({ id, today, ...fields }) {
  const ref = `activity:${id}`;
  const body = { client_ref: ref, today };
  for (const [name, value] of Object.entries(fields)) {
    if (value == null || value === "") continue;
    body[name] = typeof value === "string" ? value.trim() : value;
  }
  return { method: "POST", path: "/api/activities", saveAs: ref, body };
}

// Changes an activity: its RPE, note, or any other field (null clears it).
export function changeRequest(activity, changes, today) {
  return { method: "PATCH", path: activityPath(activity), body: { ...changes, today } };
}

export function deleteRequest(activity) {
  return { method: "DELETE", path: activityPath(activity) };
}

// The fields a queued change can set on an activity shown.
const SHOWN_FIELDS = ["date", "started_at", "sport", "title", "moving_seconds", "elapsed_seconds", "distance_m", "climb_m", "avg_hr", "max_hr", "rpe", "note", "routine_id", "routine_date"];

// The activities as they will be once the queued requests are sent: logs
// added, changes and deletions applied. Requests that are not about
// activities are left out. An activity shown before the server has it, or
// with a change not sent yet, carries `pending: true`.
export function withQueuedActivities(activities, queue) {
  let list = activities.map((a) => ({ ...a }));
  const find = (path) => {
    const match = path.match(/^\/api\/activities\/(?:(\d+)|\{([^}]+)\})$/);
    if (!match) return null;
    return list.find((a) => (match[1] ? a.id === Number(match[1]) : a.client_ref === match[2])) ?? null;
  };
  for (const entry of queue) {
    if (entry.method === "POST" && entry.path === "/api/activities" && entry.body?.client_ref && !entry.body.activities) {
      const { client_ref } = entry.body;
      if (list.some((a) => a.client_ref === client_ref)) continue;
      const shown = Object.fromEntries(SHOWN_FIELDS.map((name) => [name, entry.body[name] ?? null]));
      list.push({ ...shown, id: null, client_ref, sport: normalSport(shown.sport), source: null, external_id: null, created_by: "manual", pending: true });
      continue;
    }
    const activity = find(entry.path);
    if (!activity) continue;
    if (entry.method === "DELETE") {
      list = list.filter((a) => a !== activity);
    } else if (entry.method === "PATCH") {
      for (const name of SHOWN_FIELDS) if (entry.body && name in entry.body) activity[name] = entry.body[name];
      if (entry.body && "sport" in entry.body) activity.sport = normalSport(activity.sport);
      activity.pending = true;
    }
  }
  return inOrder(list);
}

// The ids of the activities the outbox deletes.
export function removedActivityIds(queue) {
  return new Set(queue.flatMap((entry) => {
    const match = entry.method === "DELETE" && entry.path.match(/^\/api\/activities\/(\d+)$/);
    return match ? [Number(match[1])] : [];
  }));
}

// By day, then by start (as logged when no start was given), as the server
// orders them; ones not sent yet go last.
export function inOrder(activities) {
  const stamp = (time) => (time ? new Date(time).toISOString() : "~");
  const key = (a) => `${a.date} ${stamp(a.started_at ?? a.created_at)}`;
  return [...activities].sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : (a.id ?? Infinity) - (b.id ?? Infinity)));
}

// Activities by day: { "2026-10-28": [...] }.
export function byDay(activities) {
  const days = {};
  for (const activity of inOrder(activities)) (days[activity.date] ??= []).push(activity);
  return days;
}

// ---------- How hard was it ----------

const ASKED_KEY = "rpeAsked";
// The ids already asked about on this device, newest last.
const KEEP_ASKED = 50;

// The activity Today asks how hard it was: the first of the day's with no
// RPE that came from elsewhere (a `source`) or from the coach agent (one
// logged by hand was the person's own choice), not asked about on this
// device before. Null when the prompt is off, or there is none.
export function rpeToAsk(activities, { asked = [], enabled = true } = {}) {
  if (!enabled) return null;
  return inOrder(activities).find((a) => a.id != null && a.rpe == null && !a.pending &&
    (a.source != null || a.created_by === "llm") && !asked.includes(a.id)) ?? null;
}

export function readAsked(storage) {
  try {
    const ids = JSON.parse(storage.getItem(ASKED_KEY));
    return Array.isArray(ids) ? ids.filter(Number.isInteger) : [];
  } catch {
    return [];
  }
}

// Remembers that an activity was asked about, keeping the newest 50.
export function rememberAsked(storage, id) {
  const ids = [...readAsked(storage).filter((known) => known !== id), id].slice(-KEEP_ASKED);
  try {
    storage.setItem(ASKED_KEY, JSON.stringify(ids));
  } catch {
    // Blocked: it may ask again on the next visit.
  }
  return ids;
}

// ---------- The distance unit ----------

// km or mi, as this device last saw it (the server's copy wins once read).
export function preferredDistanceUnit(storage) {
  try {
    const unit = storage.getItem(DISTANCE_KEY);
    return DISTANCE_UNITS.includes(unit) ? unit : "km";
  } catch {
    return "km";
  }
}

export function setPreferredDistanceUnit(storage, unit) {
  if (!DISTANCE_UNITS.includes(unit)) throw new Error(`unknown distance unit ${unit}`);
  try {
    storage.setItem(DISTANCE_KEY, unit);
  } catch {
    // Storage blocked: the setting is not kept.
  }
}

export function distanceUnitRequest(unit) {
  if (!DISTANCE_UNITS.includes(unit)) throw new Error(`unknown distance unit ${unit}`);
  return { method: "PATCH", path: SETTINGS_PATH, body: { distance_unit: unit } };
}

// The unit to show once the server has answered with its own: kept as this
// device's copy, unless a change made here is still queued, or the answer is
// an offline copy that may predate it.
export function adoptServerDistanceUnit(storage, unit, { queued = [], stale = false } = {}) {
  const changing = queued.some((entry) => entry.path === SETTINGS_PATH && entry.body && "distance_unit" in entry.body);
  if (stale || !DISTANCE_UNITS.includes(unit) || changing) return preferredDistanceUnit(storage);
  setPreferredDistanceUnit(storage, unit);
  return unit;
}

// Where an activity came from: "From Garmin · copied by Coach agent, Nov 14",
// "From Garmin" for one a script sent, "Logged by Coach agent" for one an
// agent wrote down, or "Logged by you".
export function activityOrigin(activity, today = localToday()) {
  const when = activity.created_at ? `, ${writtenDay(activity.created_at, today)}` : "";
  const source = activity.source ? `From ${sourceLabel(activity.source)}` : null;
  if (activity.created_by === "llm") return source ? `${source} · copied by ${agentName(activity)}${when}` : `Logged by ${agentName(activity)}${when}`;
  return source ?? "Logged by you";
}

// A source as people write it: garmin is Garmin, apple_health Apple Health.
// One sent with capitals (iPhone) is kept as sent.
export function sourceLabel(source) {
  const text = String(source);
  if (/\p{Lu}/u.test(text)) return text;
  return text.replace(/_/g, " ").replace(/(^|\s)(\p{L})/gu, (_, gap, letter) => gap + letter.toUpperCase());
}
