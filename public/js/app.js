import * as countdown from "./countdown.js";
import { beep, unlock } from "./beeper.js";
import { createOutbox } from "./outbox.js";
import { pageAccount, signInHref, syncNote } from "./account.js";
import { stepTargetWeight, sameWeight, sameShownWeight, inUnit, preferredUnit, adoptServerUnit, formatWeight, formatLoad } from "./weights.js";
import { createFigure } from "./figure-view.js";
import { openHowto, equipmentNames, loadEquipmentNames, knowsEquipmentNames } from "./howto.js";
import { escape, icon, authorLine } from "./html.js";
import { offlineToday } from "./offline.js";
import { blockName, blockSummary, stepSummary, alternatingText, setWeight, includedKinds, framingFor, framePlan, gearList } from "./workout.js";
import { previousIndex, switchesSides, mainActionLabel, plannedExercise, swapRun, resumeChoice, sessionProgress, endsEarly, loggedFromServer, pickUpIndex, partEnd, setLabel, minutesLeft, tempoText, leadInSeconds, extraSeconds, upNextDetails, equipmentChanges, finishSummary, RPE_ANCHORS } from "./player.js";
import { openSwap, prefetchAlternatives } from "./swap.js";
import { mountNav } from "./nav.js";
import { parseRoute, routeHash, pageFor, isSessionView } from "./routes.js";
import { setsSummary, sessionSummary, exerciseSummary } from "./history.js";
import { getJson, errorMessage, send, sendChange, STALE_NOTE } from "./api.js";
import { readSettings } from "./preferences.js";
import { weightRequest, skipRequest, startRequest, setRequest, finishRequests, discardRequest } from "./session-log.js";
import { createRunStore, restoredTimer } from "./run-store.js";
import { markFor, longDay, localToday, moveRequest, removeRequest, STATUS_LABELS } from "./calendar.js";
import { openSessionSheet, openLogActivitySheet, openRpeSheet, activityRow, editActivity } from "./calendar-sheets.js";
import { plannedBy } from "./coach.js";
import {
  withQueuedActivities, removedActivityIds, activityKey, preferredDistanceUnit, adoptServerDistanceUnit,
  logRequest, changeRequest, rpeToAsk, readAsked, rememberAsked,
} from "./activities.js";
import { openEditor, leaveEditor } from "./editor.js";
import {
  withActivities, listed, routineTitle, confirmRequest as confirmDayRequest, skipRequest as skipDayRequest,
  moveRequest as moveDayRequest, resetRequest as resetDayRequest,
} from "./routines.js";
import { routineRow, dayKey, openRoutineDaySheet } from "./routine-sheets.js";

// A kept session touched this recently reopens on load (a reload or an app
// switch mid-workout); an older one waits on Today for the user to choose.
const RESUME_WITHIN_MS = 2 * 60 * 60 * 1000;
const TICK_MS = 100;
const SYNC_EVERY_MS = 20_000;
// Whether sessions include the warm-up and the cool-down, as last chosen.
const FRAMING_KEY = "framing";
// How long the workout view waits after the last weight tap before saving.
const SAVE_WEIGHT_AFTER_MS = 1000;
// How long "Switch sides" stays up on a rep-based step.
const SWITCH_CUE_MS = 3000;
// How long a discarded session can be brought back before it is deleted.
const UNDO_DISCARD_MS = 6000;

const $ = (id) => document.getElementById(id);
const storage = safeStorage();
const runStore = createRunStore(storage);
const account = pageAccount(storage);
const outbox = createOutbox({ storage, fetch: (...args) => fetch(...args), locks: navigator.locks, user: account.id });
const nav = mountNav("today");

const state = {
  unit: preferredUnit(storage), // lb or kg, for showing weights
  distanceUnit: preferredDistanceUnit(storage), // km or mi, for showing distances
  framing: savedFraming(), // { warmup: false } leaves the warm-up out
  sessionFraming: {}, // session id -> framing, for a planned session with its own parts
  today: null,
  // The session being run, saved on every change so a reload picks it up.
  run: null,
  // An old session kept from before, not on screen until the user resumes it.
  parked: null,
  discarding: null, // { run, timer } for a discarded session while its undo shows
  phase: null, // "lead", "work" or "rest" while a countdown runs; "reps" while waiting for Done
  timer: null,
  lastElapsed: 0,
  wakeLock: null,
  rpe: null,
  feedback: null, // too_easy, right or too_hard, picked on the finish form
  figure: null, // { key, view } for the animation on screen
  workout: null, // the workout open in the workout view
  workoutNote: "", // said once under the workout when it opens, such as "Saved."
  shownHash: "", // the URL hash of the view on screen, for the editor to return to
  workoutFrom: "home", // the view its back button returns to
  weightSaves: {}, // exercise id -> weight changed in the workout view or on Get ready, not yet queued
  weightSaveTimer: null,
  switchCueUntil: 0, // "Switch sides" shows until then on a rep-based right side
};

// ---------- Home ----------

// The card shows the day's session up next, or `sessionId` (another of the
// day's sessions, picked from the list above it), or `workoutId` (a workout
// picked to train instead).
async function loadToday(workoutId, sessionId) {
  loadWeek();
  const query = new URLSearchParams({ date: localToday() });
  if (workoutId) query.set("workout_id", workoutId);
  else if (sessionId) query.set("session_id", sessionId);
  try {
    const { data: today, stale } = await getJson(`/api/today?${query}`);
    state.unit = adoptServerUnit(storage, today.unit, { queued: outbox.queued(), stale });
    state.distanceUnit = adoptServerDistanceUnit(storage, today.distance_unit, { queued: outbox.queued(), stale });
    // The service worker answered from its cache: the server is out of reach.
    state.today = stale ? offlineToday(today, localToday()) : today;
    state.today.pickedSession = Boolean(sessionId && !workoutId);
    renderToday();
    renderActivities();
    if (!stale) askHowHard();
    return true;
  } catch (error) {
    // A session picked from the list may be gone (or not cached offline):
    // fall back to the day's own card.
    if (sessionId && !workoutId) return loadToday();
    if (error.code === "no_workouts") return renderSetup();
    $("today").innerHTML = `<p>Could not load today's session (${escape(error.message)}).</p>
      <button class="secondary" id="retry">Try again</button>`;
    $("retry").onclick = () => loadToday(workoutId, sessionId);
    return false;
  }
}

// A new user's Today: nothing to train until they import an example program
// or build a workout.
function renderSetup() {
  state.today = null;
  $("today-date").textContent = "";
  $("today-day").hidden = true;
  $("today").innerHTML = `
    <h2>Nothing to train yet</h2>
    <p>Start from an example program, or build a workout of your own from the exercise library.</p>
    <div class="card-actions">
      <a class="button primary" href="/settings.html#examples" id="setup-examples">Example programs</a>
      <a class="button secondary" href="${routeHash("edit", "new")}">Build a workout</a>
    </div>`;
  // Nothing loaded: a caller waiting to start the session doesn't.
  return false;
}

// This week at a glance, beside the Today card on wide screens.
async function loadWeek() {
  try {
    const { data: history } = await getJson(`/api/history?days=7&date=${localToday()}`);
    const done = history.weeks[0]?.done ?? 0;
    const last = history.sessions.find((session) => session.status === "done");
    $("week").innerHTML = `
      <h2>This week</h2>
      <p class="week-count"><strong>${done}</strong> ${done === 1 ? "session" : "sessions"} done</p>
      ${last ? `<p class="muted">Last: ${escape(last.workout.title)}, ${escape(shortDate(last.date))}</p>` : ""}
      <a class="link" href="${routeHash("history")}">See history</a>`;
    $("week").hidden = false;
  } catch {
    $("week").hidden = true;
  }
}

// Reloads the card, keeping a picked workout or session picked.
function reloadToday() {
  const today = state.today;
  if (today?.source === "picked") return loadToday(today.workout_id);
  // A session picked from the list stays picked for its own day only.
  const keep = today?.pickedSession && today.date === localToday() && ["planned", "in_progress"].includes(today.session?.status);
  return loadToday(undefined, keep ? today.session.id : undefined);
}

// The parts the session runs. One under way or done keeps the ones it was
// started with; one planned with its own parts starts from those; otherwise
// the warm-up and cool-down follow the toggles.
function sessionKinds() {
  const { workouts, session } = state.today;
  if (["in_progress", "done"].includes(session?.status)) return workouts.filter((w) => w.included !== false).map((w) => w.kind);
  return includedKinds(workouts, framingNow());
}

// The framing the toggles show: a planned session's own, else the device's.
function framingNow() {
  const session = state.today.session;
  if (session?.status !== "planned") return state.framing;
  return state.sessionFraming[session.id] ?? framingFor(session.parts) ?? state.framing;
}

// The day's sessions in order, above the card when there is more than one.
// The one on the card is marked; a tap on another puts it on the card, or
// opens its log once it is done.
function renderDay() {
  const { day = [], session, date, source } = state.today;
  const list = $("today-day");
  // A rest day can still hold a warm-up or cool-down planned on its own.
  list.hidden = day.length < (source === "default" ? 1 : 2);
  if (list.hidden) return;
  list.innerHTML = day.map((s) => {
    const current = session?.id === s.id;
    const mark = current && ["planned", "in_progress"].includes(s.status) ? "next" : markFor(s, date, null);
    const meta = [current ? "On the card" : STATUS_LABELS[mark], `${s.workout.estimated_minutes} min`].join(" · ");
    return `
      <li class="cal-row${current ? " is-next" : ""}">
        <button class="row" data-day-session="${s.id}" data-status="${s.status}"${current ? ` aria-current="true"` : ""}>
          <span class="mark ${mark}" aria-hidden="true"></span>
          <span class="row-text">
            <span class="row-title${s.status === "skipped" ? " struck" : ""}">${escape(s.workout.title)}</span>
            <span class="row-meta">${escape(meta)}</span>
          </span>
        </button>
      </li>`;
  }).join("");
}

