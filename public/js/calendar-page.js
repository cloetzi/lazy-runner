import { createOutbox } from "./outbox.js";
import { pageAccount, syncNote } from "./account.js";
import { mountNav } from "./nav.js";
import { getJson, loadProblem, paths, sendChange, STALE_NOTE, unreachable } from "./api.js";
import { escape, icon, authorLine } from "./html.js";
import {
  addDays, addMonths, weekOf, monthWeeks, rangeFor, dayName, shortDay, longDay, weekdayDay, weekLabel, monthLabel, localToday, isDate,
  byDay, upNext, markFor, movable, plannable, STATUS_LABELS,
  planRequest, moveRequest, skipSessionRequest, removeRequest, withQueued,
} from "./calendar.js";
import { openPlanSheet, openSessionSheet, openAddSheet, openLogActivitySheet, activityRow, editActivity, noteRow, weekSummaryHtml } from "./calendar-sheets.js";
import { openNoteSheet, aboutChoices } from "./coach-sheets.js";
import { notesByDay, knownCoaches, noteRequest, changeNoteRequest, deleteNoteRequest, plannedBy, agentName } from "./coach.js";
import {
  withQueuedActivities, removedActivityIds, byDay as activitiesByDay, sportIcon, activityTitle, activityKey, preferredDistanceUnit, adoptServerDistanceUnit,
  logRequest,
} from "./activities.js";
import {
  withActivities, byDay as routineDaysByDay, listed, routineTitle, STATE_LABELS as ROUTINE_LABELS,
  confirmRequest, skipRequest, moveRequest as moveDayRequest, resetRequest, planRequest as planRoutineRequest,
  changeRequest as changeRoutineRequest, endRequest,
} from "./routines.js";
import { routineRow, routineChip, dayKey, openRoutineDaySheet, openRoutineSheet } from "./routine-sheets.js";

// The Calendar page. Phones show one week, Monday to Sunday, days top to
// bottom; wide screens also have a month grid with the chosen day beside it,
// where a planned session can be dragged to another day. Activities (runs,
// rides, anything done) show beside the sessions, each with its sport's icon,
// and the coach's notes dated to a day under them. Routine days (a run on
// Wednesdays, a maybe-hike on Saturday) show dashed while tentative and
// outlined once confirmed; a logged activity ticks one off. Every change but
// a note or a routine goes through the outbox, and what it still holds is
// shown on top of the server's answer, so a change made offline shows at
// once. Notes and routines are sent straight away, as on the Coach page.

const VIEW_KEY = "calendarView";
// Set once the calendar has shown anything to this account: the page's
// how-to line goes.
const usedKey = () => `calendarUsed:${pageAccount(storage).id}`;
const wide = matchMedia("(min-width: 60rem)");
const $ = (id) => document.getElementById(id);
const storage = (() => {
  try {
    return localStorage;
  } catch {
    const items = new Map();
    return { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v), removeItem: (k) => items.delete(k) };
  }
})();
const outbox = createOutbox({ storage, fetch: (...args) => fetch(...args), locks: navigator.locks, user: pageAccount(storage).id });
mountNav("calendar");

const state = {
  today: localToday(),
  focus: null, // the day the shown week or month is about, and the month's selected day
  chosenView: storage.getItem(VIEW_KEY) === "week" ? "week" : "month", // on wide screens
  sessions: [], // the shown range, as the server last gave it
  activities: [], // the shown range's activities, as the server last gave them
  notes: [], // the shown range's coach notes
  routines: [], // the routines with days in the shown range
  routineDays: [], // their days, as the server read them on state.today
  upcoming: [], // planned and under way from today on, for what is up next
  board: null, // GET /api/coach: the goals, focus and concerns the week header shows
  stale: false,
  failed: null,
  workouts: null, // what the plan sheet offers, loaded on first use
  load: 0, // the latest load, so an older answer arriving late is dropped
  loaded: null, // the range `sessions` is for, "from..to"
  unfolded: new Set(), // days gone by in this week opened to show in full
  toToday: true, // bring today into view once the week is drawn ("asked": Today was tapped)
};

const rangeKey = () => { const { from, to } = rangeFor(view(), state.focus); return `${from}..${to}`; };

