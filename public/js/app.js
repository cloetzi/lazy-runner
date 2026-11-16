import * as countdown from "./countdown.js";
import { beep, unlock } from "./beeper.js";
import { createOutbox } from "./outbox.js";
import { pageAccount, signInHref, syncNote, parkedNote } from "./account.js";
import { stepTargetWeight, sameWeight, sameShownWeight, inUnit, preferredUnit, adoptServerUnit, formatWeight, formatLoad } from "./weights.js";
import { createFigure } from "./figure-view.js";
import { openHowto, equipmentNames, loadEquipmentNames, knowsEquipmentNames, ownedEquipment, equipmentId, comesInWeights, isAnyWeight, markOwned } from "./howto.js";
import { gearChips, missingGear, nameList } from "./gear.js";
import { escape, icon, authorLine, busy, showSheet } from "./html.js";
import { offlineToday } from "./offline.js";
import { setupRows, setupLeft } from "./setup.js";
import { blockName, blockSummary, stepSummary, alternatingText, setWeight, includedKinds, framingFor, framePlan, gearList, carrierOf } from "./workout.js";
import { previousIndex, switchesSides, mainActionLabel, stepAnnouncement, spokenTarget, tapAccepted, holdStatus, unloggedExercises, plannedExercise, swapRun, resumeChoice, sessionProgress, endsEarly, loggedFromServer, pickUpIndex, partEnd, setLabel, minutesLeft, tempoText, leadInSeconds, extraSeconds, progressAt, repsCount, upNextLabel, upNextDetails, equipmentChanges, finishSummary, framingLine, swapTargets } from "./player.js";
import { rpeOptions, toggleRpe } from "./rpe-picker.js";
import { openSwap, prefetchAlternatives, forgetAlternatives } from "./swap.js";
import { mountNav } from "./nav.js";
import { parseRoute, routeHash, pageFor, isSessionView, backFor, viewLabel } from "./routes.js";
import { setsSummary, sessionSummary, exerciseSummary, sessionParts, partLine } from "./history.js";
import { getJson, errorMessage, loadProblem, paths, send, sendChange, STALE_NOTE } from "./api.js";
import { readSettings } from "./preferences.js";
import { weightRequest, skipRequest, startRequest, setRequest, finishRequests, discardRequest } from "./session-log.js";
import { createRunStore, restoredTimer } from "./run-store.js";
import { markFor, longDay, localToday, moveRequest, removeRequest, STATUS_LABELS } from "./calendar.js";
import { openSessionSheet, openLogActivitySheet, openRpeSheet, activityRow, editActivity, weekSummaryHtml } from "./calendar-sheets.js";
import { plannedBy, notesAbout } from "./coach.js";
import { queuedWeek, strengthWeekLine, nextSessionLine } from "./week.js";
import {
  withQueuedActivities, removedActivityIds, activityKey, preferredDistanceUnit, adoptServerDistanceUnit,
  logRequest, changeRequest, rpeToAsk, readAsked, rememberAsked,
} from "./activities.js";
import { openEditor, leaveEditor } from "./editor.js";
import { draftFrom, setExercise, saveRequest } from "./builder.js";
import { mountExamples } from "./example-list.js";
import { changeHtml, undoButton, undoRequest, workoutChanges, weightChange, withoutUndo } from "./plan-changes.js";
import {
  withActivities, listed, routineTitle, confirmRequest as confirmDayRequest, skipRequest as skipDayRequest,
  moveRequest as moveDayRequest, resetRequest as resetDayRequest, endRequest as endRoutineRequest,
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
  setup: null, // GET /api/account/setup, for the "Getting set up" card
  noWorkouts: false, // Today is "Nothing to train yet", with set-up under it
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
  board: null, // GET /api/coach, for the week beside Today
  setupAsk: 0, // the latest read of a new user's day, so an older answer is dropped
  askedHowHard: false, // Today's how-hard question was asked on this visit
  readRecent: null, // the date whose days before were read for it
  shownHash: "", // the URL hash of the view on screen, for the editor to return to
  trail: [], // the URL hashes of the views opened on this page, latest last
  wandered: false, // a view on this page was left for another: the page that linked here is no longer the way back
  back: null, // where the view on screen's Back button goes (backFor)
  pushedFrom: null, // { hash, from }: the view on screen came by a link from `from`, the history entry before it
  focusOnLoad: false, // the detail on screen takes the focus to its heading once loaded
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
  loadSetup();
  try {
    const { data: today, stale } = await getJson(paths.today({ date: localToday(), workoutId, sessionId }));
    state.unit = adoptServerUnit(storage, today.unit, { queued: outbox.queued(), stale });
    state.distanceUnit = adoptServerDistanceUnit(storage, today.distance_unit, { queued: outbox.queued(), stale });
    // The service worker answered from its cache: the server is out of reach.
    state.today = stale ? offlineToday(today, localToday()) : today;
    state.todayStale = stale;
    state.today.pickedSession = Boolean(sessionId && !workoutId);
    state.noWorkouts = false;
    renderToday();
    drawSetup();
    renderActivities();
    if (!stale) askHowHard();
    return true;
  } catch (error) {
    // A session picked from the list may be gone (or not cached offline):
    // fall back to the day's own card.
    if (sessionId && !workoutId) return loadToday();
    if (error.code === "no_workouts") return renderSetup();
    // A new user's day read before this doesn't draw under the error.
    state.setupAsk += 1;
    $("today").innerHTML = `<p>${escape(loadProblem("today's session", error, { hint: false }))}</p>
      <button class="secondary" id="retry">Try again</button>`;
    $("retry").onclick = () => loadToday(workoutId, sessionId);
    return false;
  }
}

// A new user's Today: nothing to train until they import an example program
// or build a workout.
function renderSetup() {
  // The day read before stays on screen, and in hand, until the new read
  // answers; another day's (or a card's) goes.
  if (!state.today?.setup || state.today.date !== localToday()) {
    state.today = null;
    $("today-activities").hidden = true;
  }
  $("today-date").textContent = "";
  $("today-day").hidden = true;
  $("today").innerHTML = `
    <h2>Nothing to train yet</h2>
    <p>Start from an example program, fitted to the gear you own, or build a workout of your own from the exercise library.</p>
    <div class="card-actions">
      <a class="button primary small" href="#examples" id="setup-examples">From an example</a>
      <a class="button secondary small" href="${routeHash("edit", "new")}">Build a workout</a>
    </div>
    <div id="setup-later"></div>`;
  state.noWorkouts = true;
  // Fetched even with the card hidden: here the rest of set-up is all there is.
  if (state.setup) drawSetup();
  else loadSetup();
  loadSetupDay();
  // Nothing loaded: a caller waiting to start the session doesn't.
  return false;
}

// ---------- Getting set up ----------

// Hidden for good on this device once the user says so.
const SETUP_HIDDEN_KEY = "setup-hidden";
const setupHidden = () => {
  try {
    return Boolean(storage?.getItem(SETUP_HIDDEN_KEY));
  } catch {
    return false; // storage blocked: the card shows
  }
};
const installed = () => matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;

// What is left of setting up, from the server (setup.js has the rows).
async function loadSetup() {
  if (setupHidden() && !state.noWorkouts) return;
  try {
    state.setup = (await getJson(`/api/account/setup?today=${localToday()}`)).data;
  } catch {
    // Offline and never fetched: no card until it can be.
  }
  drawSetup();
}

const setupList = (rows) => `
  <ul class="setup-list">${rows.map((row) => `
    <li class="${row.done ? "done" : ""}">
      ${row.done ? icon("check", "Done:") : `<span class="setup-dot" aria-hidden="true"></span>`}
      <span>${row.href && !row.done ? `<a href="${row.href}">${escape(row.label)}</a>` : `<strong>${escape(row.label)}</strong>`}
        ${row.done ? "" : `<span class="muted">${escape(row.hint)}</span>`}</span>
    </li>`).join("")}
  </ul>`;

// With no workout yet, the rest of set-up sits under the "Nothing to train
// yet" card; after, it is a card of its own above Today's, until all done
// or hidden.
function drawSetup() {
  const card = $("today-setup");
  const later = state.noWorkouts ? $("setup-later") : null;
  if (!state.setup) {
    card.hidden = true;
    return;
  }
  const rows = setupRows(state.setup, { standalone: installed() });
  if (later) {
    card.hidden = true;
    const rest = rows.filter((row) => row.key !== "program" && !row.done);
    later.innerHTML = rest.length ? `<h3>Then, when you like</h3>${setupList(rest)}` : "";
    return;
  }
  card.hidden = setupHidden() || !setupLeft(rows);
  if (card.hidden) return;
  card.innerHTML = `
    <div class="setup-head">
      <h2 id="setup-title">Getting set up</h2>
      <button class="quiet small" type="button" id="setup-hide">Hide</button>
    </div>
    ${setupList(rows)}`;
  $("setup-hide").onclick = () => {
    try {
      storage?.setItem(SETUP_HIDDEN_KEY, "1");
    } catch {
      // Not kept: hidden until the page loads again.
    }
    card.hidden = true;
    const heading = $("today").querySelector("h2");
    heading?.setAttribute("tabindex", "-1");
    heading?.focus();
  };
}