function renderToday() {
  const { title, subtitle, workouts, session, source, offline } = state.today;
  const status = session?.status;
  const kinds = sessionKinds();
  const toggles = workouts.length > 1 && !["in_progress", "done"].includes(status);
  const parts = workouts.map((w) => {
    const on = kinds.includes(w.kind);
    const toggle = toggles ? `<input type="checkbox" class="part-toggle" data-part="${w.kind}"${on ? " checked" : ""}${w.kind === "workout" ? " disabled" : ""} aria-label="Include the ${escape(w.title)}">` : "";
    return `<li class="${[toggles && "part-row", !on && "left-out"].filter(Boolean).join(" ")}">${toggle}<button class="row" data-view="${w.id}">
      <span class="row-text"><span class="row-title">${escape(w.title)}</span><span class="row-meta">${w.estimated_minutes} min</span></span>${icon("chevron-right")}</button></li>`;
  }).join("");
  const estimated_minutes = workouts.filter((w) => kinds.includes(w.kind)).reduce((sum, w) => sum + w.estimated_minutes, 0);
  $("today-date").textContent = new Date(`${state.today.date}T12:00`)
    .toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });
  renderDay();
  const note = `${session?.note ? `<p class="planner-note">${escape(session.note)}</p>` : ""}${authorLine(plannedBy(session, state.today.date), "p")}`;

  if (status === "done" && session.completion?.ended_early) {
    const { exercises, done } = sessionProgress({ items: state.today.plan.items, logged: loggedFromServer(state.today.plan.items, state.today.logged) });
    $("today").innerHTML = `
      <h2>${escape(title)}</h2>
      <p>You did part of ${escape(title)} today: ${done} of ${exercises} exercises.</p>
      <ul class="list parts">${parts}</ul>
      <button class="primary" id="start">Pick up again</button>
      <button class="secondary" id="pick">Pick another</button>`;
    $("start").onclick = startSession;
    $("pick").onclick = () => go("#workouts");
    return;
  }

  if (status === "done") {
    $("today").innerHTML = `
      <h2>${escape(title)} <span class="done-check">${icon("check", "done")}</span></h2>
      <p>Done for today. Nice work.</p>
      <ul class="list parts">${parts}</ul>
      <button class="secondary" id="pick">Train again</button>`;
    $("pick").onclick = () => go("#workouts");
    return;
  }

  const offlineNote = offline ? `<p class="muted">Offline: this is the last plan the app saw. What you log syncs later.</p>` : "";

  // Nothing on the calendar today: a rest day, which offers to bring the
  // next planned session forward, else the rotation's next workout.
  if (source === "default") {
    const next = state.today.next_planned;
    const heading = state.today.day?.length ? "No workout planned today" : "Nothing planned today";
    $("today").innerHTML = next ? `
      <p class="muted">Rest day</p>
      <h2>${heading}</h2>
      <p>Next on the calendar: <strong>${escape(next.workout.title)}</strong>, ${escape(longDay(next.date))}.</p>
      ${next.note ? `<p class="planner-note">${escape(next.note)}</p>` : ""}
      ${authorLine(plannedBy(next, state.today.date), "p")}
      ${offlineNote}
      <button class="primary" id="bring-forward">Do it today</button>
      <button class="secondary" id="pick">Pick another</button>` : `
      <p class="muted">Rest day</p>
      <h2>${heading}</h2>
      <p>Rest, or train anyway: next in the rotation is ${escape(title)}${subtitle ? `, ${escape(subtitle)}` : ""}.</p>
      ${offlineNote}
      <ul class="list parts">${parts}</ul>
      <p class="muted">About ${estimated_minutes} minutes</p>
      <button class="primary" id="start">Train anyway</button>
      <button class="secondary" id="pick">Pick another</button>`;
    if ($("start")) $("start").onclick = startSession;
    if ($("bring-forward")) $("bring-forward").onclick = (event) => moveToToday(next, event.currentTarget);
    $("pick").onclick = () => go("#workouts");
    return;
  }

  const planned = status === "planned" && source === "session";
  $("today").innerHTML = `
    ${status === "skipped" ? `<p class="muted">Skipped today</p>` : source === "picked" ? `<p class="muted">Picked</p>` : ""}
    <h2>${escape(title)}</h2>
    <p>${escape(subtitle ?? "")}</p>
    ${note}
    ${offlineNote}
    <ul class="list parts">${parts}</ul>
    <p class="muted">About ${estimated_minutes} minutes</p>
    <button class="primary" id="start">${status === "skipped" ? "Train anyway" : "Start"}</button>
    ${status === "skipped" ? "" : `<div class="secondary-actions">
      ${planned ? `<button class="secondary" id="move">Move</button>` : ""}
      <button class="secondary" id="skip-today">Skip today</button>
    </div>`}
    <button class="link" id="pick">${source === "picked" ? "Pick another" : "Train something else"}</button>`;
  $("start").onclick = startSession;
  $("pick").onclick = () => go("#workouts");
  if ($("skip-today")) $("skip-today").onclick = skipToday;
  if ($("move")) $("move").onclick = moveSession;
}

// The session sheet for the planned session on the card: move it to another
// day, skip it or take it off the calendar.
function moveSession() {
  const session = state.today.session;
  openSessionSheet({
    session, today: state.today.date,
    on: {
      onMove: (date) => sendAndReload(moveRequest(session, date), $("move")),
      onSkip: skipToday,
      onRemove: () => sendAndReload(removeRequest(session), $("move")),
    },
  });
}

// Brings the next planned session forward to today.
function moveToToday(session, button) {
  return sendAndReload(moveRequest(session, state.today.date), button);
}

// Sends a calendar change and shows the day as the server has it then. While
// it waits in the outbox the card can't show it yet, so the button that
// asked for it says so instead of being pressed again.
async function sendAndReload(request, button) {
  outbox.enqueue(request);
  if (await sync()) return loadToday();
  if (button) {
    button.disabled = true;
    button.textContent = "Saved, waiting to sync";
  }
}

async function skipToday() {
  outbox.enqueue(skipRequest(state.today, uniqueId()));
  await sync();
  loadToday();
}

// ---------- Activities today ----------

// The day's activities as the server gave them, with what the outbox still
// holds laid over them.
function todayActivities() {
  const { date, activities = [] } = state.today;
  return withQueuedActivities(activities, outbox.queued()).filter((a) => a.date === date);
}

// The day's routine days (a run planned, a maybe-hike), read on the day,
// with the activities the outbox still holds ticking them off.
function todayRoutineDays() {
  const { date, routines = [], routine_days: days = [] } = state.today;
  return withActivities(days, routines, todayActivities(), date, removedActivityIds(outbox.queued()));
}

const todayRoutine = (day) => (state.today.routines ?? []).find((r) => r.id === day.routine_id);

// Under the card: what else is planned today (tentative or confirmed
// routine days), what was done, and a way to log it.
function renderActivities() {
  const list = todayActivities();
  const days = todayRoutineDays();
  const plans = listed(days);
  const fulfils = new Map(days.filter((d) => d.state === "done").map((d) => [String(d.activity_key ?? d.activity_id), routineTitle(todayRoutine(d))]));
  const section = $("today-activities");
  section.hidden = false;
  section.innerHTML = `
    ${plans.length ? `<h2>Planned today</h2>
      <ul class="list day-sessions">${plans.map((d) => routineRow(d, todayRoutine(d), state.distanceUnit, "data-today-routine", state.today.date)).join("")}</ul>` : ""}
    ${list.length ? `<h2>Activities today</h2>
      <ul class="list day-sessions">${list.map((a) => activityRow(a, state.distanceUnit, "data-today-activity", fulfils.get(activityKey(a)))).join("")}</ul>` : ""}
    <button class="link" id="log-activity">${icon("plus")}Log an activity</button>`;
}

// A routine day's change goes straight to the server, then Today reads again.
async function sendRoutineDay(request) {
  const problem = await sendChange(request);
  if (problem) return alert(problem);
  reloadToday();
}

function openTodayRoutine(key) {
  const day = todayRoutineDays().find((d) => dayKey(d) === key);
  const routine = day && todayRoutine(day);
  if (!routine) return;
  const today = state.today.date;
  openRoutineDaySheet({
    day, routine, unit: state.distanceUnit, today,
    on: {
      onConfirm: () => sendRoutineDay(confirmDayRequest(day, today)),
      onReset: () => sendRoutineDay(resetDayRequest(day, today)),
      onSkip: () => sendRoutineDay(skipDayRequest(day, today)),
      onMove: (date) => sendRoutineDay(moveDayRequest(day, date, today)),
      onLog: () => logActivity({ sport: routine.sport, about: `for ${routineTitle(routine)}` }),
      onEdit: () => { location.href = `/calendar.html#${day.on}`; },
    },
  });
}

// Sends an activity change: shown at once from the outbox, and read back
// from the server once it has it.
async function sendActivity(request) {
  outbox.enqueue(request);
  renderActivities();
  if (await sync()) reloadToday();
}

function logActivity({ sport = "", about = "" } = {}) {
  openLogActivitySheet({
    date: state.today.date, unit: state.distanceUnit, sport, about,
    onLog: (fields) => sendActivity(logRequest({ ...fields, id: uniqueId(), today: state.today.date })),
  });
}

