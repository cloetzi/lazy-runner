// The requests a session run sends to the server, kept free of the DOM so the
// order and the bodies can be tested. Each function returns outbox entries;
// the caller queues them. The session is named by `run.ref` until the server
// gives it an id, so sets and the finish can be queued while offline.

const sessionPath = (run) => `/api/sessions/{${run.ref}}`;

// Remembers an exercise's weight for next time; null remembers no weight.
export function weightRequest(exerciseId, weight) {
  return { method: "PATCH", path: `/api/exercises/${exerciseId}/weight`, body: weight ?? { value: null } };
}

// Marks the day skipped: the day's session if there is one, a new one if not.
export function skipRequest(today, id) {
  const { session, workout_id, date } = today;
  if (session) return { method: "PATCH", path: `/api/sessions/${session.id}`, body: { status: "skipped" } };
  return { method: "POST", path: "/api/sessions", body: { workout_id, date, status: "skipped", client_ref: `skip:${id}` } };
}

// Starts the session once the player starts: the day's session again when it
// has one (the outbox is told its id under `run.ref`), otherwise a new one
// the server can recognise by `client_ref` when the create is sent twice.
// `started_at` is the device's clock, so a start synced late keeps its time.
export function startRequest(run, now = new Date()) {
  const parts = run.parts && { parts: run.parts };
  const started_at = now.toISOString();
  if (run.sessionId) return { method: "PATCH", path: sessionPath(run), body: { status: "in_progress", started_at, ...parts } };
  return {
    method: "POST", path: "/api/sessions", saveAs: run.ref,
    body: { workout_id: run.workoutId, date: run.date, status: "in_progress", client_ref: run.ref, started_at, ...parts },
  };
}

// One set. `set_number` is the round of its block; `exercise_id` goes only
// with a swapped exercise (the step names the planned one). A hold ended
// early logs the seconds held. A skipped set keeps its weight but no reps or
// seconds. What the plan showed rides along (planned exercise, block and
// target), so the set is kept even if the workout was edited elsewhere and
// its step is gone by the time the set reaches the server.
export function setRequest(run, item, status, { reps = item.reps, seconds = item.seconds } = {}) {
  const planned = item.planned ?? item;
  const body = {
    step_id: item.step_id, set_number: item.block.round, side: item.side, status, weight: item.weight,
    planned_exercise_id: planned.exercise.id, block_label: item.block.label,
    target: { reps: planned.reps ?? null, seconds: planned.seconds ?? null, weight: planned.weight ?? null },
  };
  if (item.planned) body.exercise_id = item.exercise.id;
  if (item.mode === "reps") body.reps = status === "done" ? reps : null;
  else body.seconds = status === "done" ? seconds : null;
  return { method: "POST", path: `${sessionPath(run)}/sets`, body };
}

// The kept weight changes first, so the suggestion for next time is worked
// out from them, then the finish, timed by the device's clock so a finish
// synced late keeps its place in the day. Its answer is saved under `key`.
export function finishRequests(run, { rpe = null, feedback = null, now = new Date() } = {}) {
  const key = `complete:${run.id}`;
  const weights = Object.entries(run.weights)
    .filter(([, change]) => change.keep)
    .map(([id, change]) => weightRequest(id, change.to));
  const complete = {
    method: "POST", path: `${sessionPath(run)}/complete`, saveAs: key,
    body: { rpe, feedback, ended_early: !!run.endedEarly, finished_at: now.toISOString() },
  };
  return { key, requests: [...weights, complete] };
}

// Deletes a discarded session. Nothing reached the server before the player
// started, so a run still on Get ready needs nothing.
export function discardRequest(run) {
  if (run.stage === "ready") return null;
  return { method: "DELETE", path: sessionPath(run) };
}