// What else is on a new user's day, under the setup card: the runs planned,
// the activities done, a way to log one, and the question of how hard one
// sent from elsewhere was. `setup` marks a Today with no card.
async function loadSetupDay() {
  const date = localToday();
  const ask = ++state.setupAsk;
  try {
    const { data, stale } = await getJson(paths.calendar({ from: date, to: date, today: date }));
    // Read again since, or a workout made meanwhile brought the card back.
    if (ask !== state.setupAsk || (state.today && !state.today.setup) || localToday() !== date) return;
    state.distanceUnit = adoptServerDistanceUnit(storage, data.distance_unit, { queued: outbox.queued(), stale });
    state.today = { date, setup: true, activities: data.activities, routines: data.routines, routine_days: data.routine_days };
    renderActivities();
    if (!stale) askHowHard();
  } catch {
    // The setup card alone.
  }
}

// This week at a glance, with the coach's focus and concerns: beside the
// Today card on wide screens, under it on narrower ones.
async function loadWeek() {
  try {
    state.board = (await getJson(paths.coach(localToday()))).data;
  } catch {
    state.board = null;
  }
  renderWeek();
}

// Drawn again when the day's activities or the distance unit change, with
// what the outbox holds laid over the server's week.
function renderWeek() {
  const { board } = state;
  $("week").hidden = !board;
  if (!board) return;
  $("week").innerHTML = weekSummaryHtml({
    week: queuedWeek(board.week, outbox.queued(), localToday()), board, unit: state.distanceUnit, heading: "<h2>This week</h2>",
  });
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
    const toggle = toggles ? `<label class="part-target"><input type="checkbox" class="part-toggle" data-part="${w.kind}"${on ? " checked" : ""}${w.kind === "workout" ? " disabled" : ""} aria-label="Include the ${escape(w.title)}"></label>` : "";
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
      <button class="primary large" id="start">Pick up again</button>
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

  // Never trained and nothing planned: not a rest day but the first session,
  // with planning the week as the other way on.
  // Offline, a finished first session may still be in the outbox; a day
  // that already holds sessions is the rest-day card's to explain.
  if (source === "default" && !offline && !state.today.next_planned && !state.today.day?.length && state.today.trained === false) {
    $("today").innerHTML = `
      <p class="muted">Your first session</p>
      <h2>${escape(title)}</h2>
      ${subtitle ? `<p>${escape(subtitle)}</p>` : ""}
      ${offlineNote}
      <ul class="list parts">${parts}</ul>
      <p class="muted">About ${estimated_minutes} minutes</p>
      <button class="primary large" id="start">Start</button>
      <a class="button secondary" href="/calendar.html">Plan my week</a>
      <button class="quiet" id="pick">Pick another</button>`;
    $("start").onclick = startSession;
    $("pick").onclick = () => go("#workouts");
    return;
  }

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
      <button class="primary large" id="bring-forward">Do it today</button>
      <button class="secondary" id="pick">Pick another</button>` : `
      <p class="muted">Rest day</p>
      <h2>${heading}</h2>
      <p>Rest, or train anyway: next in the rotation is ${escape(title)}${subtitle ? `, ${escape(subtitle)}` : ""}.</p>
      ${offlineNote}
      <ul class="list parts">${parts}</ul>
      <p class="muted">About ${estimated_minutes} minutes</p>
      <button class="primary large" id="start">Train anyway</button>
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
    <button class="primary large" id="start">${status === "skipped" ? "Train anyway" : "Start"}</button>
    ${status === "skipped" ? "" : `<div class="secondary-actions">
      ${planned ? `<button class="secondary" id="move">Move</button>` : ""}
      <button class="secondary" id="skip-today">Skip today</button>
    </div>`}
    <button class="quiet" id="pick">${source === "picked" ? "Pick another" : "Train something else"}</button>`;
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
    session, today: state.today.date, notes: notesAbout(state.board?.week.notes ?? [], "session", session.id),
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
    ${plans.length ? `<h2>Also today</h2>
      <ul class="list day-sessions">${plans.map((d) => routineRow(d, todayRoutine(d), state.distanceUnit, "data-today-routine", state.today.date)).join("")}</ul>` : ""}
    ${list.length ? `<h2>Activities today</h2>
      <ul class="list day-sessions">${list.map((a) => activityRow(a, state.distanceUnit, "data-today-activity", fulfils.get(activityKey(a)))).join("")}</ul>` : ""}
    <button class="quiet" id="log-activity">${icon("plus")}Log an activity</button>`;
  renderWeek();
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
      onRemove: () => sendRoutineDay(endRoutineRequest(routine, today)),
    },
  });
}

// Sends an activity change: shown at once from the outbox, and read back
// from the server once it has it.
async function sendActivity(request) {
  outbox.enqueue(request);
  if (state.today) renderActivities();
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
  editActivity({ activity, unit: state.distanceUnit, today: state.today.date, send: sendActivity, notes: notesAbout(state.board?.week.notes ?? [], "activity", activity.id) });
}

// Asks once how hard a new activity from elsewhere was, unless that is
// turned off on Settings, and only on Today with nothing else open: one of
// the day's, or of the few days before (sent the morning after, say). One
// question a visit: answering doesn't open the next one.
async function askHowHard() {
  const free = () => !$("home").hidden && !state.run && !document.querySelector("dialog[open]") && !state.askedHowHard;
  const enabled = readSettings(storage).askRpe;
  if (!free() || !enabled) return;
  const date = state.today.date;
  // The day's own first; the days before are read only when none is left.
  let activity = rpeToAsk(todayActivities(), { asked: readAsked(storage), enabled });
  // The days before are read once a visit.
  if (!activity && state.readRecent !== date) {
    state.readRecent = date;
    try {
      const { data, stale } = await getJson(paths.recentActivities(date));
      // Today may have moved on, or asked, while the days before were read.
      if (stale || !free() || state.today?.date !== date) return;
      activity = rpeToAsk(withQueuedActivities(data, outbox.queued()), { asked: readAsked(storage), enabled });
    } catch {
      return;
    }
  }
  if (!activity) return;
  state.askedHowHard = true;
  rememberAsked(storage, activity.id);
  openRpeSheet({
    activity, unit: state.distanceUnit, today: date,
    onRpe: (rpe) => sendActivity(changeRequest(activity, { rpe }, date)),
  });
}

// ---------- Workouts ----------

// Every workout by program: the main workouts first, then the warm-up and
// cool-down that frame each session.
async function openWorkouts() {
  show("workouts");
  $("workouts-list").innerHTML = `<p class="muted">Loading…</p>`;
  try {
    // What is owned comes with the names: the cards mark missing gear.
    const [{ data: programs, stale }] = await Promise.all([getJson(paths.workouts), loadEquipmentNames()]);
    if (programs.length === 0) {
      $("workouts-list").innerHTML = offlineNote(stale) + `
        <section class="card">
          <h2>No workouts yet</h2>
          <p>Start from an example program, or build a workout of your own from the exercise library.</p>
          <div class="card-actions">
            <button class="primary small" type="button" data-examples>From an example</button>
            <a class="button secondary small" href="${routeHash("edit", "new")}">Build a workout</a>
          </div>
        </section>`;
      return;
    }
    $("workouts-list").innerHTML = offlineNote(stale) + programs.map((program) => {
      const mains = program.workouts.filter((w) => w.kind === "workout");
      const frame = program.workouts.filter((w) => w.kind !== "workout");
      return `
        <section class="program">
          <h2${programs.length > 1 ? "" : ` class="visually-hidden"`}>${escape(program.name)}</h2>
          <div class="workout-grid">${mains.map((w) => workoutCard(w, 3)).join("")}</div>
          ${frame.length ? `<h3>Every session</h3>
            <p class="muted">Each workout starts with the warm-up and ends with the cool-down. Leave them out on Today, or start one on its own.</p>
            <div class="workout-grid">${frame.map((w) => workoutCard(w, 4)).join("")}</div>` : ""}
        </section>`;
    }).join("");
  } catch (error) {
    $("workouts-list").innerHTML = `<p>${escape(loadProblem("the workouts", error, { hint: false }))}</p>`;
  }
}

// ---------- From an example ----------

// The example programs in a sheet over Workouts (example-list.js), best fit
// to the user's gear first. An import fills in the workouts behind it, and
// the line saying so closes the sheet onto them.
function openExamplesSheet() {
  const dialog = $("examples-sheet") ?? document.body.appendChild(Object.assign(document.createElement("dialog"), { id: "examples-sheet", className: "sheet" }));
  dialog.innerHTML = `
    <div class="howto">
      <header>
        <h2>From an example</h2>
        <button type="button" class="icon-button" data-close aria-label="Close">${icon("close")}</button>
      </header>
      <p class="muted">Ready-made programs to train from, the best fit to <a href="/equipment.html">your gear</a> first. An imported one is yours to change, its weights fitted to what you own.</p>
      <ul class="device-list examples" id="examples-list"><li class="muted">Loading…</li></ul>
      <p class="form-error" id="examples-error" role="alert" hidden></p>
      <p id="examples-done" hidden></p>
    </div>`;
  dialog.onclick = (event) => {
    if (event.target.closest("[data-close]") || event.target.closest("#examples-done a")) {
      event.preventDefault();
      dialog.close();
    }
  };
  mountExamples({
    list: dialog.querySelector("#examples-list"),
    error: dialog.querySelector("#examples-error"),
    done: dialog.querySelector("#examples-done"),
    href: routeHash("workouts"),
    onImported: () => {
      if (!$("workouts").hidden) openWorkouts();
    },
  }).load();
  showSheet(dialog);
}

