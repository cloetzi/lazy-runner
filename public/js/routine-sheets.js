import { escape, icon, authorLine } from "./html.js";
import { longDay, weekdayDay, weekOf } from "./calendar.js";
import { KNOWN_SPORTS, sportIcon, sportLabel, formatDistance } from "./activities.js";
import { plannedBy } from "./coach.js";
import {
  WEEKDAY_SHORT, EFFORTS, STATE_LABELS, isoWeekday, routineTitle, routineFacts, moveChoices, readRoutine,
} from "./routines.js";

// The routine sheets, used by the Calendar page and by Today: a day of a
// routine in a day's list, its sheet (I'm going, Log it now, Not this week
// or Skip, Move to, Edit the routine, or Remove for a one-off), and the
// sheet that plans or changes a
// routine. Each is a dialog built on demand; they only ask, and the caller
// sends the change.

function sheet(id) {
  return document.getElementById(id) ??
    document.body.appendChild(Object.assign(document.createElement("dialog"), { id, className: "sheet calendar-sheet" }));
}

// The tile a routine shows: its sport's icon (or the workouts icon), drawn
// dashed while tentative and outlined in the accent once confirmed.
function tile(routine, state, size = "") {
  const glyph = routine?.sport ? sportIcon(routine.sport) : "workouts";
  return `<span class="sport-tile routine-tile ${state}${size ? ` ${size}` : ""}" aria-hidden="true">${icon(glyph)}</span>`;
}

// A day of a routine in a day's list. `attribute` names the data attribute a
// tap is looked up by, holding "<routine id>:<date>". `today` is the page's.
export function routineRow(day, routine, unit, attribute, today) {
  const meta = [STATE_LABELS[day.state], ...(routine ? routineFacts(routine, unit).slice(1) : []), day.moved && `moved from ${weekdayDay(day.date)}`]
    .filter(Boolean).map(escape).join(" · ");
  return `
    <li class="cal-row routine-row ${day.state}">
      <button class="row" ${attribute}="${escape(dayKey(day))}">
        ${tile(routine, day.state)}
        <span class="row-text">
          <span class="row-title${day.state === "skipped" ? " struck" : ""}">${escape(routine ? routineTitle(routine) : "Routine")}</span>
          <span class="row-meta">${meta}</span>
          ${routine?.note ? `<span class="row-note">${escape(routine.note)}</span>` : ""}
          ${authorLine(plannedBy(routine, today))}
        </span>
      </button>
    </li>`;
}

// A day of a routine in the month grid, with a dot when someone else planned it.
export function routineChip(day, routine) {
  return `<li class="chip routine-chip ${day.state}${day.state === "skipped" ? " struck" : ""}${routine?.created_by === "llm" ? " by-agent" : ""}">${tile(routine, day.state, "tiny")}${escape(routine ? routineTitle(routine) : "Routine")}</li>`;
}

export const dayKey = (day) => `${day.routine_id}:${day.date}`;

// A day's sheet. A tentative day can be confirmed (I'm going), a confirmed
// one made tentative again; a sport routine's day up to today can be logged
// now, linked to it; an open day can be skipped or moved within its week (or
// Later), a skipped one planned again. A weekly routine's day is skipped
// "Not this week"; a one-off's is skipped, or taken off the calendar
// (onRemove) while its day is still to come. `on` holds onConfirm, onReset,
// onLog, onSkip, onMove(date), onEdit and onRemove; one left out is not offered.
export function openRoutineDaySheet({ day, routine, unit, today, on }) {
  const dialog = sheet("routine-day-sheet");
  const open = ["tentative", "confirmed", "missed"].includes(day.state);
  const facts = [longDay(day.on), STATE_LABELS[day.state], day.moved && `moved from ${longDay(day.date)}`].filter(Boolean);
  const choices = open ? moveChoices(day, today, weekOf) : [];
  const canLog = routine.sport && open && day.on <= today;
  const oneOff = routine.weekdays.length === 0;
  // Only a one-off still wholly ahead is deleted; one whose own day has gone
  // by would only be stopped (Routine#end!).
  const canRemove = oneOff && on.onRemove && day.date >= today && day.on >= today && day.state !== "done";
  dialog.innerHTML = `
    <form method="dialog" class="howto routine-day-sheet" novalidate>
      <header>
        <h2>${tile(routine, day.state, "small")} ${escape(routineTitle(routine))}</h2>
        <button class="icon-button" value="close" aria-label="Close">${icon("close")}</button>
      </header>
      <p class="muted">${facts.map(escape).join(" · ")}</p>
      <p>${escape(routineFacts(routine, unit).join(" · "))}</p>
      ${routine.note ? `<p class="planner-note">${escape(routine.note)}</p>` : ""}
      ${authorLine(plannedBy(routine, today), "p")}
      <div class="sheet-actions">
        ${day.state === "tentative" ? `<button class="primary" value="confirm">I'm going</button>` : ""}
        ${canLog ? `<button class="${day.state === "tentative" ? "secondary" : "primary"}" value="log">Log it now</button>` : ""}
        ${day.state === "confirmed" ? `<button class="secondary" value="reset">Maybe after all</button>` : ""}
        ${open ? `<button class="secondary" value="skip">${oneOff ? "Skip" : "Not this week"}</button>` : ""}
        ${day.state === "skipped" && day.on >= today ? `<button class="secondary" value="reset">Plan it again</button>` : ""}
      </div>
      ${open && day.on >= today ? `
        <h3 id="routine-move-label">Move to</h3>
        <div class="move-days" role="group" aria-labelledby="routine-move-label">
          ${choices.map((c) => `<button class="secondary small" value="move:${c.date}"${c.disabled ? " disabled" : ""}${c.date === day.on ? ` aria-current="date"` : ""}>${escape(weekdayDay(c.date))}</button>`).join("")}
          <button class="secondary small" type="button" data-later aria-expanded="false">Later</button>
        </div>
        <div class="move-later" hidden>
          <label>Date <input type="date" name="later" min="${today}"></label>
          <button class="secondary small" type="button" data-move-later>Move</button>
        </div>` : ""}
      <div class="sheet-actions">
        ${routine.workout ? `<a class="button secondary small" href="/#workout/${routine.workout.id}">Open workout</a>` : ""}
        ${on.onEdit ? `<button class="secondary small" value="edit">${oneOff ? "Edit" : "Edit the routine"}</button>` : ""}
      </div>
      ${canRemove ? `<button class="link danger" value="remove">Remove from the calendar</button>` : ""}
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
    if (answer === "confirm") on.onConfirm();
    if (answer === "reset") on.onReset();
    if (answer === "log") on.onLog();
    if (answer === "skip") on.onSkip();
    if (answer === "edit") on.onEdit();
    if (answer === "remove" && confirm(`Remove ${routineTitle(routine)} from the calendar?`)) on.onRemove();
    if (answer.startsWith("move:")) on.onMove(answer.slice(5));
  };
  dialog.returnValue = "";
  dialog.showModal();
}