function openTodayActivity(key) {
  const activity = todayActivities().find((a) => activityKey(a) === key);
  if (!activity) return;
  editActivity({ activity, unit: state.distanceUnit, today: state.today.date, send: sendActivity });
}

// Asks once how hard a new activity from elsewhere was, unless that is
// turned off on Settings, and only on Today with nothing else open.
function askHowHard() {
  if ($("home").hidden || state.run || document.querySelector("dialog[open]")) return;
  const activity = rpeToAsk(todayActivities(), { asked: readAsked(storage), enabled: readSettings(storage).askRpe });
  if (!activity) return;
  rememberAsked(storage, activity.id);
  openRpeSheet({
    activity, unit: state.distanceUnit,
    onRpe: (rpe) => sendActivity(changeRequest(activity, { rpe }, state.today.date)),
  });
}

// ---------- Workouts ----------

// Every workout by program: the main workouts first, then the warm-up and
// cool-down that frame each session.
async function openWorkouts() {
  show("workouts");
  $("workouts-list").innerHTML = `<p class="muted">Loading…</p>`;
  try {
    const { data: programs, stale } = await getJson("/api/workouts");
    if (programs.length === 0) {
      $("workouts-list").innerHTML = offlineNote(stale) + `
        <p>No workouts yet. Import an <a href="/settings.html#examples">example program</a>, or build one with New workout.</p>`;
      return;
    }
    $("workouts-list").innerHTML = offlineNote(stale) + programs.map((program) => {
      const mains = program.workouts.filter((w) => w.kind === "workout");
      const frame = program.workouts.filter((w) => w.kind !== "workout");
      return `
        <section class="program">
          ${programs.length > 1 ? `<h2>${escape(program.name)}</h2>` : ""}
          <div class="workout-grid">${mains.map(workoutCard).join("")}</div>
          ${frame.length ? `<h3>Every session</h3>
            <p class="muted">Each workout starts with the warm-up and ends with the cool-down. Leave them out on Today, or start one on its own.</p>
            <div class="workout-grid">${frame.map(workoutCard).join("")}</div>` : ""}
        </section>`;
    }).join("");
  } catch (error) {
    $("workouts-list").innerHTML = `<p>Could not load the workouts (${escape(error.message)}).</p>`;
  }
}

function workoutCard(workout) {
  const main = workout.kind === "workout";
  const minutes = workout.framed_minutes > workout.estimated_minutes
    ? `${workout.estimated_minutes} min, ${workout.framed_minutes} with warm-up and cool-down`
    : `${workout.estimated_minutes} min`;
  const facts = [`${icon("clock")}${minutes}`];
  if (main) facts.push(workout.last_done ? `Last done ${escape(shortDate(workout.last_done))}` : "Not done yet");
  const equipment = equipmentNames(workout.equipment);
  const shown = workout.exercises.slice(0, 4).map((name) => `<li>${escape(name)}</li>`);
  if (workout.exercises.length > 4) shown.push(`<li>+${workout.exercises.length - 4} more</li>`);
  return `
    <article class="card workout-card${workout.up_next ? " up-next" : ""}">
      <a class="workout-link" href="${routeHash("workout", workout.id)}">
        <h3>${escape(workout.title)}${workout.up_next ? ` <span class="badge">Up next</span>` : ""}</h3>
        ${workout.subtitle ? `<p class="muted">${escape(workout.subtitle)}</p>` : ""}
        <p class="facts">${facts.map((fact) => `<span>${fact}</span>`).join("")}</p>
        <ul class="workout-exercises">${shown.join("")}</ul>
        ${equipment.length ? `<ul class="equipment-list small" aria-label="Equipment">${equipment.map((name) => `<li>${escape(name)}</li>`).join("")}</ul>` : ""}
      </a>
      <div class="workout-actions">
        <a class="button secondary small" href="${routeHash("workout", workout.id)}">View</a>
        <button class="${main ? "primary" : "secondary"} small" data-start="${workout.id}">Start</button>
      </div>
    </article>`;
}

// ---------- Workout view ----------

// The whole workout outside a session. Weight changes are remembered for the
// exercise straight away (through the outbox), so the next session uses them;
// a running session keeps the weights it started with.
async function openWorkout(id) {
  state.workoutFrom = $("home").hidden ? "workouts" : "home";
  $("workout-back").innerHTML = `${icon("chevron-left")}${state.workoutFrom === "home" ? "Today" : "Workouts"}`;
  state.workout = null;
  $("workout-title").textContent = "";
  $("workout-subtitle").textContent = "";
  $("workout-saved").textContent = state.workoutNote;
  state.workoutNote = "";
  $("workout-start").hidden = true;
  $("workout-own").hidden = true;
  $("workout-blocks").innerHTML = `<p class="muted">Loading…</p>`;
  show("workout", id);
  try {
    const { data, stale } = await getJson(`/api/workouts/${id}`);
    state.workout = data;
    state.unit = adoptServerUnit(storage, data.unit, { queued: outbox.queued(), stale });
    renderWorkout();
    $("workout-blocks").insertAdjacentHTML("afterbegin", offlineNote(stale));
  } catch (error) {
    $("workout-blocks").innerHTML = `<p>Could not load the workout (${escape(error.message)}).</p>`;
  }
}

function renderWorkout() {
  const workout = state.workout;
  $("workout-title").textContent = workout.title;
  $("workout-subtitle").textContent = [workout.subtitle, `about ${workout.estimated_minutes} min`].filter(Boolean).join(" · ");
  $("workout-blocks").innerHTML = workout.blocks.map((block, b) => `
    <section class="card block">
      <h3 class="block-head"><span class="block-label">${escape(blockName(block.label))}</span><span class="block-meta">${escape(blockSummary(block))}</span></h3>
      <ol class="steps">${block.steps.map((step, s) => stepRow(step, `${b}:${s}`)).join("")}</ol>
    </section>`).join("");
  $("workout-start").hidden = false;
  renderWorkoutOwn();
}

// A workout opens in the editor (editor.js), and can be deleted, which
// archives it so its sessions stay in the history; a deleted one offers a
// copy to edit.
function renderWorkoutOwn() {
  const workout = state.workout;
  const own = $("workout-own");
  own.hidden = false;
  if (!workout.editable) {
    own.innerHTML = `
      <p class="muted">This workout was deleted; its sessions stay in the history.</p>
      <div class="card-actions"><button class="secondary small" data-own="duplicate">Duplicate to edit</button></div>`;
    return;
  }
  own.innerHTML = `
    <h3>Your workout</h3>
    <p class="muted">Change its name, warm-up and cool-down, and its blocks and exercises.</p>
    <div class="card-actions">
      <a class="button secondary small" href="${routeHash("edit", workout.id)}" id="workout-edit">Edit</a>
      <button class="secondary small" data-own="duplicate">Duplicate</button>
      <button class="secondary small" data-own="delete">Delete</button>
    </div>`;
}

// Editing a workout needs the server: a copy gets its id there.
async function sendWorkout(method, path, body) {
  const response = await send(path, { method, body: body ?? undefined });
  const data = response.status === 204 ? null : await response.json().catch(() => null);
  if (!response.ok) throw new Error(errorMessage(data, response.status));
  return data;
}

async function onWorkoutOwn(action, button) {
  const workout = state.workout;
  button.disabled = true;
  try {
    if (action === "duplicate") {
      await saveWeights();
      const copy = await sendWorkout("POST", `/api/workouts/${workout.id}/duplicate`);
      return go(routeHash("workout", copy.id));
    }
    if (action === "delete") {
      const frame = workout.kind === "warmup" ? " Workouts that start with it will run without a warm-up." : workout.kind === "cooldown" ? " Workouts that end with it will run without a cool-down." : "";
      if (!confirm(`Delete ${workout.title}? Its past sessions stay in the history; the ones planned from today on are taken off the calendar.${frame}`)) return;
      await sendWorkout("DELETE", `/api/workouts/${workout.id}`);
      return go(routeHash("workouts"));
    }
  } catch (error) {
    alert(`Could not change the workout (${error.message}).`);
  } finally {
    button.disabled = false;
  }
}

function stepRow(step, ref) {
  const weight = step.target.weight;
  const equipment = equipmentNames(neededEquipment(step));
  const seed = step.weight && !sameShownWeight(step.weight, weight, state.unit) ? ` · plan: ${formatWeight(step.weight, state.unit)}` : "";
  const stepper = takesWeight(step) ? weightStepper(step.exercise.name, shownWeight(weight), `data-step="${ref}"`) : "";
  const suggestion = step.suggestion && weight
    ? suggestionAnswers(step.suggestion, weight, `data-suggestion="accept" data-step="${ref}"`, `data-suggestion="keep" data-step="${ref}"`)
    : "";
  return `<li>
    <div class="step-text">
      <button class="step-name" data-howto="${ref}" aria-label="How to do ${escape(step.exercise.name)}">${escape(step.exercise.name)}${icon("info")}</button>
      <p class="muted">${escape(stepSummary(step))}${equipment.length ? ` · ${escape(equipment.join(", "))}` : ""}${seed}</p>
    </div>
    ${stepper}${suggestion}
  </li>`;
}

// Shown for a step that takes a weight but has none (yet, or on purpose).
const NO_WEIGHT = "no weight";

// A weight as the steppers and the finish screen show it, "no weight" for none.
function shownWeight(weight) {
  return formatWeight(weight, state.unit) || NO_WEIGHT;
}

// A load to pick up ("2 × 20 lb"), "no weight" for none.
function shownLoad(weight, held) {
  return formatLoad(weight, held, state.unit) || NO_WEIGHT;
}