// `level`: the card's heading, under the program's (h2) or Every session's (h3).
function workoutCard(workout, level) {
  const main = workout.kind === "workout";
  const minutes = workout.framed_minutes > workout.estimated_minutes
    ? `${workout.estimated_minutes} min, ${workout.framed_minutes} with warm-up and cool-down`
    : `${workout.estimated_minutes} min`;
  const facts = [`${icon("clock")}${minutes}`];
  if (main) facts.push(workout.last_done ? `Last done ${escape(shortDate(workout.last_done))}` : "Not done yet");
  const shown = workout.exercises.slice(0, 4).map((name) => `<li>${escape(name)}</li>`);
  if (workout.exercises.length > 4) shown.push(`<li>+${workout.exercises.length - 4} more</li>`);
  return `
    <article class="card workout-card${workout.up_next ? " up-next" : ""}">
      <a class="workout-link" href="${routeHash("workout", workout.id)}">
        <h${level}>${escape(workout.title)}${workout.up_next ? ` <span class="badge">Up next</span>` : ""}</h${level}>
        ${workout.subtitle ? `<p class="muted">${escape(workout.subtitle)}</p>` : ""}
        <p class="facts">${facts.map((fact) => `<span>${fact}</span>`).join("")}</p>
        <ul class="workout-exercises">${shown.join("")}</ul>
        ${gearChips(workout.equipment, { names: equipmentNames, owned: ownedEquipment() })}
      </a>
      <div class="workout-actions">
        <a class="button secondary small" href="${routeHash("workout", workout.id)}">View</a>
        <button class="${workout.up_next ? "primary" : "secondary"} small" data-start="${workout.id}">Start</button>
      </div>
    </article>`;
}

// ---------- Workout view ----------

// The whole workout outside a session. Weight changes are remembered for the
// exercise straight away (through the outbox), so the next session uses them;
// a running session keeps the weights it started with.
async function openWorkout(id) {
  state.workout = null;
  $("workout-title").textContent = "";
  $("workout-subtitle").textContent = "";
  $("workout-saved").textContent = state.workoutNote;
  state.workoutNote = "";
  $("workout-start").hidden = true;
  $("workout-actions").hidden = true;
  $("workout-blocks").innerHTML = `<p class="muted">Loading…</p>`;
  show("workout", id);
  aimBack("workout");
  try {
    const [{ data, stale }] = await Promise.all([getJson(paths.workout(id)), loadEquipmentNames()]);
    state.workout = data;
    state.workoutStale = stale;
    state.unit = adoptServerUnit(storage, data.unit, { queued: outbox.queued(), stale });
    renderWorkout();
    $("workout-blocks").insertAdjacentHTML("afterbegin", offlineNote(stale));
  } catch (error) {
    $("workout-blocks").innerHTML = `<p>${escape(loadProblem("this workout", error, { hint: false }))}</p>`;
    loaded("workout", id, null);
  }
}

function renderWorkout() {
  const workout = state.workout;
  $("workout-title").textContent = workout.title;
  loaded("workout", workout.id, workout.title);
  $("workout-subtitle").textContent = [workout.subtitle, `about ${workout.estimated_minutes} min`].filter(Boolean).join(" · ");
  const gear = [...new Set(workout.blocks.flatMap((block) => block.steps.flatMap((step) => neededEquipment(step) ?? [])))];
  const changes = workoutChanges(workout.changes, [workout.id]).map((change) => withoutUndo(change, state.workoutStale));
  $("workout-blocks").innerHTML = agentChangesHtml(changes) + (gear.length ? `<div class="workout-gear"><h2 class="visually-hidden">Gear</h2>
      ${gearChips(gear, { names: equipmentNames, owned: ownedEquipment(), label: "Gear it needs", classes: "equipment-list" })}</div>` : "") +
    workout.blocks.map((block, b) => `
    <section class="card block">
      <h2 class="block-head"><span class="block-label">${escape(blockName(block.label))}</span><span class="block-meta">${escape(blockSummary(block))}</span></h2>
      <ol class="steps">${block.steps.map((step, s) => stepRow(step, `${b}:${s}`)).join("")}</ol>
    </section>`).join("");
  $("workout-start").hidden = false;
  renderWorkoutOwn();
}

// An agent's edits of a workout, each with its reason and the button
// that changes it back: in the workout view and on Get ready.
function agentChangesHtml(changes) {
  return changes.map((change) => {
    const line = changeHtml(change, { today: localToday(), tag: "p" });
    return line ? `<div class="agent-change">${line}${undoButton(change, change.title)}</div>` : "";
  }).join("");
}

// Takes an agent's edit of a workout or a weight back, now (it answers
// whether it could), then `after()` reads the screen again either way.
async function takeBack(id, changes, button, after) {
  const change = (changes ?? []).find((c) => String(c.id) === id);
  if (!change || state.undoing) return;
  state.undoing = true;
  busy(button);
  try {
    await saveWeights();
    const problem = await sendChange(undoRequest(change, localToday()));
    if (problem) alert(problem);
    await after(!problem);
  } finally {
    state.undoing = false;
    if (button.isConnected) busy(button, false);
  }
}

// At the top of the workout view: Edit, which opens the editor (editor.js),
// and Duplicate and Delete under More. Deleting archives the workout so its
// sessions stay in the history; a deleted one offers a copy to edit.
function renderWorkoutOwn() {
  const workout = state.workout;
  const actions = $("workout-actions");
  actions.hidden = false;
  if (!workout.editable) {
    $("workout-subtitle").textContent += " · Deleted: its sessions stay in the history";
    actions.innerHTML = `<button class="secondary small" data-own="duplicate">Duplicate to edit</button>`;
    return;
  }
  actions.innerHTML = `
    <a class="button secondary small" href="${routeHash("edit", workout.id)}" id="workout-edit">Edit</a>
    <details class="more-actions">
      <summary title="More">${icon("more")}<span class="visually-hidden">More for this workout</span></summary>
      <div class="more-actions-list">
        <button class="quiet small" data-own="duplicate">Duplicate</button>
        <div class="danger-zone stretch"><button class="quiet small danger" data-own="delete">${icon("trash")}Delete</button></div>
      </div>
    </details>`;
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
  busy(button);
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
    busy(button, false);
  }
}

function stepRow(step, ref) {
  const weight = step.target.weight;
  const missing = missingGear(neededEquipment(step), ownedEquipment());
  const equipment = equipmentNames((neededEquipment(step) ?? []).filter((slug) => !missing.includes(slug)));
  const seed = step.weight && !sameShownWeight(step.weight, weight, state.unit) ? ` · plan: ${formatWeight(step.weight, state.unit)}` : "";
  const stepper = takesWeight(step) ? weightStepper(step.exercise.name, shownWeight(weight), `data-step="${ref}"`) : "";
  return `<li>
    <div class="step-text">
      <button class="step-name" data-howto="${ref}" aria-label="How to do ${escape(step.exercise.name)}">${escape(step.exercise.name)}${icon("info")}</button>
      <p class="muted">${escape(stepSummary(step))}${equipment.length ? ` · ${escape(equipment.join(", "))}` : ""}${seed}</p>
      ${missing.length ? gearShort(missing, state.workout.editable ? `data-swap-step="${ref}"` : "") : ""}
    </div>
    ${stepper}
  </li>`;
}

// ---------- Gear you don't have ----------

// Beside a step or a Get ready row that needs gear the user doesn't own:
// what is missing, and the two ways out. "I have this" ticks it on
// Equipment; Swap (`swap`, the button's attribute; none, no Swap) opens the
// swap sheet, whose alternatives are what the user's gear can do. A generic
// weight can't be ticked: it comes with dumbbells or a kettlebell.
function gearShort(missing, swap) {
  // A generic weight reads as what it is: any weight will do.
  const names = equipmentNames(missing).map((name, i) => (isAnyWeight(missing[i]) ? "a weight" : name));
  const tickable = missing.filter((slug) => !isAnyWeight(slug) && equipmentId(slug) != null);
  return `<div class="gear-short">
    <p>${icon("close")}<span>Needs ${escape(nameList(names))}: not yours yet.</span></p>
    <div class="gear-ways">
      ${tickable.map((slug) => {
        const [name] = equipmentNames([slug]);
        // With more than one to tick, each button names its own.
        const label = tickable.length > 1 ? `I have ${escape(name)}` : `I have this<span class="visually-hidden">: ${escape(name)}</span>`;
        return `<button type="button" class="secondary small" data-have="${escape(slug)}">${label}</button>`;
      }).join("")}
      ${tickable.length < missing.length ? `<a class="button secondary small" href="/equipment.html">Add your weights</a>` : ""}
      ${swap ? `<button type="button" class="secondary small" ${swap}>${icon("swap")}Swap</button>` : ""}
    </div>
  </div>`;
}

