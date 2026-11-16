import { getJson, send, errorMessage, paths } from "./api.js";
import { adoptAccount, checkSignedIn, nextPath, pageAccount, signInHref } from "./account.js";
import { adoptServerUnit, preferredUnit, setPreferredUnit, unitRequest } from "./weights.js";
import { adoptServerDistanceUnit, distanceUnitRequest, preferredDistanceUnit, setPreferredDistanceUnit } from "./activities.js";
import { createOutbox } from "./outbox.js";
import { mountEquipment } from "./equipment-list.js";
import { mountExamples } from "./example-list.js";
import { createFigure } from "./figure-view.js";
import { localToday } from "./calendar.js";
import { WEEKDAY_SHORT } from "./routines.js";
import { programToPlan, weekPlan } from "./setup.js";
import { html } from "./html.js";

// The welcome screen, shown once, on a user's first sign-in (signin.js):
// units, the gear they own, an example program and the days they train,
// which become weekly routines. Each step saves as it goes. The server
// hears it was seen (`welcomed`) as soon as it shows, so leaving it any way
// doesn't replay it: what is left is on Today's "Getting set up" card.
// Done, or "Skip set-up", goes on to `?next=`.

const storage = (() => {
  try {
    return localStorage;
  } catch {
    return null;
  }
})();
const $ = (id) => document.getElementById(id);
const steps = [...document.querySelectorAll("[data-step]")];
const next = nextPath(location.search);
const units = $("welcome-units");
const distanceUnits = $("welcome-distance-units");
const days = $("welcome-days");
const WEEKDAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
// The units go through the outbox, as on Settings: sent later if they can't be now.
const outbox = storage && createOutbox({ storage, fetch: (...args) => fetch(...args), locks: navigator.locks, user: pageAccount(storage).id });
// What the days step plans: { program, workouts } or null, once loaded.
let toPlan = null;

function show(index) {
  steps.forEach((step, i) => (step.hidden = i !== index));
  $("welcome-step").textContent = `Step ${index + 1} of ${steps.length}`;
  $("welcome-progress").querySelectorAll(".welcome-dots > span").forEach((dot, i) => dot.classList.toggle("on", i <= index));
  const heading = steps[index].querySelector("h2");
  heading.setAttribute("tabindex", "-1");
  heading.focus();
}

// Seen, however it is left. Offline, the server isn't told and the welcome
// shows again at the next sign-in.
let seen = null;
const markSeen = () => (seen = send("/api/account/welcome", { body: {} }).then((response) => response.ok).catch(() => false));

// Unit picks being sent: leaving waits for them, so a page change doesn't cut them off.
const saving = [];

async function finish() {
  await Promise.all(saving);
  if (!(await seen)) await markSeen();
  location.replace(next);
}

// The days step: the newest program's main workouts take turns on the
// days picked. Nothing to plan, or a week planned already, says so.
async function loadDays() {
  const hint = $("welcome-days-hint");
  days.hidden = true;
  toPlan = null;
  try {
    const [{ data: programs, stale }, { data: { routines }, stale: staleRoutines }] = await Promise.all([
      getJson("/api/programs"),
      getJson(`/api/routines?today=${localToday()}`),
    ]);
    // An old copy could plan a week twice.
    if (stale || staleRoutines) throw new Error("offline");
    const plan = programToPlan(programs);
    if (!plan) {
      hint.textContent = "Once you have a program, plan your days on the Calendar.";
      return;
    }
    const ids = new Set(plan.workouts.map((w) => w.id));
    if (routines.some((routine) => ids.has(routine.workout?.id))) {
      hint.innerHTML = html`${plan.program.name} is on your <a href="/calendar.html">Calendar</a> already.`;
      return;
    }
    toPlan = plan;
    const names = plan.workouts.map((w) => w.title);
    hint.textContent = `Tap your training days. ${names.length > 1 ? `${names.join(" and ")} take turns on them` : `${names[0]} goes on them`}, every week, as Maybe days you confirm or move on the Calendar.`;
    days.innerHTML = html`${WEEKDAY_SHORT.map((name, i) => html`
      <label><input type="checkbox" name="weekday" value="${i + 1}" aria-label="${WEEKDAY_NAMES[i]}"><span aria-hidden="true">${name}</span></label>`)}`;
    days.hidden = false;
  } catch {
    hint.textContent = "Plan your days on the Calendar once the server can be reached.";
  }
}