// Whether a step, target or player item can carry a weight: it has one, or
// it is done with gear in set weights. A plan cached by an older release has
// no weight_unit.
function takesWeight(thing) {
  return !!(thing.weight_unit ?? thing.target?.weight ?? thing.weight);
}

// The - and + buttons around a weight, in the workout view and on Get ready.
// `data` is the attribute that says which step or target they change.
function weightStepper(name, shown, data) {
  return `
    <div class="stepper">
      <button class="secondary" data-weight="down" ${data} aria-label="Less weight for ${escape(name)}">${icon("minus")}</button>
      <span>${shown}</span>
      <button class="secondary" data-weight="up" ${data} aria-label="More weight for ${escape(name)}">${icon("plus")}</button>
    </div>`;
}

// A weight suggestion with buttons to take it or keep the current weight.
function suggestionAnswers(suggestion, weight, acceptData, keepData) {
  return `
    <p class="suggestion">${escape(suggestion.reason)}: try ${formatWeight(suggestion, state.unit)}?</p>
    <div class="suggestion-actions">
      <button class="primary small" ${acceptData}>Use ${formatWeight(suggestion, state.unit)}</button>
      <button class="secondary small" ${keepData}>Keep ${formatWeight(weight, state.unit)}</button>
    </div>`;
}

// What a step of the workout view is done with. A workout cached offline by
// an older release names it `equipment`.
function neededEquipment(step) {
  return step.equipment_needed ?? step.equipment;
}

function workoutStep(ref) {
  const [b, s] = ref.split(":").map(Number);
  return state.workout.blocks[b].steps[s];
}

function changeWorkoutWeight(step, direction) {
  const weight = stepTargetWeight(step.target.weight, neededEquipment(step), direction, state.workout.weight_steps, step.allowed_weights, step.weight_unit);
  if (!sameWeight(weight, step.target.weight)) rememberWeight(step, weight);
}

// `weight` null remembers no weight.
function rememberWeight(step, weight) {
  setWeight(state.workout, step.exercise.id, weight);
  queueWeightSave(step.exercise.id, weight);
  $("workout-saved").textContent = "";
  renderWorkout();
}

// Taps are gathered so a run of + presses saves once (and answers a pending
// suggestion once, with the weight the user settled on).
function queueWeightSave(exerciseId, weight) {
  state.weightSaves[exerciseId] = weight;
  clearTimeout(state.weightSaveTimer);
  state.weightSaveTimer = setTimeout(saveWeights, SAVE_WEIGHT_AFTER_MS);
}

async function saveWeights() {
  clearTimeout(state.weightSaveTimer);
  if (!account.current()) return; // someone else signed in meanwhile
  const saves = Object.entries(state.weightSaves);
  if (saves.length === 0) return;
  state.weightSaves = {};
  for (const [id, weight] of saves) {
    outbox.enqueue(weightRequest(id, weight));
  }
  const synced = await sync();
  if (!$("workout").hidden) $("workout-saved").textContent = synced ? "Saved for next time." : "Saved on this device; it will sync when the server is reachable.";
}

async function leaveWorkout() {
  await saveWeights();
  if (state.workoutFrom === "workouts") return openWorkouts();
  show("home");
  await reloadToday();
}

async function startWorkout(id) {
  await saveWeights();
  if (state.parked) return askAboutParked();
  // Stays on this page until the session opens, so Back on Get ready returns here.
  if (await loadToday(id)) startSession();
  else show("home");
}

// ---------- Get ready ----------

function startSession() {
  if (state.parked) return askAboutParked();
  settleDiscard();
  unlock();
  const today = state.today;
  const id = uniqueId();
  const kinds = sessionKinds();
  const plan = structuredClone(framePlan(today.plan, kinds));
  const items = plan.items;
  // Sets the day's session already has (an ended-early or interrupted one):
  // the player picks up after them.
  const logged = loggedFromServer(items, today.logged);

  state.run = {
    id,
    ref: `session:${id}`,
    sessionId: today.session?.id ?? null,
    workoutId: today.workout_id,
    // The warm-up and cool-down it runs, for a workout that has them.
    parts: today.workouts.length > 1 ? kinds : null,
    date: today.date,
    title: today.title,
    from: location.hash || "#today", // where Start was pressed, for Back on Get ready
    items,
    targets: plan.targets,
    equipment: plan.equipment,
    weightSteps: today.weight_steps,
    index: pickUpIndex(items, logged),
    startedAt: Date.now(),
    weights: {}, // exercise id -> { name, from, to, keep } for weights changed in the player
    reps: {}, // item index -> reps actually done, when changed
    logged, // item index -> "done" or "skipped", for the sets logged
    // Picked up from sets on the server: discarding would take them too.
    pickedUp: Object.keys(logged).length > 0,
    stage: "ready",
  };
  if (state.run.equipment.length === 0 && state.run.targets.length === 0) beginPlayer();
  else showReady();
}

function showReady() {
  const run = state.run;
  run.stage = "ready";
  saveRun();
  $("ready-title").textContent = run.title;
  // Everything the session needs, one row each, with what it is for.
  const gear = gearList(run.items, run.targets);
  $("ready-pickup").innerHTML = gear.map((row) => `
    <li class="row"><span class="row-text">
      <span class="row-title">${escape(gearTitle(row))}</span>
      <span class="row-meta">${escape(row.exercises.join(", "))}</span>
    </span></li>`).join("");
  $("ready-need").hidden = gear.length === 0;
  $("ready-weights").hidden = run.targets.length === 0;
  $("ready-targets").innerHTML = run.targets.map((t, i) => {
    const suggestion = t.suggestion && t.weight ? suggestionAnswers(t.suggestion, t.weight, `data-accept="${i}"`, `data-keep="${i}"`) : "";
    return `<li><span>${escape(t.exercise.name)}</span>
      ${weightStepper(t.exercise.name, shownLoad(t.weight, t.weights_held), `data-target="${i}"`)}${suggestion}</li>`;
  }).join("");
  show("ready");
}

// A Get ready row: the equipment, with the load to pick up when it carries one.
function gearTitle(row) {
  const name = row.equipment ? equipmentNames([row.equipment])[0] : "Weight";
  if (row.load) return `${name}: ${formatLoad(row.load.weight, row.load.held, state.unit)}`;
  if (row.unset) return `${name}: no weight set`;
  return name;
}

// The user's answer to a suggestion is saved straight away; it is not a
// change made during the session, so there is nothing to undo at the end.
function answerSuggestion(index, accept) {
  const run = state.run;
  const target = run.targets[index];
  const weight = accept ? (target.suggestion.value > 0 ? { value: target.suggestion.value, unit: target.suggestion.unit } : null) : target.weight;
  outbox.enqueue(weightRequest(target.exercise.id, weight));
  sync();
  setTargetWeight(target, weight);
  showReady();
}

// A weight stepped on Get ready is remembered for the exercise, as in the
// workout view (taps are gathered and saved once).
function stepReadyWeight(index, direction) {
  const run = state.run;
  const target = run.targets[index];
  const weight = stepTargetWeight(target.weight, target.equipment, direction, run.weightSteps, target.allowed_weights, target.weight_unit);
  if (sameWeight(weight, target.weight)) return;
  setTargetWeight(target, weight);
  queueWeightSave(target.exercise.id, weight);
  showReady();
}

// The weight is the exercise's: every item of it takes it, each in its own
// unit (a step done with gear of its own keeps that gear's).
function setTargetWeight(target, weight) {
  target.weight = weight;
  target.suggestion = null;
  for (const item of state.run.items) {
    if (item.exercise?.id !== target.exercise.id) continue;
    item.weight = inUnit(weight, item.weight_unit);
    item.suggestion = null;
  }
}

// ---------- Player ----------

// The session is started on the server once the player starts, so backing
// out of the get-ready screen leaves nothing behind.
function beginPlayer() {
  const run = state.run;
  saveWeights();
  if (run.sessionId) outbox.remember(run.ref, run.sessionId);
  outbox.enqueue(startRequest(run));
  sync();
  run.stage = "player";
  show("player");
  requestWakeLock();
  prefetchSwaps();
  goTo(state.run.index);
}

function goTo(index) {
  const run = state.run;
  if (index < 0) index = 0;
  if (index >= run.items.length) return showFinish();

  // Moving on from the left side to the right: beep and say so.
  const switching = index === run.index + 1 && switchesSides(run.items, index);
  if (switching) {
    beep("switch");
    state.switchCueUntil = performance.now() + SWITCH_CUE_MS;
    // Only while the player is still up: a skip to the end shows the finish form.
    setTimeout(() => state.run && !$("player").hidden && render(), SWITCH_CUE_MS);
  } else {
    state.switchCueUntil = 0;
  }

  run.index = index;
  const item = current();
  if (item.type === "rest") {
    startCountdown("rest", item.seconds);
  } else if (item.mode === "timed") {
    // Seconds to get into position, as set on the Settings page.
    startCountdown("lead", leadInSeconds(run.items, index, readSettings(storage).leadIn));
  } else {
    stopTimer();
    state.phase = "reps";
  }
  saveRun();
  render();
}

function current() {
  return state.run.items[state.run.index];
}

function startCountdown(phase, seconds) {
  state.phase = phase;
  state.timer = countdown.start(countdown.createCountdown(seconds), performance.now());
  state.lastElapsed = 0;
}

function stopTimer() {
  state.timer = null;
}

function togglePause() {
  if (!state.timer) return;
  const now = performance.now();
  state.timer = countdown.isRunning(state.timer)
    ? countdown.pause(state.timer, now)
    : countdown.start(state.timer, now);
  saveRun();
  render();
}