// Ticks `slug` as owned on Equipment, then draws the screen again (`after`)
// with what is owned now. `note(text)` says what happened.
async function haveGear(slug, button, { after, note }) {
  const [name] = equipmentNames([slug]);
  busy(button);
  try {
    const response = await send(`/api/equipment/${equipmentId(slug)}`, { method: "PATCH", body: { owned: true } });
    if (!response.ok) throw new Error(errorMessage(await response.json().catch(() => null), response.status));
    await loadEquipmentNames(fetch, { fresh: true });
    // The server said yes: a list read from a cache, or not read, doesn't undo it.
    markOwned(slug);
    forgetAlternatives();
    busy(button, false);
    await after();
    note(comesInWeights(slug) ? `${name} is ticked on Equipment. List the weights you have there.` : `${name} is ticked on Equipment.`);
  } catch (error) {
    busy(button, false);
    note(error instanceof TypeError ? "Couldn't reach the server. Try again when you're online." : `Not ticked: ${error.message}`);
  }
}

// The workout read again, as the server now plans it with the gear owned
// (which weights a step steps through), and drawn again.
async function rereadWorkout() {
  const workout = state.workout;
  if (!workout) return;
  try {
    const { data } = await getJson(paths.workout(workout.id));
    if (state.workout === workout) state.workout = data;
  } catch {
    // Offline: drawn as it was read, with the gear marks as they are now.
  }
  if (state.workout?.id === workout.id) renderWorkout();
}

// Swap in the workout view: the step's exercise for another, in the workout
// itself (saved as the editor saves it), not only for one session.
async function swapWorkoutStep(ref) {
  const workout = state.workout;
  const step = workoutStep(ref);
  await saveWeights();
  // The new step's weight starts from the gear owned for it: no list, no swap.
  let inventory;
  try {
    inventory = (await getJson(paths.equipment)).data;
  } catch {
    $("workout-saved").textContent = "Couldn't reach the server. Try again when you're online.";
    return;
  }
  if (state.workout !== workout) return;
  openSwap({
    planned: step.exercise,
    current: step.exercise,
    inSession: new Set(workout.blocks.flatMap((block) => block.steps.map((other) => other.exercise.id))),
    unit: state.unit,
    note: "Changes this step of the workout. Its other steps stay as they are.",
    alreadyIn: "In this workout",
    onPick: (exercise) => replaceWorkoutExercise(ref, exercise, inventory),
  });
}

async function replaceWorkoutExercise(ref, exercise, inventory) {
  const workout = state.workout;
  const [b, s] = ref.split(":").map(Number);
  const draft = draftFrom(workout);
  const step = draft.blocks[b].steps[s];
  const before = { ...step };
  setExercise(step, exercise, inventory, state.unit);
  // The amount stays when the new exercise is done the same way, sides
  // counted the same; otherwise it starts from the exercise's own.
  const sameSides = Boolean(before.exercise.unilateral) === Boolean(exercise.unilateral) &&
    Boolean(before.exercise.alternating) === Boolean(exercise.alternating);
  if (before.mode === step.mode && sameSides) Object.assign(step, { reps: before.reps, seconds: before.seconds });
  const request = saveRequest(draft);
  try {
    await sendWorkout(request.method, request.path, request.body);
    // Still on this workout: it is read again with the swap, and says so.
    if (state.workout !== workout) return;
    state.workoutNote = `${exercise.name} instead of ${workout.blocks[b].steps[s].exercise.name}.`;
    openWorkout(workout.id);
  } catch (error) {
    $("workout-saved").textContent = error instanceof TypeError ? "Couldn't reach the server. Try again when you're online." : `Not swapped: ${error.message}`;
  }
}

// Shown for a step that takes a weight but has none (yet, or on purpose).
const NO_WEIGHT = "no weight";
// A weight with no gear named, as the generic gear is called.
const ANY_WEIGHT = "Any weight";

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

// Taps are gathered so a run of + presses saves once, with the weight the
// user settled on.
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
  goBack();
}

async function startWorkout(id) {
  await saveWeights();
  if (state.parked) return askAboutParked();
  // Stays on this page until the session opens, so Back on Get ready returns here.
  if (await loadToday(id)) startSession();
  else show("home");
}

// ---------- Get ready ----------

// `ready`: Get ready even when the session needs nothing to pick up (drawn
// again after a change was taken back there).
function startSession({ ready = false } = {}) {
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
  $("ready-note").textContent = "";
  if (!ready && state.run.equipment.length === 0 && state.run.targets.length === 0) beginPlayer();
  else showReady();
}

function showReady() {
  const run = state.run;
  run.stage = "ready";
  saveRun();
  $("ready-title").textContent = run.title;
  // Everything the session needs, one row each, with what it is for.
  // Rows to tick off while fetching; nothing is kept.
  const gear = gearList(run.items, run.targets);
  state.readyGear = gear;
  const owned = ownedEquipment();
  // Gear the user doesn't own is no row to tick: it says so, with the ways out.
  $("ready-pickup").innerHTML = gear.map((row, i) => missingGear(row.equipment ? [row.equipment] : [], owned).length ? `
    <li class="ready-missing"><div class="row"><span class="row-text">
      <span class="row-title">${escape(gearTitle(row))}</span>
      <span class="row-meta">${escape(row.exercises.join(", "))}</span>
    </span></div>${gearShort([row.equipment], `data-swap-row="${i}"`)}</li>` : `
    <li><label class="row check-row"><input type="checkbox"><span class="row-text">
      <span class="row-title">${escape(gearTitle(row))}</span>
      <span class="row-meta">${escape(row.exercises.join(", "))}</span>
    </span></label></li>`).join("");
  $("ready-go").textContent = startLabel(run.items[run.index] ?? run.items[0]);
  $("ready-need").hidden = gear.length === 0;
  $("ready-weights").hidden = run.targets.length === 0;
  const changes = readyChanges();
  $("ready-changes").innerHTML = agentChangesHtml(workoutChanges(changes, [...new Set(run.items.map((item) => item.workout.id))]));
  $("ready-targets").innerHTML = run.targets.map((t, i) => {
    const change = weightChange(changes, t.exercise.id);
    // In its own unit, the gear's, as the stepper beside it shows it.
    const line = change && changeHtml(change, { today: localToday(), tag: "p" });
    return `<li><span>${escape(t.exercise.name)}</span>
      ${weightStepper(t.exercise.name, shownLoad(t.weight, t.weights_held), `data-target="${i}"`)}
      ${line ? `<div class="agent-change">${line}${undoButton(change, `${t.exercise.name}'s weight`)}</div>` : ""}</li>`;
  }).join("");
  show("ready");
}

// The agent's edits and weights Today gave for this session's workout; none
// for a session picked up after a reload, until Today is read again.
// A copy kept on the device can't say what can still be taken back.
function readyChanges() {
  if (!state.today || state.today.workout_id !== state.run?.workoutId) return [];
  return (state.today.changes ?? []).map((change) => withoutUndo(change, state.todayStale));
}

// Get ready again, as the server now plans the workout after a change was
// taken back, kept going back where Start was pressed.
async function reloadReady() {
  const run = state.run;
  if (!run || run.stage !== "ready") return;
  // Read as Today was (the rotation, a picked workout or a picked session).
  if (!(await reloadToday()) || state.run !== run) return;
  if (state.today.workout_id !== run.workoutId) return showReady();
  startSession({ ready: true });
  if (state.run && state.run !== run) {
    state.run.from = run.from;
    saveRun();
  }
}

// Swap on Get ready: the first exercise of row `rowIndex` (gear the user
// doesn't own) still to come, for the rest of the session, as the player
// swaps. Get ready is drawn again with what it needs now.
function swapReadyGear(rowIndex) {
  const run = state.run;
  const row = state.readyGear?.[rowIndex];
  if (!run || !row) return;
  const index = run.items.findIndex((item, i) => i >= run.index && run.logged?.[i] == null && item.type === "exercise" &&
    (item.equipment ?? []).includes(row.equipment) && row.exercises.includes(item.exercise.name));
  if (index < 0) {
    $("ready-note").textContent = `Nothing still to come needs ${equipmentNames([row.equipment])[0]}.`;
    return;
  }
  const item = run.items[index];
  openSwap({
    planned: plannedExercise(item),
    current: item.exercise,
    inSession: new Set(run.items.filter((i) => i.type === "exercise").map((i) => i.exercise.id)),
    unit: state.unit,
    onPick: (exercise) => {
      if (state.run !== run) return;
      Object.assign(run, swapRun(run, index, exercise));
      run.targets = swapTargets(run.targets, run.items, comesInWeights);
      showReady();
    },
  });
}

// A Get ready row: the equipment, with the load to pick up when it carries one.
function gearTitle(row) {
  const name = row.equipment ? equipmentNames([row.equipment])[0] : ANY_WEIGHT;
  if (row.load) return `${name}, ${row.load.held === 2 ? formatLoad(row.load.weight, 2, state.unit) : formatWeight(row.load.weight, state.unit)}`;
  if (row.unset) return `${name}, no weight set`;
  return name;
}