const view = () => (wide.matches ? state.chosenView : "week");

// ---------- Loading ----------

async function load() {
  const ticket = ++state.load;
  const { from, to } = rangeFor(view(), state.focus);
  try {
    const [range, upcoming, board] = await Promise.all([
      getJson(paths.calendar({ from, to, today: state.today })),
      // Offline with no copy (a new day), the range still shows.
      getJson(paths.upcoming(state.today)).catch((error) => {
        if (!unreachable(error)) throw error;
        return { data: state.upcoming, stale: true };
      }),
      loadBoard(from, to),
    ]);
    if (ticket !== state.load) return;
    state.loaded = `${from}..${to}`;
    state.board = board;
    state.sessions = range.data.sessions;
    state.activities = range.data.activities;
    state.notes = range.data.notes ?? [];
    state.routines = range.data.routines ?? [];
    state.routineDays = range.data.routine_days ?? [];
    state.upcoming = upcoming.data;
    state.stale = range.stale || upcoming.stale;
    if ([state.sessions, state.activities, state.notes, state.routineDays, state.upcoming].some((list) => list.length)) {
      try {
        storage.setItem(usedKey(), "1");
      } catch {
        // Storage full or refused: the line just stays.
      }
    }
    state.failed = null;
  } catch (error) {
    if (ticket !== state.load) return;
    state.failed = loadProblem("this part of the calendar", error);
  }
  render();
}

// The coach's side of the week header (goals, focus and concerns), read
// only for the week holding today, the one that shows it. Without it
// (offline, not cached) the header shows the counts only.
async function loadBoard(from, to) {
  if (view() !== "week" || state.today < from || state.today > to) return state.board;
  try {
    return (await getJson(paths.coach(state.today))).data;
  } catch {
    return state.board;
  }
}

// Distances show in the unit the server keeps (set on any device), with
// this device's copy until it answers.
async function loadDistanceUnit() {
  try {
    const { data, stale } = await getJson(paths.settings);
    const before = preferredDistanceUnit(storage);
    if (adoptServerDistanceUnit(storage, data.distance_unit, { queued: outbox.queued(), stale }) !== before) render();
  } catch {
    // Offline: this device's copy shows.
  }
}

// Sends what is queued; once the server has taken it all, the calendar is
// read again so it shows the server's own numbering and ids.
async function sync() {
  const before = outbox.pending();
  await outbox.flush();
  renderSync();
  // Whatever went out is the server's now: read it back, or it would drop
  // off the overlay and the old copy would show.
  if (outbox.pending() < before) await load();
  else render();
}

// ---------- Drawing ----------

function shown() {
  const queue = outbox.queued();
  const { from, to } = rangeFor(view(), state.focus);
  const sessions = withQueued(state.sessions, queue, state.today).filter((s) => s.date >= from && s.date <= to);
  // What is up next may lie outside the range shown, or inside it.
  const known = new Map([...state.upcoming, ...state.sessions].map((s) => [s.id, s]));
  const next = upNext(withQueued([...known.values()], queue, state.today), state.today);
  const activities = withQueuedActivities(state.activities, queue).filter((a) => a.date >= from && a.date <= to);
  const routineDays = withActivities(state.routineDays, state.routines, activities, state.today, removedActivityIds(queue)).filter((d) => d.on >= from && d.on <= to);
  // The routine each activity ticked off, by the activity's key.
  const fulfils = new Map(routineDays.filter((d) => d.state === "done").map((d) => [String(d.activity_key ?? d.activity_id), routineTitle(routineOf(d))]));
  return {
    sessions, activities, next, routineDays, fulfils,
    days: byDay(sessions), activityDays: activitiesByDay(activities), noteDays: notesByDay(state.notes), routineDayMap: routineDaysByDay(listed(routineDays)),
  };
}

const routineOf = (day) => state.routines.find((r) => r.id === day.routine_id);