function onMainAction() {
  unlock();
  if (state.phase === "reps") {
    logSet(current(), "done");
    goTo(state.run.index + 1);
  } else if (state.phase === "work") {
    // A hold ended early counts as done, for the seconds held.
    const held = Math.round(countdown.elapsed(state.timer, performance.now()) / 1000);
    logSet(current(), "done", { seconds: held });
    goTo(state.run.index + 1);
  } else if (state.phase === "lead") {
    startWork();
    saveRun();
    render();
  } else if (state.phase === "rest") {
    goTo(state.run.index + 1);
  } else {
    togglePause();
  }
}

// Skips what is left of the warm-up or cool-down in one go, logging its
// sets as skipped.
function skipPart() {
  const run = state.run;
  const end = partEnd(run.items, run.index);
  for (let i = run.index; i < end; i++) {
    if (run.items[i].type === "exercise" && !run.logged?.[i]) logSet(run.items[i], "skipped", { index: i });
  }
  goTo(end);
}

function onSkip() {
  if (current().type === "exercise") logSet(current(), "skipped");
  goTo(state.run.index + 1);
}

function tick() {
  if (!state.timer || !countdown.isRunning(state.timer)) return;

  const now = performance.now();
  const elapsed = countdown.elapsed(state.timer, now);
  // The lead-in only ticks; the exercise's own countdown gives the start beep.
  const cues = countdown.cuesBetween(state.timer, state.lastElapsed, elapsed)
    .filter((cue) => !(state.phase === "lead" && cue !== "tick"));
  cues.forEach(beep);
  state.lastElapsed = elapsed;

  if (countdown.isFinished(state.timer, now)) {
    if (state.phase === "lead") {
      startWork();
    } else {
      if (state.phase === "work") logSet(current(), "done");
      return goTo(state.run.index + 1);
    }
  }
  render();
}

function startWork() {
  startCountdown("work", current().seconds);
  // Emit the start beep immediately rather than on the next tick.
  beep("start");
  state.lastElapsed = 1;
}

function moreTime() {
  if (!extraSeconds(state.phase)) return;
  state.timer = countdown.extend(state.timer, extraSeconds(state.phase));
  saveRun();
  render();
}

function logSet(item, status, { index = state.run.index, seconds = item.seconds } = {}) {
  outbox.enqueue(setRequest(state.run, item, status, { reps: state.run.reps[index] ?? item.reps, seconds }));
  (state.run.logged ??= {})[index] = status;
  sync();
}

function repsDone() {
  return state.run.reps[state.run.index] ?? current().reps;
}

// Applies to the current set and every remaining set of the exercise.
// During a rest it changes the exercise coming up, so the weight can be
// picked while setting up.
function changeWeight(direction) {
  const run = state.run;
  const at = current().type === "rest" ? nextExerciseIndex() : run.index;
  const item = run.items[at];
  const weight = stepTargetWeight(item.weight, item.equipment, direction, run.weightSteps, item.allowed_weights, item.weight_unit);
  if (sameWeight(weight, item.weight)) return;
  const change = run.weights[item.exercise.id] ??= { name: item.exercise.name, from: item.weight, keep: true };
  change.to = weight;

  run.items.forEach((other, i) => {
    if (i >= at && other.exercise?.id === item.exercise.id) other.weight = inUnit(weight, other.weight_unit);
  });
  if (sameShownWeight(change.from, weight, state.unit)) delete run.weights[item.exercise.id];

  saveRun();
  render();
}

function changeReps(delta) {
  state.run.reps[state.run.index] = Math.max(0, repsDone() + delta);
  saveRun();
  render();
}

function render() {
  const run = state.run;
  const item = current();
  const now = performance.now();
  const resting = item.type === "rest";
  document.body.classList.toggle("resting", resting);
  const paused = !!state.timer && !countdown.isRunning(state.timer);
  document.body.classList.toggle("paused", paused);
  $("paused-note").hidden = !paused;
  $("timer-actions").hidden = !state.timer;
  $("pause").textContent = paused ? "Resume" : "Pause";
  $("more-time").hidden = !extraSeconds(state.phase);
  $("more-time").textContent = `+${extraSeconds(state.phase)} s`;
  $("target").setAttribute("aria-disabled", String(!state.timer));

  $("progress-bar").style.width = `${(run.index / run.items.length) * 100}%`;
  $("where").textContent = `${item.workout.title} · ${blockName(item.block.label)}`;
  const left = minutesLeft(run.items, run.index);
  $("count").textContent = left > 1 ? `about ${left} min left` : "almost done";

  if (resting) {
    $("phase").textContent = "Rest";
    $("phase").classList.remove("switch");
    const next = nextExercise();
    $("exercise-name").textContent = next ? `Next: ${next.exercise.name}` : "Rest";
    $("side").hidden = true;
    $("set-label").hidden = true;
    $("target").textContent = countdown.displaySeconds(state.timer, now);
    if (next) renderSteppers(next);
    else $("adjust").hidden = true;
    $("details").textContent = next ? upNextDetails(next, next.weight && formatWeight(next.weight, state.unit)) : "";
    renderGear(next, nextExerciseIndex());
    $("cues").innerHTML = "";
  } else {
    const switching = item.side === "right" && (state.phase === "lead" || now < state.switchCueUntil);
    $("phase").textContent = switching ? "Switch sides" : { lead: "Get ready", work: "Go", reps: "" }[state.phase] ?? "";
    $("phase").classList.toggle("switch", switching);
    $("exercise-name").textContent = item.exercise.name;
    $("set-label").textContent = setLabel(item);
    $("set-label").hidden = !setLabel(item);
    $("side").hidden = !item.side;
    $("side").textContent = item.side ? `${item.side === "left" ? "Left" : "Right"} side` : "";
    $("target").textContent = state.phase === "reps" ? repsTarget(item) : countdown.displaySeconds(state.timer, now);
    renderSteppers(item);
    $("details").textContent = details(item);
    renderGear(item, run.index);
    $("cues").innerHTML = item.exercise.cues.map((cue) => `<li>${escape(cue)}</li>`).join("");
  }

  // A rest shows its own dial, never a figure: a moving figure reads as "do this now".
  renderFigure(resting ? null : item);
  $("rest-dial").hidden = !resting;
  if (resting) $("rest-arc").style.strokeDashoffset = -(1 - countdown.remainingMs(state.timer, now) / state.timer.totalMs);
  $("howto-open").hidden = resting;
  $("swap-open").hidden = resting;

  const after = run.items[run.index + 1];
  // A rest already says what is next.
  $("next").textContent = resting ? "" : after ? `Next: ${label(after)}` : "Last one";

  $("main-action").textContent = mainActionLabel(state.phase);
  $("skip").innerHTML = `<span class="label">${resting ? "Skip rest" : "Skip"}</span>${icon("chevron-right")}`;
  const framing = item.workout.kind !== "workout" && run.items.some((i) => i.workout.kind === "workout");
  $("skip-part").hidden = !framing;
  if (framing) $("skip-part").textContent = `Skip ${item.workout.title.toLowerCase()}`;
}

// Keeps the same animation running across re-renders; swaps it when the
// exercise or side changes.
function renderFigure(item) {
  const animation = item?.exercise.animation;
  const mirror = item?.side === "right";
  const key = animation ? `${item.exercise.id}:${mirror}` : null;
  if (state.figure?.key !== key) {
    state.figure?.view.destroy();
    state.figure = key && { key, view: createFigure($("figure"), animation, { mirror, label: item.exercise.name }) };
  }
  $("figure").hidden = !key;
  if (!state.figure) return;
  if (document.body.classList.contains("paused")) state.figure.view.pause();
  else state.figure.view.play();
}

function clearFigure() {
  state.figure?.view.destroy();
  state.figure = null;
  $("figure").hidden = true;
  $("rest-dial").hidden = true;
}

// Pauses a running countdown while the how-to is open; Resume carries on.
function showHowto() {
  const item = current();
  if (state.timer && countdown.isRunning(state.timer)) togglePause();
  openHowto(item.exercise, { mirror: item.side === "right", tempo: item.tempo });
}

// Swapping pauses a running countdown, like the how-to; picking an exercise
// restarts the current set with it.
function showSwap() {
  const item = current();
  if (state.timer && countdown.isRunning(state.timer)) togglePause();
  openSwap({
    planned: plannedExercise(item),
    current: item.exercise,
    inSession: new Set(state.run.items.filter((i) => i.type === "exercise").map((i) => i.exercise.id)),
    unit: state.unit,
    onPick: (exercise) => {
      Object.assign(state.run, swapRun(state.run, state.run.index, exercise));
      goTo(state.run.index);
    },
  });
}

function prefetchSwaps() {
  prefetchAlternatives(state.run.items.filter((i) => i.type === "exercise").map((i) => plannedExercise(i).id));
}

function renderSteppers(item) {
  const weighted = takesWeight(item);
  const counted = state.phase === "reps" && !!item.reps;
  $("adjust").hidden = !weighted && !counted;
  $("weight-stepper").hidden = !weighted;
  $("reps-stepper").hidden = !counted;
  if (weighted) $("weight-value").textContent = shownWeight(item.weight);
  // What was actually done, the target until changed.
  if (counted) $("reps-value").textContent = repsDone() === item.reps ? `did ${item.reps}` : `did ${repsDone()} of ${item.reps}`;
}

function repsTarget(item) {
  if (item.reps) return `${item.reps}×`;
  return item.note ?? "Go";
}

