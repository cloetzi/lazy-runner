// How a week adds up, kept free of the DOM so node can test it: what was
// planned against what was done, by kind (strength first, then each sport
// family), with the plain sum of the distance a sport covered. Counts and
// sums only: no score, load or pace.
//
// Strength is the week's workout sessions (a warm-up or cool-down done on
// its own is not one) and any strength activity logged on a day without a
// done session (on such a day it is that session, synced from a watch). A
// sport is its activities against its routine days: a routine day done is
// done by an activity, so the activities are what count as done.

import SPORTS from "./sports.json" with { type: "json" };
import { sportFamily, formatDistance, withQueuedActivities, removedActivityIds } from "./activities.js";
import { withQueued, inOrder, shownStatus, dayName } from "./calendar.js";
import { withActivities } from "./routines.js";

// Each kind's name for one and for several.
const NAMES = {
  strength: ["strength", "strength"], run: ["run", "runs"], ride: ["ride", "rides"], hike: ["hike", "hikes"],
  walk: ["walk", "walks"], ski: ["ski day", "ski days"], swim: ["swim", "swims"], climb: ["climb", "climbs"],
  yoga: ["yoga", "yoga"], activity: ["other", "other"],
};
const ORDER = ["strength", ...Object.keys(SPORTS).filter((family) => family !== "strength"), "activity"];

// The week's kinds, in order, each { kind, done, of, distance_m, facts },
// where `of` is how many were planned in all (null when nothing was planned
// beyond what was done) and `facts` counts the rest: ended early, missed,
// skipped, maybe. `sessions` and `activities` as the server gives them (a
// session's status already reads missed); `routineDays` as they read on
// the device's today, with their `routines`.
export function weekSummary({ sessions = [], activities = [], routineDays = [], routines = [] }) {
  const kinds = new Map();
  const kind = (name) => kinds.get(name) ?? kinds.set(name, { kind: name, done: 0, planned: 0, distance_m: 0, endedEarly: 0, missed: 0, skipped: 0, maybe: 0 }).get(name);

  const doneDays = new Set();
  for (const session of sessions) {
    if (session.workout?.kind && session.workout.kind !== "workout") continue;
    const k = kind("strength");
    if (session.status === "skipped") { k.skipped += 1; continue; }
    k.planned += 1;
    if (session.status === "done") {
      doneDays.add(session.date);
      if (session.completion?.ended_early) k.endedEarly += 1;
      else k.done += 1;
    }
    if (session.status === "missed") k.missed += 1;
  }

  const byId = new Map(routines.map((r) => [r.id, r]));
  for (const day of routineDays) {
    const routine = byId.get(day.routine_id);
    // A workout routine's day with a session is that session, counted above.
    if (!routine || day.session_id != null) continue;
    const k = kind(routine.sport ? sportFamily(routine.sport) : "strength");
    if (day.state === "tentative") k.maybe += 1;
    else if (day.state === "skipped") k.skipped += 1;
    else if (day.state === "missed") { k.planned += 1; k.missed += 1; }
    else if (day.state === "confirmed") k.planned += 1;
  }

  for (const activity of activities) {
    const family = sportFamily(activity.sport);
    if (family === "strength" && doneDays.has(activity.date)) continue;
    const k = kind(family);
    k.done += 1;
    // A strength session counts in what was planned once done; an activity
    // the same, so "1 of 2" is one of two whichever logged it.
    if (family === "strength") k.planned += 1;
    k.distance_m += activity.distance_m ?? 0;
  }

  return ORDER.filter((name) => kinds.has(name)).map((name) => {
    const k = kinds.get(name);
    // Strength's planned holds what was done. Done days of a sport are its
    // activities, and its planned ones not done the confirmed and missed
    // days; an extra run counts too.
    const of = name === "strength" ? k.planned : k.done + k.planned;
    const facts = [
      k.endedEarly && `${k.endedEarly} ended early`,
      k.missed && `${k.missed} missed`,
      k.skipped && `${k.skipped} skipped`,
      k.maybe && `${k.maybe} maybe`,
    ].filter(Boolean);
    return { kind: name, done: k.done, of: of > k.done ? of : null, distance_m: k.distance_m, facts };
  });
}

// GET /api/coach's week (`from`, `to`, `sessions`, `activities`,
// `routines`, `routine_days`) as weekSummary takes it, with what the outbox
// still holds laid over it and each session and routine day read on `today`,
// the way the Calendar shows them.
export function queuedWeek(week, queue, today) {
  const within = (date) => date >= week.from && date <= week.to;
  const activities = withQueuedActivities(week.activities ?? [], queue).filter((a) => within(a.date));
  return {
    sessions: withQueued(week.sessions ?? [], queue, today).filter((s) => within(s.date)),
    activities,
    routines: week.routines ?? [],
    routineDays: withActivities(week.routine_days ?? [], week.routines ?? [], activities, today, removedActivityIds(queue)).filter((d) => within(d.on)),
  };
}

// One kind as a line: { count: "1 of 2", label: "runs", facts: ["14.6 km", "1 maybe"] }.
// Strength says "0 of 2" even with none done; a sport with nothing more
// planned says just how many.
export function summaryLine(entry, unit) {
  const [one, many] = NAMES[entry.kind] ?? NAMES.activity;
  const total = entry.of ?? entry.done;
  return {
    count: entry.of != null ? `${entry.done} of ${entry.of}` : String(entry.done),
    label: total === 1 ? one : many,
    facts: [entry.distance_m > 0 && formatDistance(entry.distance_m, unit), ...entry.facts].filter(Boolean),
  };
}

// The concerns as "Watching" lines: their titles.
export const watching = (concerns = []) => concerns.map((c) => c.title || c.body);

// The Saved card's lead, once a session is finished: how the week's strength
// sessions stand ("This week: 2 of 3 strength sessions done", with what else
// is known of them), or null when the week has none.
export function strengthWeekLine(week) {
  const entry = weekSummary(week).find((e) => e.kind === "strength");
  if (!entry) return null;
  const total = entry.of ?? entry.done;
  const count = entry.of != null ? `${entry.done} of ${entry.of}` : String(entry.done);
  return [`This week: ${count} strength ${total === 1 ? "session" : "sessions"} done`, ...entry.facts].join(" · ");
}

// When the next workout session of the week is planned ("Next: Workout 2,
// Thursday"), or null when nothing more is planned this week. A warm-up or
// cool-down planned on its own is not one.
export function nextSessionLine(sessions, today) {
  const next = inOrder(sessions).find((s) => (!s.workout?.kind || s.workout.kind === "workout") && shownStatus(s, today) === "planned");
  if (!next) return null;
  const day = next.date === today ? "later today" : dayName(next.date, today);
  return `Next: ${next.workout.title}, ${day === "Tomorrow" ? "tomorrow" : day}`;
}