function render() {
  state.today = localToday();
  const current = view();
  document.body.classList.toggle("calendar-month", current === "month");
  for (const button of $("calendar-switch").querySelectorAll("[data-value]")) {
    button.setAttribute("aria-pressed", String(button.dataset.value === current));
  }
  const step = current === "month" ? "month" : "week";
  $("calendar-prev").setAttribute("aria-label", `Previous ${step}`);
  $("calendar-next").setAttribute("aria-label", `Next ${step}`);
  $("calendar-range").textContent = current === "month" ? monthLabel(state.focus) : weekLabel(state.focus, state.today);

  const notes = [];
  if (state.failed) notes.push(state.failed);
  else if (state.stale) notes.push(STALE_NOTE);
  $("calendar-note").textContent = notes.join(" ");
  $("calendar-note").hidden = notes.length === 0;
  // The how-to line is for an empty calendar; once there is anything, the title says enough.
  document.querySelector(".calendar .tagline").hidden = storage.getItem(usedKey()) === "1";

  // A range not loaded yet shows nothing rather than a week of Rest.
  if (state.loaded !== rangeKey()) {
    $("calendar-body").innerHTML = state.failed ? "" : `<p class="muted">Loading…</p>`;
  } else {
    const data = shown();
    $("calendar-body").innerHTML = current === "month" ? monthView(data) : weekView(data);
    if (state.toToday) bringTodayIntoView();
  }
  renderSync();
}

// The week opens on today: the days gone by fold to one line each (a tap
// opens one), and today scrolls up under the bar when the page opens.
// A day with a missed session stays open, so its Do today is at hand.
function weekView({ sessions, activities, routineDays, days, activityDays, noteDays, routineDayMap, fulfils, next }) {
  const week = weekOf(state.focus);
  const thisWeek = week.includes(state.today);
  const header = `<section class="card week-summary" aria-label="${escape(thisWeek ? "This week" : weekLabel(state.focus, state.today))}">${weekSummaryHtml({
    week: { sessions, activities, routineDays, routines: state.routines }, board: state.board, unit: distanceUnit(),
    when: thisWeek ? "current" : week[0] > state.today ? "future" : "past",
  })}</section>`;
  return `${header}<ol class="week-days">${week.map((date) => {
    const parts = [days[date] ?? [], activityDays[date] ?? [], next, { notes: noteDays[date], routineDays: routineDayMap[date], fulfils }];
    const missed = parts[0].some((s) => markFor(s, state.today, next) === "missed");
    const folded = thisWeek && date < state.today && !missed && !state.unfolded.has(date);
    return `<li>${folded ? foldedDay(date, ...parts) : dayCard(date, ...parts)}</li>`;
  }).join("")}</ol>`;
}

// What is on a day, a phrase each ("Session A, done"), as the folded line
// and the month's day label read it.
function dayItems(sessions, activities, next, notes = [], routineDays = []) {
  const by = (item) => (item?.created_by === "llm" ? `, by ${agentName(item)}` : "");
  return [
    ...sessions.map((s) => `${s.workout.title}, ${STATUS_LABELS[markFor(s, state.today, next)].toLowerCase()}${by(s)}`),
    ...routineDays.map((d) => `${routineTitle(routineOf(d) ?? {})}, ${ROUTINE_LABELS[d.state].toLowerCase()}${by(routineOf(d))}`),
    ...activities.map(activityTitle),
    ...notes.map((n) => `note: ${n.title ?? n.body}`),
  ];
}

// A day gone by in one line: "Mon 9 · Session A, done · Easy run, missed".
function foldedDay(date, sessions, activities, next, { notes = [], routineDays = [] } = {}) {
  const items = dayItems(sessions, activities, next, [], routineDays);
  if (notes.length) items.push(notes.length === 1 ? "1 note" : `${notes.length} notes`);
  return `
    <section class="day past folded" data-date="${date}">
      <button class="row folded-day" data-unfold="${date}" aria-expanded="false">
        <span class="folded-date">${escape(weekdayDay(date))}</span>
        <span class="folded-items">${escape(items.length ? items.join(" · ") : "Rest")}</span>
        ${icon("chevron-down")}
      </button>
    </section>`;
}

// Scrolls today's card up to just under the page's bar, once.
// Not when the page opened and the person has scrolled meanwhile (Today
// asks for it), nor when today already starts on the first screen.
function bringTodayIntoView() {
  const asked = state.toToday === "asked";
  state.toToday = false;
  const day = document.querySelector(".week-days .day.today");
  if (!day || (!asked && scrollY > 8)) return;
  const box = day.getBoundingClientRect();
  if (box.top >= 0 && box.top < innerHeight * 0.6) return;
  const bar = Math.max(document.querySelector(".topbar")?.getBoundingClientRect().bottom ?? 0, 0);
  scrollTo({ top: box.top + scrollY - bar - 8, behavior: "instant" });
}