function details(item) {
  const bits = [];
  if (item.planned) bits.push(`instead of ${item.planned.exercise.name}`);
  if (item.reps && item.exercise.alternating) bits.push(alternatingText(item.reps));
  if (item.tempo) bits.push(tempoText(item.tempo));
  if (item.mode === "timed" && state.phase === "lead") bits.push(`${item.seconds} s`);
  if (item.note && (item.mode === "timed" || item.reps)) bits.push(item.note);
  return bits.join(" · ");
}

// Everything the exercise at `index` is done with, marked when it changes.
function renderGear(item, index) {
  const names = item ? equipmentNames(item.equipment) : [];
  const list = $("equipment");
  list.hidden = names.length === 0;
  list.classList.toggle("changed", names.length > 0 && equipmentChanges(state.run.items, index));
  list.innerHTML = names.map((name) => `<li>${escape(name)}</li>`).join("");
}

function label(item) {
  if (item.type === "rest") return `rest ${item.seconds} s`;
  return item.side ? `${item.exercise.name} (${item.side})` : item.exercise.name;
}

function nextExerciseIndex() {
  return state.run.items.findIndex((item, i) => i > state.run.index && item.type === "exercise");
}

function nextExercise() {
  return state.run.items[nextExerciseIndex()];
}

// End session asks: keep going, finish with what was done, or discard. With
// nothing logged yet, discarding comes first.
function quit() {
  const running = state.timer && countdown.isRunning(state.timer);
  if (running) togglePause();
  const { exercises, done, sets } = sessionProgress(state.run);
  const sheet = $("end-sheet");
  const keep = `<button class="${sets ? "primary" : "secondary"}" value="keep">Keep going</button>`;
  const finish = `<button class="secondary" value="finish">Finish here</button>`;
  const discard = `<button class="${sets ? "secondary" : "primary"}" value="discard">Discard</button>`;
  sheet.innerHTML = `
    <form method="dialog" class="howto">
      <h2>End this session?</h2>
      <p class="muted">${sets
        ? `${done} of ${exercises} exercises done, ${sets} ${sets === 1 ? "set" : "sets"}. Finish here keeps them${state.run.pickedUp ? "" : "; Discard deletes the session"}.`
        : "Nothing logged yet."}</p>
      <div class="choices">${state.run.pickedUp ? keep + finish : sets ? keep + finish + discard : discard + keep + finish}</div>
    </form>`;
  sheet.returnValue = "keep";
  sheet.addEventListener("close", () => {
    if (sheet.returnValue === "finish") return finishEarly(state.run);
    if (sheet.returnValue === "discard") return discardRun(state.run);
    if (running) togglePause();
  }, { once: true });
  sheet.showModal();
}

function finishEarly(run) {
  if (run.stage !== "finish") run.endedEarly = endsEarly(run.items, run.index);
  state.run = run;
  showFinish();
}

// Takes the session off the screen straight away and deletes it once the
// undo has had its chance. Until then the kept run is marked, so a reload in
// between finishes the discard.
function discardRun(run) {
  stopTimer();
  releaseWakeLock();
  clearFigure();
  document.body.classList.remove("resting", "paused");
  run.discarding = true;
  state.run = run;
  saveRun();
  state.run = null;
  show("home");
  reloadToday();
  state.discarding = { run, timer: setTimeout(settleDiscard, UNDO_DISCARD_MS) };
  showToast(`${run.title} discarded.`, "Undo", () => {
    clearTimeout(state.discarding.timer);
    state.discarding = null;
    delete run.discarding;
    resume(run);
  });
}

// Lets a discard waiting on its undo go ahead now.
function settleDiscard() {
  if (!state.discarding) return;
  clearTimeout(state.discarding.timer);
  hideToast();
  completeDiscard(state.discarding.run);
  state.discarding = null;
}

// Nothing reached the server before the player started.
function completeDiscard(run) {
  const request = discardRequest(run);
  if (request) {
    outbox.enqueue(request);
    sync().then(() => { if (!$("home").hidden) reloadToday(); });
  }
  if (savedRun()?.id === run.id) clearRun();
}

function showToast(text, action, onAction) {
  const toast = $("toast");
  toast.innerHTML = `<span>${escape(text)}</span><button class="secondary small">${escape(action)}</button>`;
  toast.querySelector("button").onclick = () => {
    hideToast();
    onAction();
  };
  toast.hidden = false;
}

function hideToast() {
  $("toast").hidden = true;
}

// ---------- Finish ----------

function showFinish() {
  const run = state.run;
  stopTimer();
  releaseWakeLock();
  clearFigure();
  document.body.classList.remove("resting", "paused");
  if (run.stage !== "finish") {
    run.stage = "finish";
    run.minutes = Math.max(1, Math.round((Date.now() - run.startedAt) / 60000));
  }
  saveRun();

  const { exercises, done, sets, planned, skipped, swaps } = finishSummary(run);
  const plural = (n, word) => `${n} ${n === 1 ? word : `${word}s`}`;
  $("finish-title").textContent = run.endedEarly ? `${run.title}: ended early` : `${run.title} done`;
  $("finish-badge").classList.toggle("partial", !!run.endedEarly);
  $("finish-stats").innerHTML = [
    [done === exercises ? exercises : `${done}/${exercises}`, "exercises"],
    [sets === planned ? sets : `${sets}/${planned}`, "sets"],
    [run.minutes, run.minutes === 1 ? "minute" : "minutes"],
  ].map(([value, label]) => `<div><dt>${label}</dt><dd>${value}</dd></div>`).join("");
  $("summary").textContent = [skipped && `${skipped} skipped`, swaps && plural(swaps, "swap")].filter(Boolean).join(" · ");
  $("summary").hidden = !skipped && !swaps;
  renderChanges();
  renderFeedback();
  $("finish-form").hidden = false;
  $("finish-done").hidden = true;
  show("finish");
}

function renderChanges() {
  const changes = Object.entries(state.run.weights);
  $("changes-box").hidden = changes.length === 0;
  $("changes").innerHTML = changes.map(([id, c]) => `
    <li class="${c.keep ? "" : "undone"}">
      <span>${escape(c.name)}: ${shownWeight(c.keep ? c.to : c.from)}</span>
      <button class="secondary small" data-toggle-change="${id}">${c.keep ? `Undo (${shownWeight(c.from)})` : `Keep ${shownWeight(c.to)}`}</button>
    </li>`).join("");
}

// Both answers are picked first and saved together, so a mis-tap can be fixed.
function renderFeedback() {
  $("rpe").innerHTML = RPE_ANCHORS.map(({ rpe, label }) =>
    `<button aria-pressed="${state.rpe === rpe}" data-rpe="${rpe}">${label}</button>`).join("");
  document.querySelectorAll("[data-feedback]").forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.feedback === state.feedback));
  });
}

async function submitFinish() {
  const feedback = state.feedback;
  const run = state.run;
  const { key, requests } = finishRequests(run, { rpe: state.rpe, feedback });
  requests.forEach((request) => outbox.enqueue(request));
  clearRun();
  state.rpe = null;
  state.feedback = null;

  $("finish-form").hidden = true;
  $("finish-done").hidden = false;
  $("finish-result").textContent = "Saving…";
  $("finish-suggestions").innerHTML = "";
  $("next-up").hidden = true;

  const synced = await sync();
  const result = outbox.result(key);
  if (!synced) {
    $("finish-result").innerHTML = outbox.waiting() === "auth"
      ? `Saved on this device. <a href="${escape(signInHref(location))}">Sign in again</a> and it will sync.`
      : "Saved on this device. It will sync when the server is reachable.";
    return;
  }
  if (!result) {
    $("finish-result").textContent = "The server would not take this session. The reason is on the home screen.";
    return;
  }
  $("finish-result").textContent = result.suggestions.length
    ? "Suggested for next time (you confirm before it changes):"
    : "See you next time.";
  const names = Object.fromEntries(run.items.filter((i) => i.exercise).map((i) => [i.exercise.id, i.exercise.name]));
  $("finish-suggestions").innerHTML = result.suggestions.map((s) =>
    `<li><span>${escape(names[s.exercise_id] ?? "")}</span><strong>${formatWeight(s, state.unit)}</strong><p class="suggestion">${escape(s.reason)}</p></li>`).join("");
  showNextUp();
}

// The main workout up next, now that this one is saved.
async function showNextUp() {
  try {
    const { data: programs } = await getJson("/api/workouts");
    const next = programs.flatMap((program) => program.workouts).find((workout) => workout.up_next);
    if (!next || $("finish").hidden) return;
    $("next-up").href = routeHash("workout", next.id);
    $("next-up").textContent = `Next up: ${next.title}`;
    $("next-up").hidden = false;
  } catch {
    // Offline: the saved card does without it.
  }
}

// ---------- History ----------

async function openHistory() {
  show("history");
  $("history-list").innerHTML = `<li class="row muted">Loading…</li>`;
  $("history-exercises").innerHTML = "";
  try {
    const [{ data: history, stale }, { data: exercises, stale: staleExercises }] = await Promise.all([
      getJson(`/api/history?days=28&date=${localToday()}`),
      getJson("/api/history/exercises"),
    ]);
    const { done: week = 0, partial = 0 } = history.weeks[0] ?? {};
    $("history-week").textContent = [`This week: ${week} ${week === 1 ? "session" : "sessions"} done${partial ? `, ${partial} ended early` : ""}`,
      stale || staleExercises ? STALE_NOTE : ""].filter(Boolean).join(" · ");
    $("history-list").innerHTML = history.sessions.length
      ? history.sessions.map(historyRow).join("")
      : `<li class="row muted">Nothing in the last four weeks yet.</li>`;
    $("history-exercises").innerHTML = exercises.length
      ? exercises.map(exerciseRow).join("")
      : `<li class="row muted">Exercises show up here once you log a set.</li>`;
  } catch (error) {
    $("history-list").innerHTML = `<li class="row">Could not load the history (${escape(error.message)}).</li>`;
  }
}

