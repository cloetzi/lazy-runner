import { html, icon, authorLine, showSheet } from "./html.js";
import { longDay, weekdayDay, dayName, moveChoices, movable, shownStatus, STATUS_LABELS } from "./calendar.js";
import {
  KNOWN_SPORTS, sportIcon, sportLabel, activityTitle, activityFacts, activityKey, formatDistance, formatClimb, formatDuration,
  distanceInMetres, climbInMetres, durationInSeconds, changeRequest, deleteRequest, activityOrigin, sourceLabel,
} from "./activities.js";
import { RPE_ANCHORS } from "./player.js";
import { rpePicker, toggleRpe, pickedRpe } from "./rpe-picker.js";
import { routeHash } from "./routes.js";
import { KIND_LABELS, authorLabel, plannedBy, writtenOn, howItFelt } from "./coach.js";
import { weekSummary, summaryLine, watching } from "./week.js";
import { changeHtml, undoButton } from "./plan-changes.js";

// The calendar's sheets, used by the Calendar page and by Today: planning a
// workout on a day, a session's own sheet to move, skip or remove it, and
// logging an activity, an activity's own sheet, Today's question of how
// hard one was, and the day's plus. Notes have their own sheet
// (coach-sheets.js).
// Each is a dialog built on demand, like the swap picker. They only ask; the
// caller sends the change.

function sheet(id) {
  return document.getElementById(id) ??
    document.body.appendChild(Object.assign(document.createElement("dialog"), { id, className: "sheet calendar-sheet" }));
}

// Every workout you can plan (`workouts`, main workouts), with an optional
// note. `onPlan(workout, note)` is called with the choice.
export function openPlanSheet({ date, workouts, onPlan }) {
  const dialog = sheet("plan-sheet");
  const chosen = workouts.find((w) => w.up_next) ?? workouts[0];
  dialog.innerHTML = html`
    <form method="dialog" class="howto">
      <header>
        <h2>Plan a workout</h2>
        <button class="icon-button" value="close" formnovalidate aria-label="Close">${icon("close")}</button>
      </header>
      <p class="muted">${longDay(date)}. It goes last on the day.</p>
      ${workouts.length ? html`<fieldset class="list plan-workouts">
        <legend class="visually-hidden">Workout</legend>
        ${workouts.map((w) => html`
          <label class="row">
            <input type="radio" name="workout" value="${w.id}"${w === chosen ? " checked" : ""} required>
            <span class="row-text">
              <span class="row-title">${w.title}${w.up_next ? html` <span class="badge">Up next</span>` : ""}</span>
              <span class="row-meta">${[`${w.estimated_minutes} min`, w.subtitle].filter(Boolean).join(" · ")}</span>
            </span>
          </label>`)}
      </fieldset>
      <label class="field"><span>Note <span class="muted">(optional)</span></span>
        <textarea name="note" rows="2" maxlength="500" placeholder="Why this day, such as easy legs before the long run"></textarea>
      </label>
      <button class="primary" value="plan">Plan</button>` : html`
      <p>Get a workout first: import an example program, or build one of your own.</p>
      <div class="card-actions">
        <a class="button primary small" href="/#examples">From an example</a>
        <a class="button secondary small" href="${routeHash("edit", "new")}">Build a workout</a>
      </div>`}
    </form>`;
  const form = dialog.querySelector("form");
  dialog.onclose = () => {
    if (dialog.returnValue !== "plan") return;
    const workout = workouts.find((w) => String(w.id) === form.elements.workout?.value);
    if (workout) onPlan(workout, form.elements.note.value);
  };
  dialog.returnValue = "";
  showSheet(dialog);
}