// What the day's plus adds: a workout from today on, an activity up to today, or a note.
const addLabel = (date) => (date > state.today ? "Plan a workout, run or routine, or write a note" : date < state.today ? "Log an activity or write a note" : "Add a workout, run, routine, activity or note");

// One day: its name, a plus to plan a workout (from today on), log an
// activity (up to today) or write a note, its sessions in order, then its
// activities and notes, or Rest.
function dayCard(date, sessions, activities, next, { heading = "h3", notes = [], routineDays = [], fulfils = new Map() } = {}) {
  const classes = ["day", date === state.today && "today", date < state.today && "past"].filter(Boolean).join(" ");
  const plan = `<button class="icon-button" data-add="${date}" aria-label="${escape(`${addLabel(date)} on ${longDay(date)}`)}">${icon("plus")}</button>`;
  return `
    <section class="${classes}" data-date="${date}">
      <header class="day-head">
        <${heading} class="day-title"><span>${escape(dayName(date, state.today))}</span> <span class="muted">${escape(shortDay(date))}</span></${heading}>
        ${plan}
      </header>
      ${sessions.length || activities.length || routineDays.length
        ? `<ul class="list day-sessions">${sessions.map((s) => sessionRow(s, next)).join("")}${routineDays.map((d) => routineRow(d, routineOf(d), distanceUnit(), "data-routine-day", state.today)).join("")}${activities.map((a) => activityRow(a, distanceUnit(), "data-activity", fulfils.get(String(activityKey(a))))).join("")}${notes.map((n) => noteRow(n, "data-note")).join("")}</ul>`
        : `${notes.length ? `<ul class="list day-sessions">${notes.map((n) => noteRow(n, "data-note")).join("")}</ul>` : ""}<p class="rest muted">Rest</p>`}
    </section>`;
}

const keyOf = (session) => session.id != null ? String(session.id) : session.client_ref;

function sessionRow(session, next) {
  const mark = markFor(session, state.today, next);
  const meta = [STATUS_LABELS[mark], session.workout.estimated_minutes && `${session.workout.estimated_minutes} min`, session.pending && "not synced yet"]
    .filter(Boolean).map(escape).join(" · ");
  const drag = movable(session) ? ` draggable="true"` : "";
  return `
    <li class="cal-row${mark === "next" ? " is-next" : ""}" data-key="${escape(keyOf(session))}"${drag}>
      <button class="row" data-open="${escape(keyOf(session))}">
        <span class="mark ${mark}" aria-hidden="true"></span>
        <span class="row-text">
          <span class="row-title${mark === "skipped" ? " struck" : ""}">${escape(session.workout.title)}</span>
          <span class="row-meta">${meta}</span>
          ${session.note ? `<span class="row-note">${escape(session.note)}</span>` : ""}
          ${authorLine(plannedBy(session, state.today))}
        </span>
      </button>
      ${mark === "missed" ? `<button class="secondary small" data-do-today="${escape(keyOf(session))}">Do today</button>` : ""}
    </li>`;
}

const distanceUnit = () => preferredDistanceUnit(storage);