function historyRow(session) {
  return `<li><button class="row" data-session="${session.id}"><span class="row-text"><span class="row-title">${escape(session.workout.title)}</span>
    <span class="row-meta">${escape([weekdayDate(session.date), sessionSummary(session)].join(" · "))}</span></span>${icon("chevron-right")}</button></li>`;
}

function exerciseRow(exercise) {
  const bits = [`last ${weekdayDate(exercise.last_date)}`, `${exercise.sessions} ${exercise.sessions === 1 ? "session" : "sessions"}`];
  if (exercise.remembered) bits.push(formatWeight(exercise.remembered, state.unit));
  return `<li><button class="row" data-exercise="${exercise.id}"><span class="row-text"><span class="row-title">${escape(exercise.name)}</span>
    <span class="row-meta">${escape(bits.join(" · "))}</span></span>${icon("chevron-right")}</button></li>`;
}

// Weight and reps per session for one exercise, newest first.
async function openExerciseHistory(id) {
  show("exercise-history", id);
  $("exercise-history-name").textContent = "";
  $("exercise-history-remembered").textContent = "";
  $("exercise-history-list").innerHTML = `<li class="row muted">Loading…</li>`;
  try {
    const { data: history, stale } = await getJson(`/api/exercises/${id}/history`);
    $("exercise-history-name").textContent = history.exercise.name;
    $("exercise-history-remembered").textContent = [
      history.remembered?.value != null ? `Next time: ${formatWeight(history.remembered, state.unit)}`
        : history.remembered?.unit ? `Next time: ${NO_WEIGHT}` : "",
      stale ? STALE_NOTE : "",
    ].filter(Boolean).join(" · ");
    $("exercise-history-list").innerHTML = history.sessions.length
      ? history.sessions.map(exerciseSessionRow).join("")
      : `<li class="row muted">Nothing logged yet.</li>`;
  } catch (error) {
    $("exercise-history-list").innerHTML = `<li class="row">Could not load the history (${escape(error.message)}).</li>`;
  }
}

function exerciseSessionRow(session) {
  const swapped = session.sets.some((set) => set.swapped) ? " · as a swap" : "";
  return `<li class="row"><span class="row-text"><span class="row-title sets">${escape(setsSummary(session.sets, state.unit))}</span>
    <span class="row-meta">${escape(`${weekdayDate(session.date)} · ${session.workout.title}${swapped}`)}</span></span></li>`;
}

function weekdayDate(iso) {
  return new Date(`${iso}T12:00:00`).toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
}

// One past session: what was done per exercise, each linking to its
// progress, and Delete at the bottom.
async function openSession(id) {
  show("session", id);
  $("session-title").textContent = "";
  $("session-summary").textContent = "";
  $("session-note").hidden = true;
  $("session-delete").hidden = true;
  $("session-exercises").innerHTML = `<li class="muted">Loading…</li>`;
  try {
    const { data: session, stale } = await getJson(`/api/sessions/${id}`);
    const date = weekdayDate(session.date);
    $("session-title").textContent = session.workout.title;
    $("session-summary").textContent = [date, sessionSummary(session), stale ? STALE_NOTE : ""].filter(Boolean).join(" · ");
    $("session-note").textContent = session.completion?.note ?? "";
    $("session-note").hidden = !session.completion?.note;
    $("session-exercises").innerHTML = session.exercises.length
      ? session.exercises.map(sessionExerciseRow).join("")
      : `<li class="muted">No sets were logged in this session.</li>`;
    Object.assign($("session-delete").dataset, { delete: session.id, label: `${session.workout.title} on ${date}` });
    $("session-delete").hidden = false;
  } catch (error) {
    $("session-exercises").innerHTML = `<li>Could not load the session (${escape(error.message)}).</li>`;
  }
}

function sessionExerciseRow(entry) {
  const { done, skipped } = exerciseSummary(entry, state.unit);
  const notes = [];
  if (entry.instead_of) notes.push(`instead of ${entry.instead_of.name}`);
  if (done && skipped) notes.push(`${skipped} skipped`);
  return `<li><button class="row${done ? "" : " skipped"}" data-exercise="${entry.exercise.id}"><span class="row-text">
    <span class="row-meta">${escape([entry.exercise.name, ...notes].join(" · "))}</span>
    <span class="row-title sets">${escape(done || "Skipped")}</span></span>${icon("chevron-right")}</button></li>`;
}

// Deleting needs the server, like loading the history does, so it is not
// queued: the user sees right away whether it worked.
async function deleteSession(button) {
  if (!confirm(`Delete ${button.dataset.label} and every set logged in it? This cannot be undone.`)) return;
  button.disabled = true;
  try {
    const response = await send(`/api/sessions/${button.dataset.delete}`, { method: "DELETE" });
    if (!response.ok && response.status !== 404) throw new Error(`HTTP ${response.status}`);
    button.disabled = false;
    go(routeHash("history"));
  } catch (error) {
    button.disabled = false;
    alert(`Could not delete the session (${error.message}).`);
  }
}

// ---------- Saving and resuming ----------

function saveRun() {
  const run = state.run;
  if (!run || !account.current()) return;
  runStore.save(run, { phase: state.phase, timer: state.timer, timerNow: performance.now() });
}

function clearRun() {
  state.run = null;
  runStore.clear();
}

function resume(run) {
  state.run = run;
  if (run.stage === "ready") return showReady();
  if (run.stage === "finish") return showFinish();

  const saved = restoredTimer(run.timer);
  show("player");
  requestWakeLock();
  prefetchSwaps();
  goTo(run.index);
  // Come back paused where the countdown was, so nothing runs unseen.
  if (saved && state.timer) {
    state.phase = saved.phase;
    state.timer = saved.timer;
    state.lastElapsed = saved.timer.elapsedMs;
    saveRun();
    render();
  }
}

// Names a session the server can recognise when its create is sent again.
function uniqueId() {
  return crypto.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

// ---------- A session left from before ----------

// Shown on top of every view outside the session screens, so the pages stay
// usable and the old session is one tap away.
function renderParked(view, note = "") {
  const box = $("in-progress");
  const run = state.parked;
  box.hidden = !run || isSessionView(view);
  if (box.hidden) return;
  $(view).prepend(box);
  const { exercises, done } = sessionProgress(run);
  const started = new Date(run.startedAt).toLocaleString(undefined, { weekday: "short", hour: "2-digit", minute: "2-digit" });
  const where = run.stage === "finish" ? "finished, not saved yet" : `${done} of ${exercises} exercises done`;
  box.innerHTML = `
    <p class="muted">Session in progress</p>
    <h2>${escape(run.title)}</h2>
    <p>Started ${escape(started)} · ${escape(where)}</p>
    ${note ? `<p><strong>${escape(note)}</strong></p>` : ""}
    <button class="primary" data-parked="resume">Resume</button>
    <div class="secondary-actions">
      <button class="secondary" data-parked="finish">Finish with what I did</button>
      ${run.pickedUp ? "" : `<button class="secondary" data-parked="discard">Discard</button>`}
    </div>`;
}

function askAboutParked() {
  show("home");
  renderParked("home", "Finish or discard this session before you start another.");
}

function onParked(action) {
  const run = state.parked;
  if (!run) return;
  state.parked = null;
  if (action === "resume") return resume(run);
  if (action === "finish") return finishEarly(run);
  discardRun(run);
}

function savedRun() {
  return runStore.load();
}

async function sync() {
  const done = await outbox.flush();
  renderSync();
  return done;
}

function renderSync() {
  const pending = outbox.pending();
  $("sync").hidden = pending === 0;
  $("sync").innerHTML = syncNote(pending, outbox.waiting(), location);
  renderRejected();
}

// Changes the server would not take, with its reason, until dismissed.
function renderRejected() {
  const rejected = outbox.rejected();
  $("sync-rejected").hidden = rejected.length === 0;
  if (rejected.length === 0) return;
  const count = `${rejected.length} ${rejected.length === 1 ? "change" : "changes"}`;
  const reasons = [...new Set(rejected.map((r) => r.error))];
  $("sync-rejected").innerHTML = `
    <p>${count} could not be saved: ${escape(reasons.join("; "))}</p>
    <button class="secondary small" data-dismiss-rejected>Dismiss</button>`;
}

// ---------- Screen wake lock ----------

async function requestWakeLock() {
  try {
    state.wakeLock = await navigator.wakeLock?.request("screen");
  } catch {
    // Not supported or refused (e.g. low battery); the player still works.
  }
}

function releaseWakeLock() {
  state.wakeLock?.release();
  state.wakeLock = null;
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && !$("player").hidden) requestWakeLock();
  if (document.visibilityState === "hidden") saveRun();
});

// ---------- Helpers ----------

// Shown over a view the service worker answered from its cache.
function offlineNote(stale) {
  return stale ? `<p class="muted">${escape(STALE_NOTE)}</p>` : "";
}

// Shows one view. The views with a page in the sidebar get a URL hash, so a
// reload comes back to them; the session screens hide the sidebar.
// Going into a session adds a history entry, so back stays in the app (see
// onPopState).
function show(view, id) {
  for (const other of ["home", "workouts", "workout", "edit", "ready", "player", "finish", "history", "exercise-history", "session"]) $(other).hidden = other !== view;
  const hash = routeHash(view, id);
  state.shownHash = hash;
  const entering = isSessionView(view) && location.hash !== hash;
  if (entering) history.pushState({ session: true }, "", hash);
  else if (location.hash !== hash) history.replaceState(null, "", hash);
  if (isSessionView(view)) document.body.dataset.focus = "";
  else document.body.removeAttribute("data-focus");
  nav.setCurrent(pageFor(view));
  renderParked(view);
  window.scrollTo(0, 0);
}