// The notes about a session or activity, newest first, each with who wrote
// it and when: where the coach's reading meets what was planned and done.
function notesList(notes) {
  if (!notes.length) return "";
  return html`
    <h3>Notes</h3>
    <ul class="sheet-notes">${notes.map((n) => html`
      <li>
        ${n.title ? html`<p><strong>${n.title}</strong></p>` : ""}
        <p>${n.body}</p>
        <p class="muted small-print">${`${authorLabel(n)} · ${writtenOn(n)}`}</p>
        ${n.replies?.length ? html`<ul class="sheet-replies" aria-label="Replies">${n.replies.map((r) => html`
          <li><p>${r.body}</p><p class="muted small-print">${`${authorLabel(r)} · ${writtenOn(r)}`}</p></li>`)}</ul>` : ""}
      </li>`)}</ul>`;
}

// A session's sheet. A planned or missed one can move to a day of its week
// (or this week's, once its day is gone), or Later to any date from today on;
// it can be skipped or taken off the calendar. Any session opens its workout,
// and a finished one its log; a done one opens with how it felt. `notes` are
// the notes about it (notesAbout in coach.js). `change` is the latest change
// an agent made to it, shown with its reason and, while it can be, the
// button that takes it back (onUndo). `on` holds onMove(date), onSkip(),
// onRemove() and onUndo().
export function openSessionSheet({ session, today, on, notes = [], change = null }) {
  const dialog = sheet("session-sheet");
  const status = shownStatus(session, today);
  const can = movable(session);
  const minutes = session.workout.estimated_minutes;
  const facts = [longDay(session.date), STATUS_LABELS[status], minutes && `${minutes} min`].filter(Boolean);
  const choices = can ? moveChoices(session, today) : [];
  const logged = session.id != null && ["done", "in_progress", "skipped"].includes(status);
  // A done session opens with how it felt, and the remark made on finishing.
  const felt = status === "done" ? howItFelt(session.completion) : "";
  const remark = status === "done" ? session.completion?.note : "";
  dialog.innerHTML = html`
    <form method="dialog" class="howto session-sheet" novalidate>
      <header>
        <h2>${session.workout.title}</h2>
        <button class="icon-button" value="close" aria-label="Close">${icon("close")}</button>
      </header>
      <p class="muted">${facts.join(" · ")}</p>
      ${felt ? html`<p class="session-felt"><strong>${felt}</strong></p>` : ""}
      ${remark ? html`<p class="session-remark">${remark}</p>` : ""}
      ${session.note ? html`<p class="planner-note">${session.note}</p>` : ""}
      ${changeHtml(change, { today, tag: "p" }) ?? authorLine(plannedBy(session, today), "p")}
      ${on.onUndo ? undoButton(change, session.workout.title, { sheet: true }) : ""}
      ${notesList(notes)}
      ${status === "missed" ? html`<button class="primary" value="today">Do today</button>` : ""}
      ${can ? html`
        <h3 id="move-label">Move to</h3>
        <div class="move-days" role="group" aria-labelledby="move-label">
          ${choices.map((c) => html`<button class="secondary small" value="move:${c.date}"${c.disabled ? " disabled" : ""}${c.date === session.date ? html` aria-current="date"` : ""}>${weekdayDay(c.date)}</button>`)}
          <button class="secondary small" type="button" data-later aria-expanded="false">Later</button>
        </div>
        <div class="move-later" hidden>
          <label class="field">Date <input type="date" name="later" min="${today}"></label>
          <button class="secondary small" type="button" data-move-later>Move</button>
        </div>` : ""}
      <div class="sheet-actions">
        <a class="button secondary small" href="/#workout/${session.workout.id}">Open workout</a>
        ${logged ? html`<a class="button secondary small" href="/#session/${session.id}">See the log</a>` : ""}
        ${can ? html`<button class="secondary small" value="skip">Skip</button>` : ""}
      </div>
      ${can ? html`<div class="danger-zone"><button class="quiet small danger" value="remove">Remove from the calendar</button></div>` : ""}
    </form>`;

  const later = dialog.querySelector(".move-later");
  dialog.querySelector("[data-later]")?.addEventListener("click", (event) => {
    later.hidden = !later.hidden;
    event.currentTarget.setAttribute("aria-expanded", String(!later.hidden));
    if (!later.hidden) later.querySelector("input").focus();
  });
  dialog.querySelector("[data-move-later]")?.addEventListener("click", () => {
    const input = later.querySelector("input");
    if (!input.value || input.value < today) {
      input.setCustomValidity("Pick a day from today on.");
      input.reportValidity();
      return;
    }
    dialog.close(`move:${input.value}`);
  });
  later?.querySelector("input").addEventListener("input", (event) => event.target.setCustomValidity(""));

  dialog.onclose = () => {
    const answer = dialog.returnValue;
    if (answer.startsWith("move:")) on.onMove(answer.slice(5));
    if (answer === "today") on.onMove(today);
    if (answer === "skip") on.onSkip();
    if (answer === "remove") on.onRemove();
    if (answer === "undo") on.onUndo();
  };
  dialog.returnValue = "";
  showSheet(dialog);
}

