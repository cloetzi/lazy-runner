import { createOutbox } from "./outbox.js";
import { pageAccount, syncNote } from "./account.js";
import { mountNav } from "./nav.js";
import { getJson, loadProblem, paths, sendChange, STALE_NOTE, unreachable, offline } from "./api.js";
import { html, icon, authorLine, busy, showSheet } from "./html.js";
import {
  addDays, addMonths, weekOf, monthWeeks, rangeFor, dayName, shortDay, longDay, weekdayDay, weekLabel, monthLabel, localToday, isDate,
  byDay, upNext, markFor, movable, plannable, STATUS_LABELS,
  planRequest, moveRequest, skipSessionRequest, removeRequest, withQueued,
} from "./calendar.js";
import { openPlanSheet, openSessionSheet, openAddSheet, openLogActivitySheet, activityRow, editActivity, noteRow, weekSummaryHtml } from "./calendar-sheets.js";
import { openNoteSheet, aboutChoices } from "./coach-sheets.js";
import { notesByDay, notesAbout, knownCoaches, noteRequest, changeNoteRequest, deleteNoteRequest, plannedBy, agentName } from "./coach.js";
import {
  withQueuedActivities, removedActivityIds, byDay as activitiesByDay, sportIcon, activityTitle, activityKey, preferredDistanceUnit, adoptServerDistanceUnit,
  activityChipLabel,
  logRequest,
} from "./activities.js";
import {
  withActivities, byDay as routineDaysByDay, listed, routineTitle, STATE_LABELS as ROUTINE_LABELS,
  confirmRequest, skipRequest, moveRequest as moveDayRequest, resetRequest, planRequest as planRoutineRequest,
  changeRequest as changeRoutineRequest, endRequest,
} from "./routines.js";
import { routineRow, routineChip, dayKey, openRoutineDaySheet, openRoutineSheet } from "./routine-sheets.js";
import { changeHtml, undoButton, dayChangeLines, undoRequest, sessionChange as agentChange, routineChangeOn, changeShownOn, withoutUndo } from "./plan-changes.js";

// The Calendar page. Phones show one week, Monday to Sunday, days top to
// bottom; tablets and wider also have a month grid with the chosen day under it,
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
// The month is offered from the tablet tier, the same query as the
// shell's rail (44rem wide on a screen 48rem tall, or 60rem wide).
const wide = matchMedia("(min-width: 60rem), (min-width: 44rem) and (min-height: 48rem)");
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
  planChanges: [], // the sessions an agent moved away from a day shown or removed from it
  undoing: false, // an undo is on its way
  upcoming: [], // planned and under way from today on, for what is up next
  board: null, // GET /api/coach: the goals, focus and concerns the week header shows
  stale: false,
  failed: null,
  workouts: null, // what the plan sheet offers, loaded on first use
  load: 0, // the latest load, so an older answer arriving late is dropped
  loaded: null, // the range `sessions` is for, "from..to"
  unfolded: new Set(), // days gone by in this week opened to show in full
  toToday: true, // bring today into view once the week is drawn ("asked": Today was tapped)
  toDay: null, // the day the page was opened on (Coach's This week), brought into view instead
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
    state.planChanges = range.data.plan_changes ?? [];
    // Distances show in the unit the server keeps (set on any device), with
    // this device's copy until it answers.
    if (range.data.distance_unit) adoptServerDistanceUnit(storage, range.data.distance_unit, { queued: outbox.queued(), stale: range.stale });
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
    // In the month only the chosen day's list shows, with its lines.
    changeShown: changeShownOn(listed(routineDays).filter((d) => view() === "week" || d.on === state.focus), routineOf),
    changeDays: dayChangeLines(state.planChanges.map((c) => withoutUndo(c, state.stale)), view() === "month" ? { from: state.focus, to: state.focus } : { from, to }),
    days: byDay(sessions), activityDays: activitiesByDay(activities), noteDays: notesByDay(state.notes, withQueued(state.sessions, queue, state.today)), routineDayMap: routineDaysByDay(listed(routineDays)),
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
    $("calendar-body").innerHTML = state.failed ? "" : html`<p class="muted">Loading…</p>`;
    // An arrow key left the month: the focus waits on the body until the
    // next month is drawn, and the keys still work there. Nothing to wait
    // for once the load failed.
    if (state.gridFocus) {
      if (state.failed) state.gridFocus = false;
      else $("calendar-body").focus({ preventScroll: true });
    }
  } else {
    const data = shown();
    $("calendar-body").innerHTML = current === "month" ? monthView(data) : weekView(data);
    if (state.toToday) bringTodayIntoView();
    // The arrow keys moved the selection; focus follows it.
    if (state.gridFocus) {
      state.gridFocus = false;
      if (current === "month") document.querySelector('.month-date[tabindex="0"]')?.focus();
    }
    if (state.showDay) {
      state.showDay = false;
      if (current === "month") showSelectedDay();
    }
  }
  renderSync();
}