// Navigates as a link would, so the phone's back button returns here.
function go(hash) {
  location.hash = hash;
}

// Back while a session runs: leaving Get ready goes back to where Start was
// pressed; the player asks how to end the session instead of leaving; the
// finish form stays. The session's history entry is put back when it stays.
function onPopState() {
  const run = state.run;
  if (!run || location.hash === "#running") return;
  if (run.stage === "ready") return clearRun();
  history.pushState({ session: true }, "", "#running");
  if (run.stage === "player" && !$("end-sheet").open) quit();
}

// Leaves Get ready the way the phone's back button does.
function leaveReady() {
  if (history.state?.session) return history.back();
  const from = state.run.from ?? "#today";
  clearRun();
  history.replaceState(null, "", from);
  route();
}

// Opens the view the URL hash names. A session under way keeps the screen.
async function route() {
  if (state.run) return;
  const { view, id } = parseRoute(location.hash);
  if (!leaveEditor(view, id)) return;
  const cameFrom = state.shownHash;
  await saveWeights();
  if (view === "workouts") return openWorkouts();
  if (view === "edit") return openEdit(id, cameFrom);
  if (view === "history") return openHistory();
  if (view === "exercise-history") return openExerciseHistory(id);
  if (view === "session") return openSession(id);
  if (view === "workout") return openWorkout(id);
  show("home");
  reloadToday();
}

// The workout editor, opened from `cameFrom` (a URL hash).
function openEdit(id, cameFrom) {
  show("edit", id);
  openEditor(id, {
    unit: state.unit,
    cameFrom,
    onSaved: (workout, created) => {
      state.workoutNote = created ? "Created. Start it here, or find it under My workouts." : "Saved.";
    },
  });
}

function shortDate(date) {
  return new Date(`${date}T12:00:00`).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function savedFraming() {
  try {
    return JSON.parse(storage.getItem(FRAMING_KEY)) ?? {};
  } catch {
    return {};
  }
}

function saveFraming() {
  try {
    storage.setItem(FRAMING_KEY, JSON.stringify(state.framing));
  } catch {
    // Storage blocked: the choice lasts for this page load.
  }
}

function safeStorage() {
  try {
    return window.localStorage;
  } catch {
    const items = new Map();
    return { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v), removeItem: (k) => items.delete(k) };
  }
}

// ---------- Wiring ----------

$("main-action").onclick = onMainAction;
$("prev").onclick = () => goTo(previousIndex(state.run.items, state.run.index));
$("skip").onclick = onSkip;
$("quit").onclick = quit;
// Tapping a countdown pauses or resumes it.
$("target").onclick = togglePause;
$("target").onkeydown = (event) => {
  if (event.key !== "Enter" && event.key !== " ") return;
  event.preventDefault();
  togglePause();
};
$("pause").onclick = togglePause;
$("more-time").onclick = moreTime;
$("skip-part").onclick = skipPart;
$("howto-open").onclick = showHowto;
$("swap-open").onclick = showSwap;
$("weight-down").onclick = () => changeWeight("down");
$("weight-up").onclick = () => changeWeight("up");
$("reps-down").onclick = () => changeReps(-1);
$("reps-up").onclick = () => changeReps(1);

$("ready-go").onclick = () => { unlock(); beginPlayer(); };
$("ready-back").onclick = leaveReady;
$("ready-targets").onclick = (event) => {
  const button = event.target.closest("button");
  if (button?.dataset.accept) answerSuggestion(Number(button.dataset.accept), true);
  if (button?.dataset.keep) answerSuggestion(Number(button.dataset.keep), false);
  if (button?.dataset.weight) stepReadyWeight(Number(button.dataset.target), button.dataset.weight);
};

$("workouts-list").onclick = (event) => {
  const button = event.target.closest("button[data-start]");
  if (button) startWorkout(Number(button.dataset.start));
};
$("today").addEventListener("change", (event) => {
  const toggle = event.target.closest("input[data-part]");
  if (!toggle) return;
  const session = state.today.session;
  // A planned session with its own parts keeps the change to itself.
  if (session?.status === "planned" && session.parts) {
    state.sessionFraming[session.id] = { ...framingNow(), [toggle.dataset.part]: toggle.checked };
    // The plan changes with it, here and on every device.
    outbox.enqueue({ method: "PATCH", path: `/api/sessions/${session.id}`, body: { parts: sessionKinds() } });
    sync();
  } else {
    state.framing[toggle.dataset.part] = toggle.checked;
    saveFraming();
  }
  renderToday();
});
$("today-day").addEventListener("click", (event) => {
  const button = event.target.closest("button[data-day-session]");
  if (!button) return;
  if (button.dataset.status === "done") return go(routeHash("session", button.dataset.daySession));
  loadToday(undefined, button.dataset.daySession);
});
$("today").addEventListener("click", (event) => {
  const button = event.target.closest("button[data-view]");
  if (button) openWorkout(button.dataset.view);
});
$("today-activities").addEventListener("click", (event) => {
  if (event.target.closest("#log-activity")) return logActivity();
  const plan = event.target.closest("[data-today-routine]");
  if (plan) return openTodayRoutine(plan.dataset.todayRoutine);
  const row = event.target.closest("[data-today-activity]");
  if (row) openTodayActivity(row.dataset.todayActivity);
});

$("sync-rejected").onclick = (event) => {
  if (!event.target.closest("button[data-dismiss-rejected]")) return;
  outbox.dismissRejected();
  renderRejected();
};

$("workout-back").onclick = leaveWorkout;
$("workout-start").onclick = () => startWorkout(state.workout.id);
$("workout-own").onclick = (event) => {
  const button = event.target.closest("button[data-own]");
  if (button) onWorkoutOwn(button.dataset.own, button);
};
$("workout-blocks").onclick = (event) => {
  const button = event.target.closest("button[data-step], button[data-howto]");
  if (!button) return;
  if (button.dataset.howto) return openHowto(workoutStep(button.dataset.howto).exercise);
  const step = workoutStep(button.dataset.step);
  if (button.dataset.weight) changeWorkoutWeight(step, button.dataset.weight);
  if (button.dataset.suggestion === "accept") rememberWeight(step, { value: step.suggestion.value, unit: step.suggestion.unit });
  if (button.dataset.suggestion === "keep") rememberWeight(step, step.target.weight);
};

$("changes").onclick = (event) => {
  const id = event.target.closest("button")?.dataset.toggleChange;
  if (!id) return;
  state.run.weights[id].keep = !state.run.weights[id].keep;
  saveRun();
  renderChanges();
};
$("rpe").onclick = (event) => {
  const n = Number(event.target.closest("button")?.dataset.rpe);
  if (!n) return;
  state.rpe = state.rpe === n ? null : n;
  renderFeedback();
};
document.querySelectorAll("[data-feedback]").forEach((button) => {
  button.onclick = () => {
    state.feedback = state.feedback === button.dataset.feedback ? null : button.dataset.feedback;
    renderFeedback();
  };
});
$("finish-save").onclick = submitFinish;
$("home-again").onclick = () => { show("home"); loadToday(); };

$("in-progress").onclick = (event) => {
  const action = event.target.closest("button[data-parked]")?.dataset.parked;
  if (action) onParked(action);
};

$("history-list").onclick = (event) => {
  const button = event.target.closest("button[data-session]");
  if (button) go(routeHash("session", button.dataset.session));
};
$("session-exercises").onclick = (event) => {
  const button = event.target.closest("button[data-exercise]");
  if (button) go(routeHash("exercise-history", button.dataset.exercise));
};
$("session-back").onclick = () => go(routeHash("history"));
$("session-delete").onclick = (event) => deleteSession(event.currentTarget);
$("history-exercises").onclick = (event) => {
  const button = event.target.closest("button[data-exercise]");
  if (button) go(routeHash("exercise-history", button.dataset.exercise));
};
$("exercise-history-back").onclick = () => go(routeHash("history"));
$("exercise-history-howto").onclick = async () => {
  const id = parseRoute(location.hash).id;
  try {
    openHowto((await getJson(`/api/exercises/${id}`)).data, { controls: true });
  } catch (error) {
    alert(`Could not load the how-to (${error.message}).`);
  }
};

window.addEventListener("online", sync);
window.addEventListener("popstate", onPopState);
// Another tab queued or sent changes: show the queue as it is now.
window.addEventListener("storage", (event) => { if (event.key === "outbox") renderSync(); });
window.addEventListener("hashchange", route);
window.addEventListener("pagehide", () => { saveRun(); saveWeights(); });
setInterval(tick, TICK_MS);
setInterval(sync, SYNC_EVERY_MS);

// Only the very first visit waits for the names; later ones use the copy
// and refresh it in the background.
if (knowsEquipmentNames()) loadEquipmentNames();
else await loadEquipmentNames();
let saved = savedRun();
// Closed while the undo was showing: the discard goes ahead.
if (saved?.discarding) {
  completeDiscard(saved);
  saved = null;
}
const choice = resumeChoice(saved, Date.now(), RESUME_WITHIN_MS);
if (choice === "resume") {
  resume(saved);
  loadToday();
} else {
  if (choice === "ask") state.parked = saved;
  if (choice === "drop") clearRun();
  route();
}
sync();