// The month grid, with the selected day's sessions beside it.
function monthView({ days, activityDays, noteDays, routineDayMap, fulfils, next }) {
  const month = state.focus.slice(0, 7);
  const head = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((d) => `<span class="month-weekday" aria-hidden="true">${d}</span>`).join("");
  const cells = monthWeeks(state.focus).flat().map((date) => {
    const sessions = days[date] ?? [];
    const activities = activityDays[date] ?? [];
    const notes = noteDays[date] ?? [];
    const routineDays = routineDayMap[date] ?? [];
    const classes = ["month-day", date.slice(0, 7) !== month && "outside", date === state.today && "today",
      date === state.focus && "selected", date < state.today && "past"].filter(Boolean).join(" ");
    const items = dayItems(sessions, activities, next, notes, routineDays);
    const label = `${longDay(date)}: ${items.length ? items.join("; ") : "rest"}`;
    return `
      <div class="${classes}" data-date="${date}">
        <button class="month-date" data-select="${date}" aria-label="${escape(label)}" aria-pressed="${date === state.focus}">${Number(date.slice(8))}</button>
        <ul class="chips">${sessions.map((s) => {
          const mark = markFor(s, state.today, next);
          return `<li class="chip${mark === "skipped" ? " struck" : ""}${s.created_by === "llm" ? " by-agent" : ""}" data-key="${escape(keyOf(s))}"${movable(s) ? ` draggable="true"` : ""}><span class="mark ${mark}" aria-hidden="true"></span>${escape(s.workout.title)}</li>`;
        }).join("")}${routineDays.map((d) => routineChip(d, routineOf(d))).join("")}${activities.map((a) => `<li class="chip activity-chip"><span class="sport-tile tiny" aria-hidden="true">${icon(sportIcon(a.sport))}</span>${escape(activityTitle(a))}</li>`).join("")}${notes.length ? `<li class="chip note-chip">${notes.length === 1 ? "1 note" : `${notes.length} notes`}</li>` : ""}</ul>
      </div>`;
  }).join("");
  return `
    <div class="month">
      <div class="month-grid">${head}${cells}</div>
      <aside class="card day-panel" aria-label="${escape(longDay(state.focus))}">${dayCard(state.focus, days[state.focus] ?? [], activityDays[state.focus] ?? [], next, { heading: "h2", notes: noteDays[state.focus], routineDays: routineDayMap[state.focus], fulfils })}</aside>
    </div>`;
}

function renderSync() {
  const pending = outbox.pending();
  $("sync").hidden = pending === 0;
  $("sync").innerHTML = syncNote(pending, outbox.waiting(), location);
  const rejected = outbox.rejected();
  $("sync-rejected").hidden = rejected.length === 0;
  if (rejected.length === 0) return;
  const reasons = [...new Set(rejected.map((r) => r.error))];
  $("sync-rejected").innerHTML = `
    <p>${rejected.length} ${rejected.length === 1 ? "change" : "changes"} could not be saved: ${escape(reasons.join("; "))}</p>
    <button class="secondary small" data-dismiss-rejected>Dismiss</button>`;
}

// ---------- Changes ----------

function send(entry) {
  outbox.enqueue(entry);
  render();
  sync();
}

const find = (key) => shown().sessions.find((s) => keyOf(s) === key);

function move(key, date) {
  const session = find(key);
  if (!session || !movable(session) || !plannable(date, state.today) || date === session.date) return false;
  send(moveRequest(session, date));
  return true;
}

// Do today moves a missed session to today, then opens Today to start it,
// once the server has it (until then Today could not show it).
async function doToday(key) {
  if (!move(key, state.today)) return;
  if (await outbox.flush()) location.href = "/#today";
}

// The main workouts a session or a workout routine can run, loaded once.
async function loadWorkouts({ quiet = false } = {}) {
  if (state.workouts) return state.workouts;
  try {
    const { data: programs } = await getJson(paths.workouts);
    state.workouts = programs.flatMap((program) => program.workouts).filter((w) => w.kind === "workout" && !w.archived);
  } catch (error) {
    if (!quiet) alert(loadProblem("the workouts", error, { hint: false }));
  }
  return state.workouts;
}

async function plan(date) {
  if (!(await loadWorkouts())) return;
  openPlanSheet({
    date, workouts: state.workouts,
    onPlan: (workout, note) => send(planRequest({ workout, date, note, id: uniqueId() })),
  });
}

// The day's plus: a workout on a day from today on, an activity on a day up
// to today, or a note on any day.
function add(date) {
  openAddSheet({
    date,
    onWorkout: date >= state.today ? () => plan(date) : null,
    onOnce: date >= state.today ? () => planRoutine({ date, once: true }) : null,
    onRoutine: date >= state.today ? () => planRoutine({ date }) : null,
    onActivity: date <= state.today ? () => logActivity(date) : null,
    onNote: () => writeNote(date),
  });
}