// The week opens on today: the days gone by fold to one line each (a tap
// opens one), and today scrolls up under the bar when the page opens.
// A day with a missed session stays open, so its Do today is at hand.
function weekView({ sessions, activities, routineDays, days, activityDays, noteDays, routineDayMap, fulfils, next, changeDays, changeShown }) {
  const week = weekOf(state.focus);
  const thisWeek = week.includes(state.today);
  const header = html`<section class="card week-summary" aria-label="${thisWeek ? "This week" : weekLabel(state.focus, state.today)}">${weekSummaryHtml({
    week: { sessions, activities, routineDays, routines: state.routines }, board: state.board, unit: distanceUnit(),
    when: thisWeek ? "current" : week[0] > state.today ? "future" : "past",
  })}</section>`;
  return html`${header}<ol class="week-days">${week.map((date) => {
    const parts = [days[date] ?? [], activityDays[date] ?? [], next, { notes: noteDays[date], routineDays: routineDayMap[date], fulfils, changes: changeDays[date], changeShown }];
    const missed = parts[0].some((s) => markFor(s, state.today, next) === "missed");
    const folded = thisWeek && date < state.today && !missed && !state.unfolded.has(date);
    return html`<li>${folded ? foldedDay(date, ...parts) : dayCard(date, ...parts)}</li>`;
  })}</ol>`;
}

// What is on a day, a phrase each ("Session A, done"), as the folded line
// and the month's day label read it.
function dayItems(sessions, activities, next, notes = [], routineDays = [], changes = []) {
  const by = (item) => (item?.created_by === "llm" ? `, by ${agentName(item)}` : "");
  return [
    ...sessions.map((s) => `${s.workout.title}, ${STATUS_LABELS[markFor(s, state.today, next)].toLowerCase()}${by(s)}`),
    ...routineDays.map((d) => `${routineTitle(routineOf(d) ?? {})}, ${ROUTINE_LABELS[d.state].toLowerCase()}${by(routineOf(d))}`),
    ...activities.map(activityTitle),
    ...notes.map((n) => `note: ${n.title ?? n.body}`),
    ...changes.map((c) => c.text),
  ];
}

// A day gone by in one line: "Mon 9 · Session A, done · Easy run, missed".
function foldedDay(date, sessions, activities, next, { notes = [], routineDays = [], changes = [] } = {}) {
  const items = dayItems(sessions, activities, next, [], routineDays, changes);
  if (notes.length) items.push(notes.length === 1 ? "1 note" : `${notes.length} notes`);
  return html`
    <section class="day past folded" data-date="${date}">
      <button class="row folded-day" data-unfold="${date}" aria-expanded="false">
        <span class="folded-date">${weekdayDay(date)}</span>
        <span class="folded-items">${items.length ? items.join(" · ") : "Rest"}</span>
        ${icon("chevron-down")}
      </button>
    </section>`;
}