// ---------- Activities ----------

// An activity in a day's list, on the Calendar and on Today: a filled tile
// with its sport's icon, its title and numbers. `attribute` names the data
// attribute a tap is looked up by, holding the activity's key.
// `fulfils` names the routine day it ticked off, if any.
export function activityRow(activity, unit, attribute, fulfils = null) {
  const meta = [fulfils && `✓ ${fulfils}`, ...activityFacts(activity, unit), activity.pending && "not synced yet"].filter(Boolean).join(" · ");
  return html`
    <li class="cal-row activity-row">
      <button class="row" ${attribute}="${activityKey(activity)}">
        <span class="sport-tile" aria-hidden="true">${icon(sportIcon(activity.sport))}</span>
        <span class="row-text">
          <span class="row-title">${activityTitle(activity)}</span>
          ${meta ? html`<span class="row-meta">${meta}</span>` : ""}
        </span>
      </button>
    </li>`;
}

// Opens an activity's sheet, sending what is changed there with `send`
// (which queues it in the outbox). `today` is the device's.
export function editActivity({ activity, unit, today, send, notes = [] }) {
  openActivitySheet({
    activity, unit, today, notes,
    on: {
      onRpe: (rpe) => send(changeRequest(activity, { rpe }, today)),
      onNote: (note) => { if (note !== (activity.note ?? "")) send(changeRequest(activity, { note: note || null }, today)); },
      onDelete: () => send(deleteRequest(activity)),
    },
  });
}

// What the day's plus adds: a workout to do (from today on), a run or other
// sport planned for the day (Maybe or Planned) or every week, an activity
// done (up to today), or a coach's note. `on` holds onWorkout, onOnce,
// onRoutine, onActivity and onNote; a choice without its handler is left out.
export function openAddSheet({ date, onWorkout, onOnce, onRoutine, onActivity, onNote }) {
  const dialog = sheet("add-sheet");
  const choices = [
    onWorkout && html`<button class="secondary add-choice" value="workout">${icon("workouts")}<span><strong>Workout</strong><span class="muted">Plan one of your workouts</span></span></button>`,
    onOnce && html`<button class="secondary add-choice" value="once">${icon("sport-run")}<span><strong>Run or other sport</strong><span class="muted">Maybe, or planned, on this day</span></span></button>`,
    onRoutine && html`<button class="secondary add-choice" value="routine">${icon("calendar")}<span><strong>Routine</strong><span class="muted">Every week, such as a run on Wednesdays</span></span></button>`,
    onActivity && html`<button class="secondary add-choice" value="activity">${icon("sport-activity")}<span><strong>Activity</strong><span class="muted">Log a run, ride or anything you did</span></span></button>`,
    onNote && html`<button class="secondary add-choice" value="note">${icon("coach")}<span><strong>Note</strong><span class="muted">How it went, what to watch, for you and your coach</span></span></button>`,
  ].filter(Boolean);
  dialog.innerHTML = html`
    <form method="dialog" class="howto">
      <header>
        <h2>Add to ${longDay(date)}</h2>
        <button class="icon-button" value="close" aria-label="Close">${icon("close")}</button>
      </header>
      <div class="add-choices">${choices}</div>
    </form>`;
  dialog.onclose = () => {
    if (dialog.returnValue === "workout") onWorkout();
    if (dialog.returnValue === "once") onOnce();
    if (dialog.returnValue === "routine") onRoutine();
    if (dialog.returnValue === "activity") onActivity();
    if (dialog.returnValue === "note") onNote();
  };
  dialog.returnValue = "";
  showSheet(dialog);
}

