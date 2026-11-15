import { addDays } from "./calendar.js";

// Reads from the API. `stale` is true when the service worker answered from
// its cache because the server was out of reach, so a view can say it is
// showing an offline copy. With no answer at all (offline, and no copy), the
// error is `unreachable`, which `loadProblem` puts in words.
export async function getJson(path, fetchFn = fetch) {
  let response;
  try {
    response = await fetchFn(path);
  } catch (cause) {
    throw Object.assign(new Error(cause?.message ?? "Failed to fetch", { cause }), { unreachable: true });
  }
  if (!response.ok) {
    let code;
    try {
      code = (await response.json())?.error?.code;
    } catch {
      // Not the API's JSON error (a proxy's page, say).
    }
    throw Object.assign(new Error(`HTTP ${response.status}`), { status: response.status, code });
  }
  return { data: await response.json(), stale: response.headers.get("x-served-from") === "cache" };
}

// Writes to the API. Every write goes through here or the outbox, so each
// sends what the server's CSRF check wants: a JSON body (or none), from this
// page's origin (the browser adds Sec-Fetch-Site and Origin), and Accept so
// the sign-in routes answer in JSON.
// `user` is the id of the user the change is for (the outbox's entries): the
// server refuses it, 409 user_mismatch, when someone else is signed in.
// `redirect: "manual"` keeps a sign-in page in front of the app from
// passing for the app's answer.
export function send(path, { method = "POST", body, fetchFn = fetch, user, redirect } = {}) {
  const headers = body === undefined ? { Accept: "application/json" } : { "Content-Type": "application/json", Accept: "application/json" };
  if (user != null) headers["X-Lazy-Runner-User"] = String(user);
  return fetchFn(path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    ...(redirect ? { redirect } : {}),
  });
}

// Sends a change now (not through the outbox), for a sheet that stays open
// until it is saved: resolves to the problem to show, or null once the
// server has taken it.
export async function sendChange({ method, path, body }, fetchFn = fetch) {
  try {
    const response = await send(path, { method, body, fetchFn });
    if (response.ok) return null;
    let json = null;
    try {
      json = await response.json();
    } catch {
      // Not the API's JSON error.
    }
    return errorMessage(json, response.status);
  } catch {
    return offline() ? "You're offline, and this needs a connection. Try again once you're back online." : "Can't reach the server. Try again once you're online.";
  }
}

// What a sheet that saves straight away (a coach note, a goal, a routine)
// says while the device is offline: unlike the rest, it isn't queued (#267).
export const NEEDS_CONNECTION = "You're offline, and this needs a connection to save. Keep it open and save it once you're back online.";

// Whether the browser knows it has no network. (It can't tell the other way
// round: online may still mean the server is out of reach.)
export const offline = (nav = globalThis.navigator) => nav?.onLine === false;

// Whether a `getJson` error means the server wasn't reached: no answer at
// all, or a proxy in front of the app answering for a server that is down.
export const unreachable = (error) => Boolean(error?.unreachable) || [502, 503, 504].includes(error?.status);

// The sentence a page shows when it couldn't load `what` ("the calendar").
// Out of reach with no copy on the device, it says so in words rather than
// the browser's "Failed to fetch", and with `hint`, what still works.
export function loadProblem(what, error, { hint = true, nav = globalThis.navigator } = {}) {
  if (!unreachable(error)) return `Could not load ${what} (${error?.message}).`;
  const start = offline(nav) ? "You're offline" : "Can't reach the server";
  return `${start}, and this device has no copy of ${what} yet.${hint ? " Today and your workouts still work offline." : ""}`;
}

// The addresses the pages read, built in one place: what is fetched ahead
// (offline.js) is kept under the very address a page asks for later, so the
// service worker's copy answers it.
export const paths = {
  workouts: "/api/workouts",
  settings: "/api/settings",
  exercises: "/api/exercises",
  equipment: "/api/equipment",
  exerciseHistory: "/api/history/exercises",
  today({ date, workoutId, sessionId } = {}) {
    const query = new URLSearchParams({ date });
    if (workoutId) query.set("workout_id", workoutId);
    else if (sessionId) query.set("session_id", sessionId);
    return `/api/today?${query}`;
  },
  workout: (id) => `/api/workouts/${id}`,
  history: (date) => `/api/history?days=28&date=${date}`,
  calendar: ({ from, to, today }) => `/api/calendar?from=${from}&to=${to}&today=${today}`,
  // Planned and under way: under way since yesterday counts too, as a
  // session stays under way past midnight.
  upcoming: (today) => `/api/sessions?status=planned,in_progress&from=${addDays(today, -1)}`,
  coach: (today) => `/api/coach?today=${today}`,
  // The days before `today` whose activities Today may still ask about,
  // as one sent the next morning wasn't asked about on its own day.
  recentActivities: (today, days = 3) => `/api/activities?from=${addDays(today, -days)}&to=${addDays(today, -1)}`,
};

// The sentence an API error carries: every error is
// { error: { code, message, fields? } }.
export function errorMessage(json, status) {
  return json?.error?.message ?? `HTTP ${status}`;
}

// The note a view shows over an offline copy.
export const STALE_NOTE = "Offline copy: this may be out of date.";