// Scrolls today's card up to just under the page's bar, once, or the day
// the page was opened on (`#<date>`).
// Not when the page opened and the person has scrolled meanwhile (Today
// asks for it), nor when the day already starts on the first screen.
function bringTodayIntoView() {
  const asked = state.toToday === "asked";
  const date = asked ? null : state.toDay;
  state.toToday = false;
  state.toDay = null;
  const day = document.querySelector(date ? `.week-days .day[data-date="${date}"]` : ".week-days .day.today");
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
function dayCard(date, sessions, activities, next, { heading = "h3", notes = [], routineDays = [], fulfils = new Map(), changes = [], changeShown = new Set() } = {}) {
  const classes = ["day", date === state.today && "today", date < state.today && "past"].filter(Boolean).join(" ");
  const plan = html`<button class="icon-button" data-add="${date}" aria-label="${`${addLabel(date)} on ${longDay(date)}`}">${icon("plus")}</button>`;
  return html`
    <section class="${classes}" data-date="${date}">
      <header class="day-head">
        <${heading} class="day-title"><span>${dayName(date, state.today)}</span> <span class="muted">${shortDay(date)}</span></${heading}>
        ${plan}
      </header>
      ${sessions.length || activities.length || routineDays.length
        ? html`<ul class="list day-sessions">${sessions.map((s) => sessionRow(s, next))}${routineDays.map((d) => routineRow(d, routineOf(d), distanceUnit(), "data-routine-day", state.today, changeShown.has(d) ? routineChange(d) : null))}${activities.map((a) => activityRow(a, distanceUnit(), "data-activity", fulfils.get(String(activityKey(a)))))}${notes.map((n) => noteRow(n, "data-note"))}</ul>`
        : html`${notes.length ? html`<ul class="list day-sessions">${notes.map((n) => noteRow(n, "data-note"))}</ul>` : ""}<p class="rest muted">Rest</p>`}
      ${changes.length ? html`<ul class="day-changes">${changes.map(dayChangeRow)}</ul>` : ""}
    </section>`;
}

// A session an agent moved away from the day or removed from it, in one
// muted line, with Put it back while it can be.
function dayChangeRow(line) {
  return html`
    <li>
      <span>${line.text}</span>
      ${line.undo ? undoButton(line.undo, undefined, { classes: "quiet small" }) : ""}
      ${line.reason ? html`<span class="change-reason">${line.reason}</span>` : ""}
    </li>`;
}

// The latest change an agent made to a day's routine or to a session, with
// no undo on a copy kept on the device.
const routineChange = (day) => withoutUndo(routineChangeOn(day, routineOf(day)), state.stale);
const sessionChange = (session) => withoutUndo(agentChange(session), state.stale);

const keyOf = (session) => session.id != null ? String(session.id) : session.client_ref;

function sessionRow(session, next) {
  const mark = markFor(session, state.today, next);
  const change = sessionChange(session);
  const meta = [STATUS_LABELS[mark], session.workout.estimated_minutes && `${session.workout.estimated_minutes} min`, session.pending && "not synced yet"]
    .filter(Boolean).join(" · ");
  const drag = movable(session) ? html` draggable="true"` : "";
  return html`
    <li class="cal-row${mark === "next" ? " is-next" : ""}" data-key="${keyOf(session)}"${drag}>
      <button class="row" data-open="${keyOf(session)}">
        ${sessionTile(session, mark)}
        <span class="row-text">
          <span class="row-title${mark === "skipped" || mark === "missed" ? " struck" : ""}">${session.workout.title}</span>
          <span class="row-meta">${meta}</span>
          ${session.note ? html`<span class="row-note">${session.note}</span>` : ""}
          ${changeHtml(change, { today: state.today, unit: distanceUnit() }) ?? authorLine(plannedBy(session, state.today))}
        </span>
      </button>
      ${mark === "missed" ? html`<button class="secondary small" data-do-today="${keyOf(session)}">Do today</button>` : ""}
      ${undoButton(change, session.workout.title)}
    </li>`;
}

const distanceUnit = () => preferredDistanceUnit(storage);

// A session's tile: the workouts icon in the session's state, as a routine
// day's tile is drawn (CM7). `size` is "" in a day's list, "chip-tile" in the month.
function sessionTile(session, mark, size = "") {
  const agent = size && session.created_by === "llm";
  return html`<span class="sport-tile ${mark}${size ? ` ${size}` : ""}" aria-hidden="true">${icon("workouts")}${agent ? html`<span class="tile-agent"></span>` : ""}</span>`;
}

const chip = (tile, label, { gone = false, key = null, drag = false } = {}) =>
  html`<li class="chip"${key ? html` data-key="${key}"` : ""}${drag ? html` draggable="true"` : ""}>${tile}<span class="chip-label${gone ? " struck" : ""}">${label}</span></li>`;

const MAX_CHIPS = 3;

// The month grid at the full width, the selected day under it.
// Each chip is a tile and what and how much; a cell too narrow for words
// shows the tiles alone (a container query in app.css). The grid is one tab
// stop: the arrow keys move the selected day, and the whole cell is
// its button.
function monthView({ days, activityDays, noteDays, routineDayMap, fulfils, next, changeDays, changeShown }) {
  const month = state.focus.slice(0, 7);
  const head = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((d) => html`<span class="month-weekday" role="columnheader">${d}</span>`);
  const weeks = monthWeeks(state.focus).map((week) => html`<div class="month-week" role="row">${week.map((date) => {
    const sessions = days[date] ?? [];
    const activities = activityDays[date] ?? [];
    const notes = noteDays[date] ?? [];
    const routineDays = routineDayMap[date] ?? [];
    const classes = ["month-day", date.slice(0, 7) !== month && "outside", date === state.today && "today",
      date === state.focus && "selected", date < state.today && "past"].filter(Boolean).join(" ");
    const items = dayItems(sessions, activities, next, notes, routineDays, changeDays[date]);
    const label = `${longDay(date)}: ${items.length ? items.join("; ") : "rest"}`;
    const chips = [
      ...sessions.map((s) => {
        const mark = markFor(s, state.today, next);
        return chip(sessionTile(s, mark, "chip-tile"), s.workout.title, { gone: mark === "skipped" || mark === "missed", key: keyOf(s), drag: movable(s) });
      }),
      ...routineDays.map((d) => routineChip(d, routineOf(d))),
      ...activities.map((a) => chip(html`<span class="sport-tile done chip-tile" aria-hidden="true">${icon(sportIcon(a.sport))}</span>`, activityChipLabel(a, distanceUnit()))),
      ...(notes.length ? [chip(html`<span class="note-tile chip-tile" aria-hidden="true">${icon("coach")}</span>`, notes.length === 1 ? "Note" : `${notes.length} notes`)] : []),
    ];
    const shown = chips.length > MAX_CHIPS + 1 ? [...chips.slice(0, MAX_CHIPS), html`<li class="chip more-chip"><span class="chip-label">+${chips.length - MAX_CHIPS} more</span></li>`] : chips;
    return html`
      <div class="${classes}" role="gridcell" aria-selected="${date === state.focus}" data-date="${date}">
        <button class="month-date" data-select="${date}" tabindex="${date === state.focus ? 0 : -1}" aria-label="${label}">${Number(date.slice(8))}</button>
        <ul class="chips" aria-hidden="true">${shown}</ul>
      </div>`;
  })}</div>`);
  return html`
    <div class="month">
      <div class="month-grid" role="grid" aria-label="${monthLabel(state.focus)}" aria-describedby="month-keys">
        <div class="month-week" role="row">${head}</div>${weeks}
      </div>
      <p class="visually-hidden" id="month-keys">Arrow keys move a day or a week, Home and End to the start or end of the week, Page Up and Page Down a month.</p>
      <section class="card day-panel" aria-label="${longDay(state.focus)}">${dayCard(state.focus, days[state.focus] ?? [], activityDays[state.focus] ?? [], next, { heading: "h2", notes: noteDays[state.focus], routineDays: routineDayMap[state.focus], fulfils, changes: changeDays[state.focus], changeShown })}</section>
    </div>`;
}

// After a tap on a day, the day under the grid comes into view when it is
// below the fold: its heading and first rows at the foot of the screen.
function showSelectedDay() {
  const panel = document.querySelector(".day-panel");
  if (!panel) return;
  const box = panel.getBoundingClientRect();
  const wanted = Math.min(box.height, innerHeight * 0.45);
  if (box.top + wanted <= innerHeight) return;
  scrollBy({ top: box.top + wanted - innerHeight + 16, behavior: "instant" });
}

// The key, one sheet for the week and the month (C6): what each mark means.
function openKeySheet() {
  const dialog = document.getElementById("key-sheet") ??
    document.body.appendChild(Object.assign(document.createElement("dialog"), { id: "key-sheet", className: "sheet calendar-sheet" }));
  const tile = (classes, glyph) => html`<span class="sport-tile ${classes}" aria-hidden="true">${icon(glyph)}</span>`;
  const row = (mark, term, text) => html`<li>${mark}<span><strong>${term}</strong><span class="muted">${text}</span></span></li>`;
  dialog.innerHTML = html`
    <form method="dialog" class="howto">
      <header>
        <h2>What the marks mean</h2>
        <button class="icon-button" value="close" aria-label="Close">${icon("close")}</button>
      </header>
      <h3>What it is</h3>
      <ul class="key-list">
        ${row(tile("done", "workouts"), "Strength session", "A workout from your programs")}
        ${row(tile("done", "sport-run"), "Run, ride, hike and more", "Each sport has its icon")}
        ${row(html`<span class="note-tile" aria-hidden="true">${icon("coach")}</span>`, "Note", "From you or your coach")}
      </ul>
      <h3>Where it stands</h3>
      <ul class="key-list">
        ${row(tile("tentative", "sport-run"), "Maybe", "Dashed, not decided yet")}
        ${row(tile("planned", "workouts"), "Planned", "Outlined, on the plan")}
        ${row(tile("next", "workouts"), "Up next", "Filled orange, the next workout")}
        ${row(tile("done", "workouts"), "Done", "Filled in")}
        ${row(tile("skipped", "workouts"), "Skipped or missed", "Faded and struck through")}
      </ul>
      <h3>Also</h3>
      <ul class="key-list">
        ${row(html`<span class="sport-tile planned" aria-hidden="true">${icon("sport-run")}<span class="tile-agent"></span></span>`, "Your coach agent planned it", "A dot in the month; the day names the agent")}
        ${row(html`<span class="key-today" aria-hidden="true">14</span>`, "Today", "The date in orange")}
      </ul>
      <p class="muted">A done run says what and how far: Run 9.4 km. Where a day is too narrow for words, the month shows the marks alone; the day under the grid names them.</p>
    </form>`;
  dialog.returnValue = "";
  showSheet(dialog);
}

function renderSync() {
  const pending = outbox.pending();
  $("sync").hidden = pending === 0;
  $("sync").innerHTML = syncNote(pending, outbox.waiting(), location);
  const rejected = outbox.rejected();
  $("sync-rejected").hidden = rejected.length === 0;
  if (rejected.length === 0) return;
  const reasons = [...new Set(rejected.map((r) => r.error))];
  $("sync-rejected").innerHTML = html`
    <p>${rejected.length} ${rejected.length === 1 ? "change" : "changes"} could not be saved: ${reasons.join("; ")}</p>
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
    onReply: (fields) => sendNote(noteRequest(fields)),
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

// Takes an agent's change back, now (not queued: it answers whether it
// could). Either way the calendar is read again, so a change that could no
// longer be taken back (the agent changed it again meanwhile) shows as it is.
async function undo(change) {
  // One at a time: a second tap while the first is on its way would only
  // hear that it was taken back already.
  if (!change || state.undoing) return;
  state.undoing = true;
  try {
    const problem = await sendChange(undoRequest(change, state.today));
    if (!problem || !offline()) await load();
    if (problem) alert(problem);
  } finally {
    state.undoing = false;
  }
}

// A data-undo button, busy while its change is taken back.
async function undoFrom(button) {
  busy(button);
  try {
    await undo(changeById(button.dataset.undo));
  } finally {
    if (button.isConnected) busy(button, false);
  }
}

// The change behind a data-undo button: on a session, a routine or a day's line.
function changeById(id) {
  const items = [...state.sessions, ...state.routines].map((item) => item.change);
  return [...items, ...state.planChanges].find((change) => change && String(change.id) === id);
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
  const change = routineChange(day);
  openRoutineDaySheet({
    day, routine, unit: distanceUnit(), today: state.today, change,
    on: {
      onConfirm: () => tell(confirmRequest(day, state.today)),
      onReset: () => tell(resetRequest(day, state.today)),
      onSkip: () => tell(skipRequest(day, state.today)),
      onMove: (date) => tell(moveDayRequest(day, date, state.today)),
      onLog: () => logActivity(day.on, { sport: routine.sport, about: `for ${routineTitle(routine)}` }),
      onEdit: () => planRoutine({ date: day.on, routine }),
      onRemove: () => tell(endRequest(routine, state.today)),
      onUndo: () => undo(change),
    },
  });
}

function openActivity(key) {
  const activity = shown().activities.find((a) => activityKey(a) === key);
  if (!activity) return;
  editActivity({ activity, unit: distanceUnit(), today: state.today, send, notes: notesAbout(state.notes, "activity", activity.id) });
}

function open(key) {
  const session = find(key);
  if (!session) return;
  openSessionSheet({
    session, today: state.today, notes: notesAbout(state.notes, "session", session.id), change: sessionChange(session),
    on: {
      onMove: (date) => (date === state.today && session.status === "missed" ? doToday(key) : move(key, date)),
      onSkip: () => send(skipSessionRequest(session)),
      onRemove: () => send(removeRequest(session)),
      onUndo: () => undo(sessionChange(session)),
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

$("calendar-key").onclick = openKeySheet;

// One tab stop for the month grid, arrow keys inside it: they move
// the selected day, and the focus follows it.
const KEY_MOVES = {
  ArrowLeft: (d) => addDays(d, -1), ArrowRight: (d) => addDays(d, 1),
  ArrowUp: (d) => addDays(d, -7), ArrowDown: (d) => addDays(d, 7),
  Home: (d) => weekOf(d)[0], End: (d) => weekOf(d)[6],
  PageUp: (d) => addMonths(d, -1), PageDown: (d) => addMonths(d, 1),
};
$("calendar-body").addEventListener("keydown", (event) => {
  const step = KEY_MOVES[event.key];
  const inGrid = event.target.closest(".month-grid") || (event.target.id === "calendar-body" && state.gridFocus);
  if (!step || !inGrid || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
  event.preventDefault();
  state.gridFocus = true;
  goTo(step(state.focus));
});

$("calendar-body").addEventListener("click", (event) => {
  const target = event.target.closest("[data-add], [data-open], [data-activity], [data-routine-day], [data-note], [data-do-today], [data-undo], [data-unfold], [data-select], .month-day");
  if (!target) return;
  if (target.dataset.undo) return undoFrom(target);
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
  if (date) {
    state.showDay = true;
    goTo(date);
  }
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

// Opened on a day (Coach's This week links here): that day, unfolded if it
// has gone by this week, and brought into view.
const asked = location.hash.slice(1);
if (isDate(asked) && asked !== localToday()) {
  if (asked < localToday()) state.unfolded.add(asked);
  state.toDay = asked;
}
goTo(isDate(asked) ? asked : localToday(), { reload: false });
load();
sync();