// A coach's note under a calendar day: its kind or title, and who wrote it.
// `attribute` names the data attribute a tap is looked up by, holding its id.
export function noteRow(note, attribute) {
  const title = note.title ?? (note.kind === "note" ? "Note" : KIND_LABELS[note.kind]);
  return html`
    <li class="cal-row note-row">
      <button class="row" ${attribute}="${note.id}">
        <span class="note-tile" aria-hidden="true">${icon("coach")}</span>
        <span class="row-text">
          <span class="row-title">${title}</span>
          <span class="row-meta">${`${authorLabel(note)}: ${note.body}`}</span>
          ${(note.replies ?? []).map((r) => html`<span class="row-reply">${`${authorLabel(r)}: ${r.body}`}</span>`)}
        </span>
      </button>
    </li>`;
}

// Logs an activity done on `date`: the sport (free text, the known ones
// suggested; `sport` fills it in), and whatever numbers the person has.
// `onLog(fields)` gets them in metres and seconds, blanks left out. `about`
// says what it is for, such as the routine day it ticks off.
export function openLogActivitySheet({ date, unit, onLog, sport = "", about = "" }) {
  const dialog = sheet("activity-log-sheet");
  const climbUnit = unit === "mi" ? "ft" : "m";
  dialog.innerHTML = html`
    <form method="dialog" class="howto activity-form" novalidate>
      <header>
        <h2>Log an activity</h2>
        <button class="icon-button" type="button" data-close aria-label="Close">${icon("close")}</button>
      </header>
      <p class="muted">${[longDay(date), about].filter(Boolean).join(" · ")}</p>
      <label class="field"><span>Sport</span>
        <input name="sport" list="activity-sports" maxlength="40" autocomplete="off" required placeholder="Run, ride, hike…" value="${sport ? sportLabel(sport) : ""}">
        <datalist id="activity-sports">${KNOWN_SPORTS.map((s) => html`<option value="${sportLabel(s)}">`)}</datalist>
      </label>
      <label class="field"><span>Title <span class="muted">(optional)</span></span>
        <input name="title" maxlength="200" placeholder="Lunch loop">
      </label>
      <div class="activity-numbers">
        <label class="field"><span>Time</span><input name="time" placeholder="45" aria-describedby="activity-time-hint"></label>
        <label class="field"><span>Distance</span><span class="with-unit"><input name="distance" inputmode="decimal" placeholder="0"><span class="muted">${unit}</span></span></label>
        <label class="field"><span>Climb</span><span class="with-unit"><input name="climb" inputmode="numeric" placeholder="0"><span class="muted">${climbUnit}</span></span></label>
      </div>
      <p class="muted small-print" id="activity-time-hint">Time in minutes, or as a watch shows it: 25:13 or 1:05:30.</p>
      <fieldset class="field"><legend>How hard <span class="muted">(optional)</span></legend>${rpePicker()}</fieldset>
      <label class="field"><span>Note <span class="muted">(optional)</span></span>
        <textarea name="note" rows="2" maxlength="2000"></textarea>
      </label>
      <p class="form-error" role="alert" hidden></p>
      <button class="primary" value="log">Log it</button>
    </form>`;
  const form = dialog.querySelector("form");
  const error = form.querySelector(".form-error");
  // How hard: picked here, read when it is logged.
  toggleRpe(form.querySelector(".rpe"));
  // Not a submit button, so Enter in a field logs rather than closes.
  form.querySelector("[data-close]").addEventListener("click", () => dialog.close("close"));
  const read = () => {
    const { sport, title, time, distance, climb, note } = form.elements;
    const fields = {
      date, sport: sport.value.trim(), title: title.value.trim(), note: note.value.trim(),
      moving_seconds: durationInSeconds(time.value),
      distance_m: distanceInMetres(distance.value, unit),
      climb_m: climbInMetres(climb.value, unit),
      rpe: pickedRpe(form.querySelector(".rpe")),
    };
    const problems = [
      !fields.sport && "Say what you did, such as run.",
      Number.isNaN(fields.moving_seconds) && "Give the time in minutes, or as 25:13 or 1:05:30.",
      Number.isNaN(fields.distance_m) && `Give the distance as a number of ${unit}.`,
      Number.isNaN(fields.climb_m) && `Give the climb as a number of ${climbUnit}.`,
    ].filter(Boolean);
    return { fields, problems };
  };
  // Checked before the sheet closes, so a slip can be fixed in place.
  form.querySelector('button[value="log"]').addEventListener("click", (event) => {
    const { problems } = read();
    if (problems.length === 0) return;
    event.preventDefault();
    error.textContent = problems.join(" ");
    error.hidden = false;
  });
  dialog.onclose = () => {
    if (dialog.returnValue !== "log") return;
    const { fields, problems } = read();
    if (problems.length === 0) onLog(fields);
  };
  dialog.returnValue = "";
  showSheet(dialog);
  (sport ? form.elements.time : form.elements.sport).focus();
}

