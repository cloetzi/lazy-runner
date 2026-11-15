import { paths } from "./api.js";
import { rangeFor } from "./calendar.js";

// Today's session as the service worker's cache last saw it, made safe to
// start offline. A copy from an earlier day still has that day's session in
// it; starting from it would reopen that session, so it is dropped and the
// workout is planned for `date` instead. Its day's other sessions go too, and
// the next planned session stays only while it is still ahead (one planned
// for the new day itself has no plan in the copy to start it from). The old
// day's activities go too.
export function offlineToday(today, date) {
  if (today.date === date) return { ...today, offline: true };
  const next = today.next_planned?.date > date ? today.next_planned : null;
  return { ...today, date, session: null, source: "default", day: [], activities: [], next_planned: next, offline: true };
}

// Fetching ahead (#267): while online, the device fetches what the pages
// read, so the whole app opens offline, not only what was opened before:
// every workout (its view, and Today's start of it), this week and this
// month on the calendar with what is up next, the coach board, history, and
// the lists and settings the pages share. Only fetched: the service worker
// keeps each answer (sw.js), under the address the page asks for later.
// Coach notes and goals are read here but written online only.

// When this device last fetched ahead, a user's thing (account.js forgets
// it): "<date> <time in ms>". The pages refresh what they open themselves,
// so this only has to catch up now and then, and on a new day.
export const AHEAD_KEY = "ahead";
export const AHEAD_EVERY_MS = 30 * 60 * 1000;
// Workouts fetched ahead at most; each costs the cache three entries.
export const AHEAD_WORKOUTS = 50;

// Every address to fetch on `date` for the workouts `workoutIds`.
export function aheadPaths(date, workoutIds) {
  const week = rangeFor("week", date);
  const month = rangeFor("month", date);
  return [
    paths.today({ date }),
    ...[week, month].map(({ from, to }) => paths.calendar({ from, to, today: date })),
    paths.upcoming(date),
    paths.coach(date),
    paths.history(date),
    paths.exerciseHistory,
    paths.settings,
    paths.exercises,
    paths.equipment,
    ...workoutIds.slice(0, AHEAD_WORKOUTS).flatMap((id) => [paths.workout(id), paths.today({ date, workoutId: id })]),
  ];
}

// After a stop, the next try waits this long (not AHEAD_EVERY_MS), so a slow
// link doesn't start the whole round again on every page.
export const AHEAD_RETRY_MS = 2 * 60 * 1000;

// Fetches ahead, unless it did on `date` less than AHEAD_EVERY_MS ago
// (`force` skips that wait). Resolves to "done", "skipped", or "stopped":
// when the server is out of reach or slow (the worker answered from its
// copy), wants a sign-in (a 401 or a redirect to a sign-in page in front of
// the app), or `halt()` turns true (a session started).
export async function fetchAhead({ storage, date, fetchFn = fetch, now = Date.now(), force = false, halt = () => false }) {
  const [day, at] = String(read(storage) ?? "").split(" ");
  const last = Number.parseInt(at, 10);
  if (!force && day === date && last <= now && now - last < AHEAD_EVERY_MS) return "skipped";
  write(storage, `${date} ${now}`);
  let stopped = false;
  const usable = (response) => response.headers.get("x-served-from") !== "cache" && !response.redirected &&
    ![401, 403, 407].includes(response.status);
  try {
    const list = await fetchFn(paths.workouts);
    if (!list.ok || !usable(list)) throw new Error("stopped");
    const ids = (await list.json()).flatMap((program) => program.workouts.map((workout) => workout.id));
    // Two at a time: the server answers from one database connection. Once
    // one stops, the other takes no more.
    const queue = aheadPaths(date, ids);
    const next = async () => {
      for (let path = queue.shift(); path && !stopped; path = queue.shift()) {
        if (halt() || !usable(await fetchFn(path))) {
          stopped = true;
          throw new Error("stopped");
        }
      }
    };
    await Promise.all([next(), next()]);
    return "done";
  } catch {
    stopped = true;
    write(storage, `${date} ${now - AHEAD_EVERY_MS + AHEAD_RETRY_MS}`);
    return "stopped";
  }
}

function read(storage) {
  try {
    return storage?.getItem(AHEAD_KEY);
  } catch {
    return null;
  }
}

function write(storage, value) {
  try {
    if (value == null) storage?.removeItem(AHEAD_KEY);
    else storage?.setItem(AHEAD_KEY, value);
  } catch {
    // Blocked storage: it fetches ahead on every page load instead.
  }
}