// Sends a note change now (notes don't go through the outbox), then reads
// the calendar again. Resolves to the problem to show, or nothing.
async function sendNote(request) {
  const problem = await sendChange(request);
  if (!problem) await load();
  return problem;
}

// Writes a note dated `date`, or edits `note`: about one of that day's
// sessions or activities, if any.
function writeNote(date, note = null) {
  const day = note?.date ?? date;
  const { sessions, activities } = shown();
  openNoteSheet({
    note, date: day,
    about: aboutChoices({ sessions: sessions.filter((s) => s.date === day), activities: activities.filter((a) => a.date === day), label: activityTitle }),
    coaches: knownCoaches(state.notes),
    onSave: (fields) => sendNote(note ? changeNoteRequest(note, fields) : noteRequest(fields)),
    onDelete: () => sendNote(deleteNoteRequest(note)),
  });
}

function logActivity(date, { sport = "", about = "" } = {}) {
  openLogActivitySheet({
    date, unit: distanceUnit(), sport, about,
    onLog: (fields) => send(logRequest({ ...fields, id: uniqueId(), today: state.today })),
  });
}

// ---------- Routines ----------

// Sends a routine change now (routines don't go through the outbox), then
// reads the calendar again. Resolves to the problem to show, or nothing.
async function sendRoutine(request) {
  const problem = await sendChange(request);
  if (!problem) await load();
  return problem;
}

const tell = async (request) => {
  const problem = await sendRoutine(request);
  if (problem) alert(problem);
};

// Plans a run, a ride or a workout on `date` (Maybe or Planned, when
// `once`), or every week from it; or changes `routine`.
async function planRoutine({ date, once = false, routine = null }) {
  // Offline, only sports are offered: a workout routine needs the list.
  const workouts = await loadWorkouts({ quiet: true });
  openRoutineSheet({
    routine, date, once, unit: distanceUnit(), today: state.today, workouts,
    onSave: (fields, { confirmed }) => sendRoutine(routine ? changeRoutineRequest(routine, fields, state.today) : planRoutineRequest(fields, state.today, confirmed)),
    onEnd: routine ? () => tell(endRequest(routine, state.today)) : null,
  });
}

function openRoutineDay(key) {
  const day = shown().routineDays.find((d) => dayKey(d) === key);
  const routine = day && routineOf(day);
  if (!routine) return;
  openRoutineDaySheet({
    day, routine, unit: distanceUnit(), today: state.today,
    on: {
      onConfirm: () => tell(confirmRequest(day, state.today)),
      onReset: () => tell(resetRequest(day, state.today)),
      onSkip: () => tell(skipRequest(day, state.today)),
      onMove: (date) => tell(moveDayRequest(day, date, state.today)),
      onLog: () => logActivity(day.on, { sport: routine.sport, about: `for ${routineTitle(routine)}` }),
      onEdit: () => planRoutine({ date: day.on, routine }),
      onRemove: () => tell(endRequest(routine, state.today)),
    },
  });
}

function openActivity(key) {
  const activity = shown().activities.find((a) => activityKey(a) === key);
  if (!activity) return;
  editActivity({ activity, unit: distanceUnit(), today: state.today, send });
}

function open(key) {
  const session = find(key);
  if (!session) return;
  openSessionSheet({
    session, today: state.today,
    on: {
      onMove: (date) => (date === state.today && session.status === "missed" ? doToday(key) : move(key, date)),
      onSkip: () => send(skipSessionRequest(session)),
      onRemove: () => send(removeRequest(session)),
    },
  });
}