// An activity's sheet: its numbers as they were sent, how hard it was, a
// note, the notes about it, and Delete. `on` holds onRpe(rpe or null),
// onNote(text) and onDelete().
export function openActivitySheet({ activity, unit, today, on, notes = [] }) {
  const dialog = sheet("activity-sheet");
  const facts = [
    ["Distance", formatDistance(activity.distance_m, unit)],
    ["Moving time", formatDuration(activity.moving_seconds)],
    ["Elapsed time", formatDuration(activity.elapsed_seconds)],
    ["Climb", activity.climb_m == null ? "" : formatClimb(activity.climb_m, unit)],
    ["Avg heart rate", activity.avg_hr == null ? "" : `${activity.avg_hr} bpm`],
    ["Max heart rate", activity.max_hr == null ? "" : `${activity.max_hr} bpm`],
    ["Started", activity.started_at ? new Date(activity.started_at).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" }) : ""],
  ].filter(([, value]) => value);
  // One not on the server yet is yours; one with a change queued still says where it came from.
  const origin = activity.id == null ? "" : activityOrigin(activity, today);
  const offScale = activity.rpe != null && !RPE_ANCHORS.some((a) => a.rpe === activity.rpe);
  dialog.innerHTML = html`
    <form method="dialog" class="howto activity-sheet" novalidate>
      <header>
        <h2><span class="sport-tile" aria-hidden="true">${icon(sportIcon(activity.sport))}</span> ${activityTitle(activity)}</h2>
        <button class="icon-button" value="close" aria-label="Close">${icon("close")}</button>
      </header>
      <p class="muted">${[longDay(activity.date), activity.title ? sportLabel(activity.sport) : "", activity.pending ? "not synced yet" : ""].filter(Boolean).join(" · ")}</p>
      ${facts.length ? html`<dl class="activity-facts">${facts.map(([name, value]) => html`<div><dt>${name}</dt><dd>${value}</dd></div>`)}</dl>`
        : html`<p class="muted">No numbers were sent with it.</p>`}
      ${activity.created_by === "llm" ? authorLine(origin, "p") : origin ? html`<p class="muted small-print">${origin}</p>` : ""}
      <h3>How hard was it?${offScale ? html` <span class="muted">RPE ${activity.rpe}</span>` : ""}</h3>
      ${rpePicker({ rpe: activity.rpe })}
      <label class="field"><span>Note</span>
        <textarea name="note" rows="2" maxlength="2000">${activity.note ?? ""}</textarea>
      </label>
      <div class="sheet-actions">
        <button class="secondary small" value="note">Save note</button>
      </div>
      ${notesList(notes)}
      <div class="danger-zone"><button class="quiet small danger" value="delete">Delete the activity</button></div>
    </form>`;
  const form = dialog.querySelector("form");
  // A tap on the picked one takes it back.
  toggleRpe(form.querySelector(".rpe"), (rpe) => on.onRpe(rpe));
  dialog.onclose = () => {
    const answer = dialog.returnValue;
    if (answer === "note") on.onNote(form.elements.note.value.trim());
    if (answer === "delete" && confirm(activity.source
      ? `Delete ${activityTitle(activity)}? It comes back if ${sourceLabel(activity.source)} sends it again.`
      : `Delete ${activityTitle(activity)}?`)) on.onDelete();
  };
  dialog.returnValue = "";
  showSheet(dialog);
}

// Today's question about an activity sent from elsewhere: how hard was it?
// `onRpe(rpe)` gets the answer; Not now leaves it.
export function openRpeSheet({ activity, unit, onRpe, today = activity.date }) {
  const dialog = sheet("rpe-sheet");
  // One from a day before says which ("Yesterday", "Friday").
  const facts = [activity.date !== today && dayName(activity.date, today), ...activityFacts(activity, unit)].filter(Boolean);
  dialog.innerHTML = html`
    <form method="dialog" class="howto">
      <header>
        <h2>How hard was it?</h2>
        <button class="icon-button" value="close" aria-label="Close">${icon("close")}</button>
      </header>
      <p class="rpe-about"><span class="sport-tile small" aria-hidden="true">${icon(sportIcon(activity.sport))}</span>
        <span><strong>${activityTitle(activity)}</strong>${facts.length ? html`<br><span class="muted">${facts.join(" · ")}</span>` : ""}</span></p>
      ${rpePicker({ answer: true })}
      <button class="quiet small" value="close">Not now</button>
      <p class="muted">You can turn this question off in <a href="/settings.html#training">Settings</a>.</p>
    </form>`;
  dialog.onclose = () => {
    const answer = dialog.returnValue;
    if (answer.startsWith("rpe:")) onRpe(Number(answer.slice(4)));
  };
  dialog.returnValue = "";
  showSheet(dialog);
}

// How the week adds up, on Today and over the Calendar's week: planned
// against done by kind with the distance covered, then, for the current
// week, the top goal, the coach's focus and what it is watching, with a
// link to Coach. `week` holds the week's sessions, activities, routines and
// routine days; `board` is GET /api/coach (or null, not loaded).
export function weekSummaryHtml({ week, board = null, unit, when = "current", heading = "" }) {
  const current = when === "current";
  const lines = weekSummary(week).map((entry) => summaryLine(entry, unit));
  const goal = current ? board?.goals?.[0] : null;
  const focus = current ? board?.focus : null;
  const concerns = current ? watching(board?.concerns) : [];
  return html`
    ${heading}
    ${lines.length ? html`<ul class="week-kinds">${lines.map((l) => html`<li><strong>${l.count}</strong> ${l.label}${l.facts.length ? html`<span class="muted"> · ${l.facts.join(" · ")}</span>` : ""}</li>`)}</ul>`
      : html`<p class="muted">${{ current: "Nothing planned this week yet.", past: "Nothing that week.", future: "Nothing planned yet." }[when]}</p>`}
    ${goal ? html`<p class="week-goal muted">Goal: ${goal.title}</p>` : ""}
    ${focus ? html`<p class="week-focus"><strong>Focus</strong> <span class="muted">· ${authorLabel(focus)}</span><br>${focus.body}</p>` : ""}
    ${concerns.map((c) => html`<p class="week-watching">${icon("info")}<span>Watching: ${c}</span></p>`)}
    ${current && board ? html`<a class="link" href="/coach.html">Open Coach</a>` : ""}`;
}