// Plans a routine, or changes `routine`. A new one starts on `date`: weekly
// on its weekday unless `once`, where Maybe or Planned (confirmed) is asked.
// `workouts` are the main workouts a workout routine can run (null: not
// loaded, so only sports are offered). `onSave(fields, { confirmed })`
// sends it and resolves to a problem to show, or nothing; `onEnd()` stops a
// routine being changed.
export function openRoutineSheet({ routine = null, date, once = false, unit, today, workouts, onSave, onEnd }) {
  const dialog = sheet("routine-sheet");
  const editing = routine != null;
  const oneOff = editing ? routine.weekdays.length === 0 : once;
  const weekdays = editing ? routine.weekdays : [isoWeekday(date)];
  const what = routine?.workout ? "workout" : "sport";
  const startsOn = editing ? (routine.starts_on < today ? today : routine.starts_on) : date;
  const distance = routine?.distance_m ? formatDistance(routine.distance_m, unit).split(" ")[0] : "";
  // The sport as kept, capitalised: sportLabel would read "e-bike" as "E bike",
  // and sending that back would count as a change of sport.
  const sport = routine?.sport ? routine.sport[0].toUpperCase() + routine.sport.slice(1) : "";
  // The routine's own workout stays a choice, archived or a warm-up as it may be.
  const choices = routine?.workout && workouts && !workouts.some((w) => w.id === routine.workout.id) ? [routine.workout, ...workouts] : workouts;
  const heading = editing ? "Edit the routine" : oneOff ? "Plan a day" : "Plan a routine";
  dialog.innerHTML = `
    <form method="dialog" class="howto routine-form" novalidate>
      <header>
        <h2>${escape(heading)}</h2>
        <button class="icon-button" type="button" data-close aria-label="Close">${icon("close")}</button>
      </header>
      ${choices?.length ? `
        <div class="segmented kind-choices" role="radiogroup" aria-label="What">
          <label><input type="radio" name="what" value="sport"${what === "sport" ? " checked" : ""}><span>Run or other sport</span></label>
          <label><input type="radio" name="what" value="workout"${what === "workout" ? " checked" : ""}><span>Workout</span></label>
        </div>` : `<input type="hidden" name="what" value="sport">`}
      <label class="field" data-for="sport"><span>Sport</span>
        <input name="sport" list="routine-sports" maxlength="40" autocomplete="off" value="${escape(sport)}" placeholder="Run, ride, hike…">
        <datalist id="routine-sports">${KNOWN_SPORTS.map((s) => `<option value="${escape(sportLabel(s))}">`).join("")}</datalist>
      </label>
      ${choices?.length ? `<label class="field" data-for="workout"><span>Workout</span>
        <select name="workout">${choices.map((w) => `<option value="${w.id}"${routine?.workout?.id === w.id ? " selected" : ""}>${escape(w.title)}</option>`).join("")}</select>
      </label>` : ""}
      ${oneOff ? `
        <label class="field"><span>Day</span><input type="date" name="starts_on" min="${today}" value="${startsOn}"></label>
        ${editing ? "" : `<div class="segmented kind-choices" role="radiogroup" aria-label="How sure">
          <label><input type="radio" name="sure" value="maybe" checked><span>Maybe</span></label>
          <label><input type="radio" name="sure" value="planned"><span>Planned</span></label>
        </div>
        <p class="muted small-print">Maybe shows it dashed until you say you're going; Planned counts on it.</p>`}` : `
        <fieldset class="field"><legend>Every</legend>
          <div class="weekday-choices">${WEEKDAY_SHORT.map((name, i) => `<label><input type="checkbox" name="weekday" value="${i + 1}"${weekdays.includes(i + 1) ? " checked" : ""}><span>${name}</span></label>`).join("")}</div>
        </fieldset>
        <label class="field"><span>From</span><input type="date" name="starts_on" min="${today}" value="${startsOn}"></label>
        ${editing && routine.starts_on < today ? `<p class="muted small-print">Days gone by stay as they were: a change to the days or the sport starts a new routine today.</p>` : ""}`}
      <label class="field"><span>Title <span class="muted">(optional)</span></span>
        <input name="title" maxlength="200" value="${escape(routine?.title ?? "")}" placeholder="Long run">
      </label>
      <div class="activity-numbers">
        <label class="field"><span>Minutes</span><input name="minutes" inputmode="numeric" value="${routine?.minutes ?? ""}" placeholder="45"></label>
        <label class="field"><span>Distance</span><span class="with-unit"><input name="distance" inputmode="decimal" value="${escape(distance)}" placeholder="0"><span class="muted">${unit}</span></span></label>
      </div>
      <fieldset class="field"><legend>Effort</legend>
        <div class="segmented kind-choices" role="radiogroup" aria-label="Effort">
          <label><input type="radio" name="effort" value=""${routine?.effort ? "" : " checked"}><span>Any</span></label>
          ${EFFORTS.map((e) => `<label><input type="radio" name="effort" value="${e}"${routine?.effort === e ? " checked" : ""}><span>${e[0].toUpperCase() + e.slice(1)}</span></label>`).join("")}
        </div>
      </fieldset>
      <label class="field"><span>Note <span class="muted">(optional)</span></span>
        <textarea name="note" rows="2" maxlength="2000">${escape(routine?.note ?? "")}</textarea>
      </label>
      <p class="form-error" role="alert" hidden></p>
      <button class="primary" type="submit">${editing ? "Save" : "Plan"}</button>
      ${editing && onEnd ? `<button class="link danger" type="button" data-end>${routine.starts_on < today ? "Stop this routine" : "Delete this routine"}</button>` : ""}
    </form>`;
  const form = dialog.querySelector("form");
  const error = form.querySelector(".form-error");
  const showWhat = () => {
    const value = form.elements.what.value;
    form.querySelector('[data-for="sport"]').hidden = value !== "sport";
    const pick = form.querySelector('[data-for="workout"]');
    if (pick) pick.hidden = value !== "workout";
  };
  form.addEventListener("change", (event) => { if (event.target.name === "what") showWhat(); });
  showWhat();
  form.querySelector("[data-close]").addEventListener("click", () => dialog.close());
  form.querySelector("[data-end]")?.addEventListener("click", () => {
    const question = routine.starts_on < today
      ? `Stop ${routineTitle(routine)} from today? Days gone by stay on the calendar.`
      : `Delete ${routineTitle(routine)}?`;
    if (!confirm(question)) return;
    dialog.close();
    onEnd();
  });
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const elements = form.elements;
    const { fields, problems } = readRoutine({
      what: elements.what.value, sport: elements.sport.value, workoutId: elements.workout?.value ?? "",
      once: oneOff, weekdays: [...form.querySelectorAll('[name="weekday"]:checked')].map((box) => box.value),
      startsOn: elements.starts_on.value, title: elements.title.value, minutes: elements.minutes.value,
      distance: elements.distance.value, effort: form.querySelector('[name="effort"]:checked')?.value ?? "", note: elements.note.value,
    }, unit);
    if (problems.length === 0 && fields.starts_on < today && !(editing && fields.starts_on === routine.starts_on)) {
      problems.push("Pick a day from today on.");
    }
    // A change leaves the start where it was when it isn't moved forward,
    // and the distance as kept when its rounded figure wasn't touched.
    if (editing && routine.starts_on < today && fields.starts_on === today) fields.starts_on = routine.starts_on;
    if (editing && elements.distance.value.trim() === distance) fields.distance_m = routine.distance_m;
    if (problems.length) {
      error.textContent = problems.join(" ");
      error.hidden = false;
      return;
    }
    const problem = await onSave(fields, { confirmed: !editing && oneOff && form.querySelector('[name="sure"]:checked')?.value === "planned" });
    if (problem) {
      error.textContent = problem;
      error.hidden = false;
      return;
    }
    dialog.close();
  });
  dialog.showModal();
}