function uniqueId() {
  return crypto.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

// ---------- Moving around ----------

// The hash names the day shown, so a reload comes back to it.
function goTo(date, { reload = true } = {}) {
  const before = state.focus && rangeFor(view(), state.focus);
  state.focus = date;
  history.replaceState(null, "", `#${date}`);
  const after = rangeFor(view(), date);
  if (reload && (!before || before.from !== after.from || before.to !== after.to)) {
    render();
    load();
  } else {
    render();
  }
}

function shift(direction) {
  // A month opens on its 1st, or on today in this month.
  if (view() === "month") {
    const month = addMonths(`${state.focus.slice(0, 7)}-01`, direction);
    return goTo(month.slice(0, 7) === state.today.slice(0, 7) ? state.today : month);
  }
  goTo(addDays(state.focus, 7 * direction));
}

// ---------- Wiring ----------

$("calendar-prev").onclick = () => shift(-1);
$("calendar-next").onclick = () => shift(1);
$("calendar-today").onclick = () => {
  state.toToday = "asked";
  goTo(localToday());
};
$("calendar-switch").onclick = (event) => {
  const value = event.target.closest("[data-value]")?.dataset.value;
  if (!value || value === state.chosenView) return;
  state.chosenView = value;
  storage.setItem(VIEW_KEY, value);
  render();
  load();
};

$("calendar-body").addEventListener("click", (event) => {
  const target = event.target.closest("[data-add], [data-open], [data-activity], [data-routine-day], [data-note], [data-do-today], [data-unfold], [data-select], .month-day");
  if (!target) return;
  if (target.dataset.unfold) {
    state.unfolded.add(target.dataset.unfold);
    render();
    // Focus stays on the day just opened: its first entry, else its plus.
    const day = document.querySelector(`.day[data-date="${target.dataset.unfold}"]`);
    return (day?.querySelector(".day-sessions button") ?? day?.querySelector("[data-add]"))?.focus();
  }
  if (target.dataset.add) return add(target.dataset.add);
  if (target.dataset.routineDay) return openRoutineDay(target.dataset.routineDay);
  if (target.dataset.note) return writeNote(null, state.notes.find((n) => String(n.id) === target.dataset.note));
  if (target.dataset.open) return open(target.dataset.open);
  if (target.dataset.activity) return openActivity(target.dataset.activity);
  if (target.dataset.doToday) return doToday(target.dataset.doToday);
  // A tap anywhere on a day of the month picks it.
  const date = target.dataset.select ?? target.dataset.date;
  if (date) goTo(date);
});

// Dragging a planned session onto another day from today on moves it there.
let dragging = null;
const dropDay = (event) => {
  const day = event.target.closest("[data-date]");
  return day && dragging && plannable(day.dataset.date, state.today) ? day : null;
};
const clearDrop = () => document.querySelectorAll(".drop-target").forEach((el) => el.classList.remove("drop-target"));
$("calendar-body").addEventListener("dragstart", (event) => {
  const item = event.target.closest?.("[data-key][draggable]");
  if (!item) return;
  dragging = item.dataset.key;
  event.dataTransfer.effectAllowed = "move";
  event.dataTransfer.setData("text/plain", dragging);
  item.classList.add("dragging");
});
$("calendar-body").addEventListener("dragover", (event) => {
  const day = dropDay(event);
  if (!day) return;
  event.preventDefault();
  event.dataTransfer.dropEffect = "move";
  if (!day.classList.contains("drop-target")) {
    clearDrop();
    day.classList.add("drop-target");
  }
});
$("calendar-body").addEventListener("dragleave", (event) => {
  if (!event.relatedTarget || !event.currentTarget.contains(event.relatedTarget)) clearDrop();
});
$("calendar-body").addEventListener("drop", (event) => {
  const day = dropDay(event);
  if (!day) return;
  event.preventDefault();
  const key = dragging;
  dragging = null;
  clearDrop();
  move(key, day.dataset.date);
});
$("calendar-body").addEventListener("dragend", () => {
  dragging = null;
  clearDrop();
  document.querySelectorAll(".dragging").forEach((el) => el.classList.remove("dragging"));
});

$("sync-rejected").onclick = (event) => {
  if (!event.target.closest("[data-dismiss-rejected]")) return;
  outbox.dismissRejected();
  renderSync();
};

wide.addEventListener("change", () => {
  render();
  load();
});
window.addEventListener("hashchange", () => {
  const date = location.hash.slice(1);
  if (isDate(date) && date !== state.focus) goTo(date);
});
window.addEventListener("online", sync);
// Another tab queued or sent changes: show the calendar as it is now.
window.addEventListener("storage", (event) => {
  if (event.key !== "outbox") return;
  render();
  load();
});
// Back after a while (the app left open overnight): today may have moved on.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") sync();
});

const asked = location.hash.slice(1);
goTo(isDate(asked) ? asked : localToday(), { reload: false });
load();
sync();
loadDistanceUnit();