// Makes the routines for the days ticked; false, with the error shown, when that fails.
async function planWeek() {
  const error = $("welcome-days-error");
  error.hidden = true;
  const picked = [...days.querySelectorAll("input:checked")].map((box) => Number(box.value));
  if (!toPlan || picked.length === 0) return true;
  let made = 0;
  try {
    for (const routine of weekPlan(toPlan.workouts, picked)) {
      const response = await send("/api/routines", { body: { ...routine, today: localToday() } });
      if (!response.ok) throw new Error(errorMessage(await response.json().catch(() => null), response.status));
      made += 1;
    }
    return true;
  } catch (failure) {
    if (made > 0) {
      // Half a week is on the Calendar: Done goes on, and the rest is planned there.
      toPlan = null;
      error.textContent = `Only part of the week is planned (${failure.message}). Plan the rest on the Calendar.`;
    } else {
      error.textContent = `Couldn't plan the week (${failure.message}). Try again, or plan it on the Calendar later.`;
    }
    error.hidden = false;
    return false;
  }
}

// Gear with no weights yet follows the unit picked in step 1, sent or not.
const equipment = mountEquipment($("welcome-inventory"), { unitFor: (item) => (item.weights.length ? item.unit : preferredUnit(storage)) });
const examples = mountExamples({ list: $("welcome-examples"), error: $("welcome-examples-error"), done: $("welcome-examples-done") });
// The unit pick being saved, if any: the gear step waits for it.
let unitSaved = Promise.resolve();

steps.forEach((step, index) => {
  step.querySelector("[data-next]").onclick = async (event) => {
    const button = event.currentTarget;
    // One step at a time: no second tap, and no skipping out halfway through planning.
    const skip = $("welcome-skip");
    const back = step.querySelector("[data-back]");
    button.disabled = skip.disabled = true;
    if (back) back.disabled = true;
    try {
      if (index + 1 === steps.length) {
        if (await planWeek()) await finish();
        return;
      }
      // Gear with no weights listed yet follows the unit: draw it in the one picked.
      if (steps[index + 1].contains($("welcome-inventory"))) {
        await unitSaved;
        await equipment.load();
      }
      // The examples say how they fit the gear just ticked.
      if (steps[index + 1].contains($("welcome-examples"))) await examples.load();
      if (steps[index + 1].contains(days)) await loadDays();
      show(index + 1);
    } finally {
      button.disabled = skip.disabled = false;
      if (back) back.disabled = false;
    }
  };
  step.querySelector("[data-back]")?.addEventListener("click", () => show(index - 1));
});
$("welcome-skip").onclick = finish;

const press = (group, value) => {
  for (const button of group.querySelectorAll("[data-value]")) button.setAttribute("aria-pressed", String(button.dataset.value === value));
};
const pressAll = () => {
  press(units, preferredUnit(storage));
  press(distanceUnits, preferredDistanceUnit(storage));
};

// A pick saved on this device and sent to the server, through the outbox when there is one.
function save(request, body) {
  let sent;
  if (outbox) {
    outbox.enqueue(request);
    sent = outbox.flush().catch(() => {});
  } else {
    sent = send("/api/settings", { method: "PATCH", body }).catch(() => {});
  }
  saving.push(sent);
  return sent;
}

units.onclick = (event) => {
  const value = event.target.closest("[data-value]")?.dataset.value;
  if (!value) return;
  setPreferredUnit(storage, value);
  pressAll();
  unitSaved = save(unitRequest(value), { unit: value });
};

distanceUnits.onclick = (event) => {
  const value = event.target.closest("[data-value]")?.dataset.value;
  if (!value) return;
  setPreferredDistanceUnit(storage, value);
  pressAll();
  save(distanceUnitRequest(value), { distance_unit: value });
};

// One of the app's own figures beside the first step: what the sessions look like.
async function showFigure() {
  try {
    const { data: exercises } = await getJson(paths.exercises);
    const exercise = exercises.find((e) => e.slug === "goblet-squat" && e.animation) ?? exercises.find((e) => e.animation);
    if (exercise) createFigure($("welcome-figure"), exercise.animation, { label: `${exercise.name}, as the app shows it` });
  } catch {
    // Offline: the step reads the same without it.
  }
}

const me = await checkSignedIn({ storage, caches: globalThis.caches });
if (me.signedOut || me.user?.password_change_required) {
  location.replace(signInHref(location, { gate: me.gate }));
} else {
  if (me.user) await adoptAccount(me.user, { storage, caches: globalThis.caches });
  $("welcome-status").hidden = true;
  $("welcome-progress").hidden = false;
  $("welcome-skip").hidden = false;
  markSeen();
  pressAll();
  getJson(paths.settings)
    .then(({ data, stale }) => {
      // A pick queued meanwhile wins over the server's answer.
      const queued = outbox?.queued() ?? [];
      adoptServerUnit(storage, data.unit, { queued, stale });
      adoptServerDistanceUnit(storage, data.distance_unit, { queued, stale });
      pressAll();
    })
    .catch(() => {});
  showFigure();
  show(0);
}