// Get ready's primary, named for what it starts: "Start warm-up",
// "Start Workout 1" (a session picked up starts where it left off).
function startLabel(first) {
  const { kind, title } = first.workout;
  return { warmup: "Start warm-up", cooldown: "Start cool-down" }[kind] ?? `Start ${title}`;
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
  for (const item of state.run.items) {
    if (item.exercise?.id !== target.exercise.id) continue;
    item.weight = inUnit(weight, item.weight_unit);
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
  // Moving on lets a skipped warm-up or cool-down go ahead.
  settleSkip();
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
  state.mainChangedAt = performance.now();
  saveRun();
  render();
  announceStep();
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
  announce(countdown.isRunning(state.timer) ? "Going again" : "Paused");
  saveRun();
  render();
}

function onMainAction() {
  unlock();
  // The second tap of a double tap would act on the button's new meaning.
  if (!tapAccepted(state.mainChangedAt, performance.now())) return;
  if (state.phase === "reps") {
    logSet(current(), "done");
    goTo(state.run.index + 1);
  } else if (state.phase === "work") {
    // A hold ended early counts as done, for the seconds held; one ended
    // straight away was not done.
    const held = Math.round(countdown.elapsed(state.timer, performance.now()) / 1000);
    logSet(current(), holdStatus(held, current().seconds), { seconds: held });
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

// Skips what is left of the warm-up or cool-down in one go. Its sets are
// logged skipped once the undo has had its chance: when the toast goes, or
// as soon as the session moves on. Skipping the last part goes straight to
// the finish, so those are logged at once.
function skipPart() {
  const run = state.run;
  const from = run.index;
  const end = partEnd(run.items, from);
  const title = current().workout.title;
  if (end >= run.items.length) {
    logSkipped(run, { from, end });
    return goTo(end);
  }
  goTo(end);
  run.skipping = { from, end };
  saveRun();
  state.skipTimer = setTimeout(settleSkip, UNDO_DISCARD_MS);
  showToast(`${title} skipped.`, "Undo", undoSkip, "skip");
}

// The skip waiting on its undo, taken off the run.
function takeSkip() {
  const skipping = state.run?.skipping;
  if (!skipping) return null;
  clearTimeout(state.skipTimer);
  delete state.run.skipping;
  if ($("toast").dataset.kind === "skip") hideToast();
  return skipping;
}

function logSkipped(run, { from, end }) {
  unloggedExercises(run.items, from, end, run.logged).forEach((i) => logSet(run.items[i], "skipped", { index: i }));
}

function settleSkip() {
  const skipping = takeSkip();
  if (!skipping) return;
  logSkipped(state.run, skipping);
  saveRun();
}

function undoSkip() {
  const skipping = takeSkip();
  if (skipping) goTo(skipping.from);
}

function onSkip() {
  // Skip takes the place the rest's button had a moment ago.
  if (!tapAccepted(state.mainChangedAt, performance.now())) return;
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
  state.mainChangedAt = performance.now();
  announce("Go");
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
  // A skipped part is logged before what comes after it.
  settleSkip();
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
  const at = shownIndex();
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

// The player draws ten times a second during a countdown. These touch the
// page only where something differs, so a button under a finger is never
// replaced mid-press and a screen reader isn't handed the same text again.
const drawn = new WeakMap();
function setText(id, text) {
  const el = $(id);
  if (el.textContent !== String(text)) el.textContent = text;
}
function setHtml(id, html) {
  const el = $(id);
  if (drawn.get(el) === html) return;
  el.innerHTML = html;
  drawn.set(el, html);
}
function setHidden(id, hidden) {
  const el = $(id);
  if (el.hidden !== hidden) el.hidden = hidden;
}
// Styles are compared with what was set, not read back: the browser rounds.
function setStyle(id, property, value) {
  const el = $(id);
  const styles = drawn.get(el.style) ?? {};
  if (styles[property] === value) return;
  el.style[property] = value;
  drawn.set(el.style, { ...styles, [property]: value });
}

// Says something once through the polite live region. It is emptied first
// and filled a moment later, so the same words twice (a step resumed) and
// words set as the player appears are both spoken.
function announce(text) {
  const region = $("announce");
  region.textContent = "";
  clearTimeout(state.announceTimer);
  state.announceTimer = setTimeout(() => { region.textContent = text; }, 100);
}

// "Switch sides" shows on the right side's lead-in and for a moment after
// moving on from the left.
function switching(item, now = performance.now()) {
  return item.side === "right" && (state.phase === "lead" || now < state.switchCueUntil);
}

function render() {
  const run = state.run;
  const item = current();
  const now = performance.now();
  const resting = item.type === "rest";
  const paused = !!state.timer && !countdown.isRunning(state.timer);
  document.body.classList.toggle("paused", paused);
  setHidden("paused-note", !paused);
  setHidden("timer-actions", !state.timer);
  setText("pause", paused ? "Resume" : "Pause");
  setHidden("more-time", !extraSeconds(state.phase));
  setText("more-time", `+${extraSeconds(state.phase)} s`);
  $("count-box").classList.toggle("pausable", !!state.timer);

  // The bar fills by time, not by screens: a rest is as long as it lasts.
  setStyle("progress-bar", "width", `${progressAt(run.items, run.index) * 100}%`);
  setText("where", `${item.workout.title} · ${blockName(item.block.label)}`);
  const left = minutesLeft(run.items, run.index);
  setText("count", left > 1 ? `about ${left} min left` : "almost done");

  const seconds = state.timer ? countdown.displaySeconds(state.timer, now) : null;
  const next = resting ? nextExercise() : null;
  const switchingSides = !resting && switching(item, now);
  // One colour per phase, on the badge and the ring; the badge says the word.
  const phase = resting ? "rest" : switchingSides ? "switch" : state.phase;
  if ($("player").dataset.phase !== phase) $("player").dataset.phase = phase;
  setText("phase", { lead: "Get ready", work: "Go", rest: "Rest", switch: "Switch sides" }[phase] ?? "");
  setHidden("phase", phase === "reps");
  // A rest prepares the next set: what it is, how much, the load to pick up.
  setHidden("up-next", !next);
  if (next) setText("up-next", upNextLabel(next));
  if (resting) {
    setText("exercise-name", next ? next.exercise.name : "Rest");
    setHidden("side", true);
    setHidden("set-label", true);
    renderLoadLine(next);
    setText("details", next ? upNextDetails(next) : "");
    renderGear(next, nextExerciseIndex());
    setHtml("cues", "");
  } else {
    setText("exercise-name", item.exercise.name);
    setText("set-label", setLabel(item));
    setHidden("set-label", !setLabel(item));
    setHidden("side", !item.side);
    // The side as a large letter as well as the word.
    setHtml("side", item.side ? `<span class="side-letter" aria-hidden="true">${item.side === "left" ? "L" : "R"}</span>${item.side === "left" ? "Left" : "Right"} side` : "");
    renderLoadLine(item);
    setText("details", details(item));
    renderGear(item, run.index);
    setHtml("cues", item.exercise.cues.map((cue) => `<li>${escape(cue)}</li>`).join(""));
  }
  // A set of reps counts what was done, the target until changed: "7" over
  // "of 8", with − and + either side.
  const counting = state.phase === "reps" && !resting && !!item.reps;
  setHidden("reps-down", !counting);
  setHidden("reps-up", !counting);
  $("count-box").classList.toggle("counting", counting);
  const count = counting ? repsCount(item, repsDone()) : null;
  // A set with no reps to log shows its note ("max"), or "Go".
  const shown = counting ? repsDone() : state.phase === "reps" && !resting ? item.note ?? "Go" : seconds;
  // A countdown keeps the size of its longest number all the way down.
  const longest = state.timer ? String(Math.ceil(state.timer.totalMs / 1000)) : "";
  renderTarget(shown, count?.spoken ?? spokenTarget(item, { phase: state.phase, seconds }), longest);
  const unit = state.timer ? (seconds === 1 ? "second" : "seconds") : count?.unit ?? "";
  setText("count-unit", paused ? "" : unit);

  // The ring drains for holds, lead-ins and rests; a set of reps has none,
  // and the count keeps its place either way.
  setStyle("ring", "visibility", state.timer ? "visible" : "hidden");
  if (state.timer) setStyle("ring-arc", "strokeDashoffset", String(-(1 - countdown.remainingMs(state.timer, now) / state.timer.totalMs)));

  // A rest shows the next exercise standing still: a moving figure reads
  // as "do this now".
  renderFigure(resting ? next : item, { still: resting });
  // In a rest, How to and Swap are for the exercise coming up.
  setHidden("howto-open", resting && !next);
  setHidden("swap-open", resting && !next);

  const after = run.items[run.index + 1];
  // A rest already says what is next.
  setText("next", resting ? "" : after ? `Next: ${label(after)}` : "Last one");

  // A rest has one way forward: the main button, quiet and in the rest colour.
  setText("main-action", mainActionLabel(state.phase, next));
  $("main-action").classList.toggle("rest-action", resting);
  setHidden("skip", resting);
  const framing = item.workout.kind !== "workout" && run.items.some((i) => i.workout.kind === "workout");
  setHidden("skip-part", !framing);
  if (framing) setText("skip-part", `Skip ${item.workout.title.toLowerCase()}`);
}

// The big count as it shows, and as words for a screen reader ("8 reps",
// "45 seconds"), which reads the words alone.
function renderTarget(shown, spoken, longest = "") {
  const text = String(shown ?? "");
  setText("target-shown", text);
  // Longer counts and words take a smaller size, so they stay in the ring.
  const size = Math.max(text.length, longest.length);
  const length = size <= 2 ? "" : size <= 3 ? "3" : size <= 5 ? "5" : "long";
  if ($("target").dataset.len !== length) $("target").dataset.len = length;
  setText("target-spoken", spoken);
}

// The step as one sentence, said once as the player moves to it.
function announceStep() {
  const item = current();
  if (item.type === "rest") return announce(stepAnnouncement(item, { next: nextExercise() }));
  const weight = takesWeight(item) && item.weight ? inUnit(item.weight, state.unit) : null;
  announce(stepAnnouncement(item, { weight, switching: switching(item) }));
}

// Keeps the same animation running across re-renders; swaps it when the
// exercise or side changes.
function renderFigure(item, { still = false } = {}) {
  const animation = item?.exercise.animation;
  const mirror = item?.side === "right";
  const key = animation ? `${item.exercise.id}:${mirror}:${still}` : null;
  if (state.figure?.key !== key) {
    state.figure?.view.destroy();
    state.figure = key && { key, view: createFigure($("figure"), animation, { mirror, label: item.exercise.name, still }) };
  }
  // A step without a drawing keeps the empty frame, so nothing under it moves.
  $("figure").hidden = false;
  setStyle("figure", "visibility", key ? "visible" : "hidden");
  if (!state.figure || still) return;
  if (document.body.classList.contains("paused")) state.figure.view.pause();
  else state.figure.view.play();
}

function clearFigure() {
  state.figure?.view.destroy();
  state.figure = null;
  $("figure").hidden = true;
}

// The set How to, Swap and the load line act on: in a rest, the one coming up.
function shownIndex() {
  return current().type === "rest" ? nextExerciseIndex() : state.run.index;
}

function shownExercise() {
  return state.run.items[shownIndex()];
}

// Pauses a running countdown while the how-to is open; Resume carries on.
function showHowto() {
  const item = shownExercise();
  if (state.timer && countdown.isRunning(state.timer)) togglePause();
  openHowto(item.exercise, { mirror: item.side === "right", tempo: item.tempo });
}

// Swapping pauses a running countdown, like the how-to; picking an exercise
// restarts the current set with it. In a rest it swaps the exercise coming
// up, and the rest carries on.
function showSwap() {
  const resting = current().type === "rest";
  const index = shownIndex();
  const item = state.run.items[index];
  if (state.timer && countdown.isRunning(state.timer)) togglePause();
  openSwap({
    planned: plannedExercise(item),
    current: item.exercise,
    inSession: new Set(state.run.items.filter((i) => i.type === "exercise").map((i) => i.exercise.id)),
    unit: state.unit,
    onPick: (exercise) => {
      Object.assign(state.run, swapRun(state.run, index, exercise));
      if (!resting) return goTo(state.run.index);
      saveRun();
      render();
      announceStep();
    },
  });
}

function prefetchSwaps() {
  prefetchAlternatives(state.run.items.filter((i) => i.type === "exercise").map((i) => plannedExercise(i).id));
}

// The load line: what to pick up and its weight, with its stepper.
function renderLoadLine(item) {
  const weighted = !!item && takesWeight(item);
  setHidden("weight-stepper", !weighted);
  if (weighted) setText("weight-value", loadLine(item));
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

// The thing to pick up, named and following the weight as it steps:
// "Kettlebell, 40 lb", "Dumbbells, 2 × 10 lb"; "no weight" with none.
function loadLine(item) {
  if (!item.weight) return NO_WEIGHT;
  const slug = carries(item) ? carrierOf(item) : null;
  const load = item.weights_held === 2 ? formatLoad(item.weight, 2, state.unit) : formatWeight(item.weight, state.unit);
  return slug ? `${equipmentNames([slug])[0]}, ${load}` : load;
}

// Whether the gear named for a weight is gear in set weights (any weight,
// dumbbells), not, say, the bench a weighted step-up is done on.
function carries(item) {
  return !!(item.any_weight || item.allowed_weights);
}

// The gear the load line doesn't already name.
function otherGear(item) {
  if (!takesWeight(item) || !item.weight || !carries(item)) return item.equipment ?? [];
  const named = new Set([carrierOf(item), item.any_weight?.slug]);
  return (item.equipment ?? []).filter((slug) => !named.has(slug));
}

// Everything else the exercise at `index` is done with, marked when it changes.
function renderGear(item, index) {
  const names = item ? equipmentNames(otherGear(item)) : [];
  setHidden("equipment", names.length === 0);
  $("equipment").classList.toggle("changed", names.length > 0 && equipmentChanges(state.run.items, index));
  setHtml("equipment", names.map((name) => `<li>${escape(name)}</li>`).join(""));
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
// nothing logged yet discarding comes first; after that it is a delete.
function quit() {
  const running = state.timer && countdown.isRunning(state.timer);
  if (running) togglePause();
  const { exercises, done, sets } = sessionProgress(state.run);
  const sheet = $("end-sheet");
  // With nothing logged, Discard loses nothing and is the likely choice. With
  // sets logged it throws them away: it looks it, and sits apart under a line.
  const keep = `<button class="${sets ? "primary" : "secondary"}" value="keep">Keep going</button>`;
  const finish = `<button class="secondary" value="finish">Finish here</button>`;
  const discard = sets
    ? `<div class="danger-zone stretch"><button class="secondary danger" value="discard">Discard</button></div>`
    : `<button class="primary" value="discard">Discard</button>`;
  sheet.innerHTML = `
    <form method="dialog" class="howto">
      <h2>End this session?</h2>
      <p class="muted">${sets
        ? `${done} of ${exercises} exercises done, ${sets} ${sets === 1 ? "set" : "sets"}. Finish here keeps them${state.run.pickedUp ? "" : "; Discard deletes the session"}.`
        : "Nothing logged yet."}</p>
      ${state.run.pickedUp ? `<div class="choices">${keep + finish}</div>`
        : sets ? `<div class="choices">${keep + finish}</div>${discard}` : `<div class="choices">${discard + keep + finish}</div>`}
    </form>`;
  sheet.returnValue = "keep";
  sheet.addEventListener("close", () => {
    // Keep going keeps a skip's undo; ending the session lets it go ahead.
    if (sheet.returnValue !== "keep") settleSkip();
    if (sheet.returnValue === "finish") return finishEarly(state.run);
    if (sheet.returnValue === "discard") return discardRun(state.run);
    if (running) togglePause();
  }, { once: true });
  showSheet(sheet);
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
  document.body.classList.remove("paused");
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

function showToast(text, action, onAction, kind = "") {
  const toast = $("toast");
  toast.dataset.kind = kind;
  // In the player it sits just under the top bar, however tall that is.
  if (!$("player").hidden) toast.style.setProperty("--toast-top", `${$("player").querySelector(".player-top").getBoundingClientRect().bottom + 8}px`);
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
  settleSkip();
  const run = state.run;
  stopTimer();
  releaseWakeLock();
  clearFigure();
  document.body.classList.remove("paused");
  if (run.stage !== "finish") {
    run.stage = "finish";
    run.minutes = Math.max(1, Math.round((Date.now() - run.startedAt) / 60000));
  }
  saveRun();

  // The main workout's numbers; the warm-up and cool-down get a line of their own.
  const { exercises, done, sets, planned, skipped, swaps, frames } = finishSummary(run);
  const plural = (n, word) => `${n} ${n === 1 ? word : `${word}s`}`;
  $("finish-title").textContent = run.endedEarly ? `${run.title}: ended early` : `${run.title} done`;
  $("finish-badge").classList.toggle("partial", !!run.endedEarly);
  $("finish-stats").innerHTML = [
    [done === exercises ? exercises : `${done}/${exercises}`, "exercises"],
    [sets === planned ? sets : `${sets}/${planned}`, "sets"],
    [run.minutes, run.minutes === 1 ? "minute" : "minutes"],
  ].map(([value, label]) => `<div><dt>${label}</dt><dd>${value}</dd></div>`).join("");
  const summary = [skipped && `${skipped} skipped`, swaps && plural(swaps, "swap"), framingLine(frames)].filter(Boolean).join(" · ");
  $("summary").textContent = summary;
  $("summary").hidden = !summary;
  renderChanges();
  renderFeedback();
  // Kept with the run, so a reload keeps it and another run starts blank.
  $("finish-note").value = run.note ?? "";
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
  $("rpe").innerHTML = rpeOptions({ rpe: state.rpe });
  document.querySelectorAll("[data-feedback]").forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.feedback === state.feedback));
  });
}

async function submitFinish() {
  const feedback = state.feedback;
  const run = state.run;
  const { key, requests } = finishRequests(run, { rpe: state.rpe, feedback, note: run.note });
  requests.forEach((request) => outbox.enqueue(request));
  clearRun();
  state.rpe = null;
  state.feedback = null;
  $("finish-note").value = "";

  $("finish-form").hidden = true;
  $("finish-done").hidden = false;
  $("finish-result").textContent = "Saving…";
  $("finish-week").hidden = true;
  $("finish-next").hidden = true;
  $("next-up").hidden = true;

  const synced = await sync();
  const result = outbox.result(key);
  if (!synced) {
    $("finish-result").innerHTML = outbox.waiting() === "auth"
      ? `Saved on this device. <a href="${escape(signInHref(location))}">Sign in again</a> and it will sync.`
      : "Saved on this device. It will sync when the server is reachable.";
    return;
  }
  if (!result && outbox.isParked(key)) {
    $("finish-result").textContent = "Saved on this device, but the server kept failing on it. Try it again from Settings, Account.";
    return;
  }
  if (!result) {
    $("finish-result").textContent = "The server would not take this session. The reason is on the home screen.";
    return;
  }
  $("finish-result").textContent = "See you next time.";
  showWeekAfterFinish();
}

// Now that the session is saved, the card leads with the week (how many of
// its strength sessions are done) and says when the next one is planned.
// With nothing more planned this week, it links to the program's workout up
// next instead. Offline, the card does without either.
async function showWeekAfterFinish() {
  const today = localToday();
  try {
    const { data: board, stale } = await getJson(paths.coach(today));
    if ($("finish").hidden) return;
    // A board cached before the finish would count this session as not done.
    if (stale) return await showNextUp();
    const week = queuedWeek(board.week, outbox.queued(), today);
    const lead = strengthWeekLine(week);
    $("finish-week").textContent = lead ?? "";
    $("finish-week").hidden = !lead;
    const next = nextSessionLine(week.sessions, today);
    $("finish-next").textContent = next ?? "";
    $("finish-next").hidden = !next;
    if (!next) await showNextUp();
  } catch {
    await showNextUp();
  }
}

// The program's main workout up next, as a link.
async function showNextUp() {
  try {
    const { data: programs } = await getJson(paths.workouts);
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
      getJson(paths.history(localToday())),
      getJson(paths.exerciseHistory),
    ]);
    const { done: week = 0, partial = 0 } = history.weeks[0] ?? {};
    $("history-week").textContent = [`This week: ${week} ${week === 1 ? "session" : "sessions"} done${partial ? `, ${partial} ended early` : ""}`,
      stale || staleExercises ? STALE_NOTE : ""].filter(Boolean).join(" · ");
    $("history-list").innerHTML = history.sessions.length
      ? history.sessions.map(historyRow).join("")
      : `<li class="row muted">Nothing in the last four weeks yet. <a href="/#today">Go to Today</a> to train.</li>`;
    $("history-exercises").innerHTML = exercises.length
      ? exercises.map(exerciseRow).join("")
      : `<li class="row muted">Exercises show up here once you log a set.</li>`;
  } catch (error) {
    $("history-list").innerHTML = `<li class="row">${escape(loadProblem("the history", error))}</li>`;
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
  aimBack("exercise-history");
  $("exercise-history-name").textContent = "";
  $("exercise-history-remembered").textContent = "";
  $("exercise-history-list").innerHTML = `<li class="row muted">Loading…</li>`;
  try {
    const { data: history, stale } = await getJson(`/api/exercises/${id}/history`);
    $("exercise-history-name").textContent = history.exercise.name;
    loaded("exercise-history", id, history.exercise.name);
    $("exercise-history-remembered").textContent = [
      history.remembered?.value != null ? `Next time: ${formatWeight(history.remembered, state.unit)}`
        : history.remembered?.unit ? `Next time: ${NO_WEIGHT}` : "",
      stale ? STALE_NOTE : "",
    ].filter(Boolean).join(" · ");
    $("exercise-history-list").innerHTML = history.sessions.length
      ? history.sessions.map(exerciseSessionRow).join("")
      : `<li class="row muted">Nothing logged yet.</li>`;
  } catch (error) {
    $("exercise-history-list").innerHTML = `<li class="row">${escape(loadProblem("this exercise's history", error))}</li>`;
    loaded("exercise-history", id, null);
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
  aimBack("session");
  $("session-title").textContent = "";
  $("session-summary").textContent = "";
  $("session-note").hidden = true;
  $("session-delete").hidden = true;
  $("session-exercises").innerHTML = `<li class="muted">Loading…</li>`;
  $("session-exercises").hidden = false;
  $("session-frames").innerHTML = "";
  try {
    const { data: session, stale } = await getJson(`/api/sessions/${id}`);
    const date = weekdayDate(session.date);
    $("session-title").textContent = session.workout.title;
    loaded("session", id, session.workout.title);
    $("session-summary").textContent = [date, sessionSummary(session), stale ? STALE_NOTE : ""].filter(Boolean).join(" · ");
    $("session-note").textContent = session.completion?.note ?? "";
    $("session-note").hidden = !session.completion?.note;
    // The main workout first and open; the warm-up and cool-down folded to a line.
    const parts = sessionParts(session.exercises);
    const rows = parts.find((part) => part.part === "workout")?.entries ?? [];
    $("session-exercises").innerHTML = session.exercises.length
      ? rows.map(sessionExerciseRow).join("")
      : `<li class="muted">No sets were logged in this session.</li>`;
    $("session-exercises").hidden = session.exercises.length > 0 && rows.length === 0;
    $("session-frames").innerHTML = parts.filter((part) => part.part !== "workout").map((part) => `
      <details class="session-part">
        <summary>${escape(partLine(part))}</summary>
        <ul class="list">${part.entries.map(sessionExerciseRow).join("")}</ul>
      </details>`).join("");
    Object.assign($("session-delete").dataset, { delete: session.id, label: `${session.workout.title} on ${date}` });
    $("session-delete").hidden = false;
  } catch (error) {
    $("session-exercises").innerHTML = `<li>${escape(loadProblem("this session", error))}</li>`;
    loaded("session", id, null);
  }
}

function sessionExerciseRow(entry) {
  const { done, skipped } = exerciseSummary(entry, state.unit);
  const notes = [];
  if (entry.instead_of) notes.push(`instead of ${entry.instead_of.name}`);
  if (done && skipped) notes.push(`${skipped} skipped`);
  return `<li><button class="row${done ? "" : " skipped"}" data-exercise="${entry.exercise.id}"><span class="row-text">
    <span class="row-title">${escape(entry.exercise.name)}</span>
    <span class="row-meta sets">${escape([done || "Skipped", ...notes].join(" · "))}</span></span>${icon("chevron-right")}</button></li>`;
}

// Deleting needs the server, like loading the history does, so it is not
// queued: the user sees right away whether it worked.
async function deleteSession(button) {
  if (!confirm(`Delete ${button.dataset.label} and every set logged in it? This cannot be undone.`)) return;
  busy(button);
  try {
    const response = await send(`/api/sessions/${button.dataset.delete}`, { method: "DELETE" });
    if (!response.ok && response.status !== 404) throw new Error(`HTTP ${response.status}`);
    busy(button, false);
    go(routeHash("history"));
  } catch (error) {
    busy(button, false);
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
    if (!countdown.isRunning(state.timer)) announce("Paused");
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
  // Not in the editor either: its buttons would leave the draft unasked.
  box.hidden = !run || isSessionView(view) || view === "edit";
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
    <button class="primary large" data-parked="resume">Resume</button>
    <div class="secondary-actions">
      <button class="secondary" data-parked="finish">Finish with what I did</button>
    </div>
    ${run.pickedUp ? "" : `<div class="danger-zone"><button class="secondary small danger" data-parked="discard">Discard</button></div>`}`;
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
  const parked = outbox.parkedCount();
  $("sync-parked").hidden = parked === 0;
  $("sync-parked").innerHTML = parked === 0 ? "" : parkedNote(parked);
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
  const hash = routeHash(view, id);
  const changed = state.shownHash && state.shownHash !== hash;
  for (const other of ["home", "workouts", "workout", "edit", "ready", "player", "finish", "history", "exercise-history", "session"]) $(other).hidden = other !== view;
  state.shownHash = hash;
  nameView(viewLabel(view));
  // A view that replaces another takes the focus to its heading, so a screen
  // reader starts there, as on a new page: a detail once its name is in
  // (loaded()). The session screens say their step in the live region
  // instead, and the editor focuses its first field.
  const focus = changed && !isSessionView(view) && view !== "edit";
  state.focusOnLoad = focus && Boolean(id);
  if (focus && !id) focusHeading(view);
  trailTo(hash);
  const entering = isSessionView(view) && location.hash !== hash;
  if (entering) history.pushState({ session: true }, "", hash);
  else if (location.hash !== hash) {
    history.replaceState(null, "", hash);
    state.pushedFrom = null; // no link brought this view
  }
  // The session screens and the editor hide the navigation: one tap on a tab
  // would leave a session, or a draft.
  if (isSessionView(view)) document.body.dataset.focus = "";
  else if (view === "edit") document.body.dataset.focus = "edit";
  else document.body.removeAttribute("data-focus");
  nav.setCurrent(pageFor(view));
  renderParked(view);
  window.scrollTo(0, 0);
}

// The tab's title: the view's name, and a detail's own once it has loaded.
function nameView(name) {
  const title = name ? `${name} · The Lazy Runner` : "The Lazy Runner";
  if (document.title !== title) document.title = title;
}

// A detail has loaded, or failed to (`name` null): it names the tab and the
// heading takes the focus, unless another view or item has replaced it in
// the meantime.
function loaded(view, id, name) {
  if (state.shownHash !== routeHash(view, id)) return;
  nameView(name ?? viewLabel(view));
  // Failed: the heading says what it is, over the problem.
  const heading = $(view).querySelector("h1");
  if (!name && heading && !heading.textContent) heading.textContent = viewLabel(view);
  if (!state.focusOnLoad) return;
  state.focusOnLoad = false;
  focusHeading(view);
}

function focusHeading(view) {
  const heading = $(view).querySelector("h1");
  if (!heading) return;
  heading.setAttribute("tabindex", "-1");
  heading.focus({ preventScroll: true });
}

// Navigates as a link would, so the phone's back button returns here.
function go(hash) {
  location.hash = hash;
}

// The views opened on this page, latest last: going to the one before goes
// back along it, any other is added.
function trailTo(hash) {
  const trail = state.trail;
  if (trail.at(-1) === hash) return;
  if (trail.length) state.wandered = true;
  if (trail.at(-2) === hash) trail.pop();
  else trail.push(hash);
  if (trail.length > 50) trail.shift();
}

// The page of the app that linked here, while it is still the way back:
// this page was opened by a link (not reloaded or restored) and nothing on it
// has been left since.
function linkedFrom() {
  if (state.wandered) return "";
  return performance.getEntriesByType?.("navigation")[0]?.type === "navigate" ? document.referrer : "";
}

// A detail's Back button names where it came from and returns there: a view
// on this page, the page that linked here (Exercises, Calendar) or its usual
// parent; the navigation shows that page as current.
const BACK_BUTTONS = { workout: "workout-back", "exercise-history": "exercise-history-back", session: "session-back" };
function aimBack(view) {
  state.back = backFor(view, { cameFrom: state.trail.at(-2) ?? null, referrer: linkedFrom(), origin: location.origin });
  $(BACK_BUTTONS[view]).innerHTML = `${icon("chevron-left")}${escape(state.back.label)}`;
  nav.setCurrent(state.back.page);
}

// Back in the browser's history when that is where the view came from (a
// link from the view on this page, or the page that linked here), so the
// phone's back button doesn't return to the detail; else a link there.
function goBack() {
  const back = state.back;
  const pushed = state.pushedFrom;
  if (back.inPage && pushed?.hash === location.hash && pushed.from === back.href) return history.back();
  // Off this page only when it was opened by a link from that page, so the
  // entry before is that page (on its day, for the calendar).
  if (!back.inPage && history.length > 1) return history.back();
  if (back.inPage) go(back.href);
  else location.assign(back.href);
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
  // A link (or the browser's back and forward) brought this hash.
  state.pushedFrom = { hash: location.hash, from: cameFrom };
  await saveWeights();
  if (view === "workouts") return openWorkouts();
  // "#examples" (Today's set-up, the calendar): Workouts, with the sheet open.
  if (view === "examples") {
    openExamplesSheet();
    return openWorkouts();
  }
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
      state.workoutNote = created ? "Created. Start it here, or find it under Workouts." : "Saved.";
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
// Back straight after skipping a part undoes the skip.
$("prev").onclick = () => state.run.skipping ? undoSkip() : goTo(previousIndex(state.run.items, state.run.index));
$("skip").onclick = onSkip;
$("quit").onclick = quit;
// Tapping a countdown pauses or resumes it; the Pause button beside it does
// the same for a keyboard or a screen reader.
// A screen reader's activation (no pointer: detail 0) only reads it.
$("count-box").onclick = (event) => { if (event.detail > 0 && !event.target.closest("button")) togglePause(); };
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
$("ready-pickup").onclick = (event) => {
  const have = event.target.closest("button[data-have]");
  if (have) {
    return haveGear(have.dataset.have, have, {
      after: () => state.run?.stage === "ready" && showReady(),
      note: (text) => ($("ready-note").textContent = text),
    });
  }
  const swap = event.target.closest("button[data-swap-row]");
  if (swap) swapReadyGear(Number(swap.dataset.swapRow));
};

$("ready-changes").onclick = (event) => {
  const undo = event.target.closest("button[data-undo]");
  if (undo) takeBack(undo.dataset.undo, readyChanges(), undo, reloadReady);
};
$("ready-targets").onclick = (event) => {
  const undo = event.target.closest("button[data-undo]");
  if (undo) return takeBack(undo.dataset.undo, readyChanges(), undo, reloadReady);
  const button = event.target.closest("button");
  if (button?.dataset.weight) stepReadyWeight(Number(button.dataset.target), button.dataset.weight);
};

$("workouts-list").onclick = (event) => {
  if (event.target.closest("button[data-examples]")) return openExamplesSheet();
  const button = event.target.closest("button[data-start]");
  if (button) startWorkout(Number(button.dataset.start));
};
$("from-example").onclick = openExamplesSheet;
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
  if (button) go(routeHash("workout", button.dataset.view));
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
$("workout-actions").onclick = (event) => {
  const button = event.target.closest("button[data-own]");
  if (!button) return;
  // The menu stays open while it works, so the button shows it is busy.
  const menu = button.closest("details");
  onWorkoutOwn(button.dataset.own, button).finally(() => menu?.removeAttribute("open"));
};
// The More menu closes on a tap anywhere else, or Escape.
document.addEventListener("click", (event) => {
  for (const menu of document.querySelectorAll("details.more-actions[open]")) {
    if (!menu.contains(event.target)) menu.removeAttribute("open");
  }
});
document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return;
  const menu = document.querySelector("details.more-actions[open]");
  if (!menu) return;
  menu.removeAttribute("open");
  menu.querySelector("summary").focus();
});
$("workout-blocks").onclick = (event) => {
  const undo = event.target.closest("button[data-undo]");
  if (undo) {
    const id = state.workout?.id;
    return takeBack(undo.dataset.undo, state.workout?.changes, undo, (done) => {
      if (done) state.workoutNote = "Changed back.";
      return openWorkout(id);
    });
  }
  const have = event.target.closest("button[data-have]");
  if (have) {
    return haveGear(have.dataset.have, have, {
      after: () => rereadWorkout(),
      note: (text) => ($("workout-saved").textContent = text),
    });
  }
  const swap = event.target.closest("button[data-swap-step]");
  if (swap) return swapWorkoutStep(swap.dataset.swapStep);
  const button = event.target.closest("button[data-step], button[data-howto]");
  if (!button) return;
  if (button.dataset.howto) return openHowto(workoutStep(button.dataset.howto).exercise);
  const step = workoutStep(button.dataset.step);
  if (button.dataset.weight) changeWorkoutWeight(step, button.dataset.weight);
};

$("changes").onclick = (event) => {
  const id = event.target.closest("button")?.dataset.toggleChange;
  if (!id) return;
  state.run.weights[id].keep = !state.run.weights[id].keep;
  saveRun();
  renderChanges();
};
toggleRpe($("rpe"), (rpe) => {
  state.rpe = rpe;
  renderFeedback();
});
document.querySelectorAll("[data-feedback]").forEach((button) => {
  button.onclick = () => {
    state.feedback = state.feedback === button.dataset.feedback ? null : button.dataset.feedback;
    renderFeedback();
  };
});
$("finish-save").onclick = submitFinish;
$("finish-note").oninput = () => {
  if (!state.run) return;
  state.run.note = $("finish-note").value;
  saveRun();
};
$("home-again").onclick = () => { show("home"); loadToday(); };

$("in-progress").onclick = (event) => {
  const action = event.target.closest("button[data-parked]")?.dataset.parked;
  if (action) onParked(action);
};

$("history-list").onclick = (event) => {
  const button = event.target.closest("button[data-session]");
  if (button) go(routeHash("session", button.dataset.session));
};
$("session-exercises").onclick = $("session-frames").onclick = (event) => {
  const button = event.target.closest("button[data-exercise]");
  if (button) go(routeHash("exercise-history", button.dataset.exercise));
};
$("session-back").onclick = goBack;
$("session-delete").onclick = (event) => deleteSession(event.currentTarget);
$("history-exercises").onclick = (event) => {
  const button = event.target.closest("button[data-exercise]");
  if (button) go(routeHash("exercise-history", button.dataset.exercise));
};
$("exercise-history-back").onclick = goBack;
$("exercise-history-howto").onclick = async () => {
  const id = parseRoute(location.hash).id;
  try {
    openHowto((await getJson(`/api/exercises/${id}`)).data, { controls: true });
  } catch (error) {
    alert(loadProblem("the how-to", error));
  }
};

window.addEventListener("online", sync);
window.addEventListener("popstate", onPopState);
// Another tab queued or sent changes: show the queue as it is now.
window.addEventListener("storage", (event) => { if (event.key === "outbox") renderSync(); });
window.addEventListener("hashchange", route);
// A skip waiting on its undo goes ahead: the page may not come back.
window.addEventListener("pagehide", () => { settleSkip(); saveRun(); saveWeights(); });
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
