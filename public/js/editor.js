import { getJson, loadProblem, errorMessage, paths, send, STALE_NOTE } from "./api.js";
import { escape, icon, busy, showSheet } from "./html.js";
import { createFigure } from "./figure-view.js";
import { openHowto, equipmentNames, learnEquipmentNames } from "./howto.js";
import { missingGear, ownedSlugs } from "./gear.js";
import { formatWeight, sameShownWeight } from "./weights.js";
import { AREAS, BODYWEIGHT, matches, standIns, gearUsed, countLine } from "./catalog.js";
import { blockName } from "./workout.js";
import { routeHash } from "./routes.js";
import {
  KINDS, MODES, draftFrom, newDraft, setKind, addBlock, newStep, setExercise, setMode, stepAmount, stepRounds,
  stepRest, weightOptions, stepDraftWeight, moveBlock, moveStep, locate, removeBlock, removeStep, saveRequest,
  changed, placeProblems, draftSummary,
} from "./builder.js";

// The workout editor (#edit/<id>, #edit/new): a workout of your own, its
// name, warm-up and cool-down, and every block and step, changed as a draft
// in the browser and saved in one go (PUT /api/workouts/:id, or POST for a
// new one). The logic lives in builder.js; this module draws it.

const $ = (id) => document.getElementById(id);
const NO_PROBLEMS = { general: [], blocks: {}, steps: {} };
const LEAVE_QUESTION = "Leave without saving? Your changes will be lost.";

// The open editor: { routeId, draft, saved, exercises, inventory, frames,
// unit, openSteps, problems, stills, onSaved }, or null.
let editor = null;
// The picker's filters, kept while the page is open.
const pickerFilters = { query: "", area: "", equipment: "", owned: true };

// Opens the editor for workout `id`, or a new workout for "new". `onSaved`
// gets the workout as the server answers, and whether it was just created,
// before the editor shows it. `cameFrom` is the URL hash the editor was
// opened from, to step back to rather than stack another entry on it.
export async function openEditor(id, { unit, onSaved, cameFrom = "" }) {
  closeEditor();
  const routeId = String(id);
  const session = { routeId, unit, onSaved, cameFrom };
  editor = session;
  $("edit-heading").textContent = routeId === "new" ? "New workout" : "Edit workout";
  $("edit-tagline").textContent = "";
  $("edit-status").textContent = "";
  $("edit-save").hidden = true;
  $("edit-form").innerHTML = `<p class="muted">Loading…</p>`;
  try {
    const [workout, exercises, inventory, catalog] = await Promise.all([
      routeId === "new" ? null : getJson(paths.workout(routeId)),
      getJson(paths.exercises),
      getJson(paths.equipment),
      getJson(paths.workouts).catch(() => ({ data: [] })),
    ]);
    if (editor !== session) return;
    learnEquipmentNames(inventory.data);
    const programs = catalog.data;
    Object.assign(session, {
      exercises: exercises.data,
      inventory: inventory.data,
      frames: programs.flatMap((program) => program.workouts.filter((w) => w.kind !== "workout")
        .map((w) => ({ id: w.id, kind: w.kind, label: program.id ? `${w.title} (${program.name})` : w.title }))),
      // A new main workout starts framed as the first program's sessions are.
      defaultFrames: Object.fromEntries(["warmup", "cooldown"].map((kind) =>
        [kind, programs.find((p) => p.id)?.workouts.find((w) => w.kind === kind)?.id ?? null])),
      // Each program's name and whether it has a warm-up and a cool-down,
      // for the "the program's own" choice.
      programFrames: new Map(programs.filter((program) => program.id).map((program) => [program.id, {
        name: program.name,
        warmup: program.workouts.some((w) => w.kind === "warmup"),
        cooldown: program.workouts.some((w) => w.kind === "cooldown"),
      }])),
      stale: [workout, exercises, inventory].some((answer) => answer?.stale),
      openSteps: new Set(),
      problems: NO_PROBLEMS,
      stills: new Map(),
    });
    if (workout && !workout.data.editable) return renderReadOnly(workout.data);
    session.draft = workout ? draftFrom(workout.data) : newDraft("workout", session.defaultFrames);
    session.saved = saveRequest(session.draft).body;
    $("edit-heading").textContent = workout ? workout.data.title : "New workout";
    $("edit-tagline").textContent = workout
      ? "Changes are kept on this page until you save."
      : "Pick what kind it is, name it and add exercises. Nothing is kept until you save.";
    $("edit-save").hidden = false;
    $("edit-save").textContent = "Save";
    render();
    showConnection();
  } catch (error) {
    if (editor === session) $("edit-form").innerHTML = `<p>${escape(loadProblem("the editor", error))}</p>`;
  }
}

function renderReadOnly(workout) {
  $("edit-heading").textContent = workout.title;
  $("edit-form").innerHTML = `
    <section class="card">
      <p>This workout was deleted, so it can't be changed.</p>
      <div class="card-actions"><a class="button secondary small" href="${routeHash("workout", workout.id)}">Back to the workout</a></div>
    </section>`;
}

// Whether leaving for the route `view`/`id` may go on: asks first when the
// draft has changes, and puts the editor's URL back when the answer is to stay.
export function leaveEditor(view, id) {
  if (!editor || (view === "edit" && String(id) === editor.routeId)) return true;
  if (unsaved() && !confirm(LEAVE_QUESTION)) {
    // The browser has already moved on (its Back button): the URL is put
    // back, and the entry the editor came from can no longer be told apart.
    history.replaceState(null, "", routeHash("edit", editor.routeId));
    editor.cameFrom = "";
    return false;
  }
  closeEditor();
  return true;
}

function unsaved() {
  return Boolean(editor?.draft && changed(editor.draft, editor.saved));
}

function closeEditor() {
  editor?.stills?.forEach((still) => still.figure.destroy());
  editor = null;
}

// ---------- Drawing ----------

function render() {
  const { draft } = editor;
  const focused = document.activeElement?.closest?.("#edit [data-focus]")?.dataset.focus;
  // Each step's still is drawn once and moved into the redrawn form.
  const before = editor.stills;
  editor.stills = new Map();
  $("edit-form").innerHTML = (editor.stale ? `<p class="muted">${STALE_NOTE}</p>` : "") + details(draft) +
    draft.blocks.map((block, b) => blockCard(block, b, draft.blocks.length)).join("") +
    `<button class="secondary editor-add" data-act="add-block" data-focus="add-block">${icon("plus")}Add block</button>`;
  const steps = new Map(draft.blocks.flatMap((block) => block.steps).map((step) => [step.key, step]));
  for (const box of $("edit-form").querySelectorAll("[data-still]")) {
    const step = steps.get(box.dataset.still);
    if (!step?.exercise.animation) continue;
    const kept = before.get(step.key);
    if (kept?.exerciseId === step.exercise.id) {
      box.replaceChildren(kept.svg);
      before.delete(step.key);
      editor.stills.set(step.key, kept);
    } else {
      const figure = createFigure(box, step.exercise.animation, { still: true });
      editor.stills.set(step.key, { exerciseId: step.exercise.id, figure, svg: box.firstElementChild });
    }
  }
  before.forEach((still) => still.figure.destroy());
  if (focused) refocus(focused);
}

// Puts the focus back on the control it was on, which may have moved; a
// control now disabled (a block moved to the top) hands it to its row.
function refocus(key) {
  const element = $("edit-form").querySelector(`[data-focus="${CSS.escape(key)}"]`);
  if (element && !element.disabled) return element.focus();
  const [, itemKey] = key.split(":");
  $("edit-form").querySelector(`[data-focus$=":${CSS.escape(itemKey ?? "")}"]:not([disabled])`)?.focus();
}

function details(draft) {
  const main = draft.kind === "workout";
  const general = editor.problems.general;
  const kinds = draft.id == null ? `
    <div class="field">
      <span class="field-label" id="edit-kind-label">Kind</span>
      <div class="segmented fill" role="group" aria-labelledby="edit-kind-label">
        ${KINDS.map((kind) => `<button type="button" data-act="kind" data-kind="${kind.id}" data-focus="kind:${kind.id}" aria-pressed="${draft.kind === kind.id}">${kind.label}</button>`).join("")}
      </div>
    </div>` : "";
  return `
    <section class="card editor-details">
      ${general.length ? problemList(general, "edit-problems") : ""}
      ${kinds}
      <label class="field"><span class="field-label">Name</span>
        <input data-field="title" value="${escape(draft.title)}" maxlength="80" autocomplete="off" required></label>
      <label class="field"><span class="field-label">Description <span class="muted">(optional)</span></span>
        <input data-field="subtitle" value="${escape(draft.subtitle)}" maxlength="120" autocomplete="off" placeholder="Legs and core, 25 minutes"></label>
      ${main ? frameSelect("warmup", "Warm-up", draft) + frameSelect("cooldown", "Cool-down", draft) : ""}
    </section>`;
}

function frameSelect(kind, label, draft) {
  const chosen = draft[kind];
  // The program's own, named: "Home strength's warm-up", or that it has none.
  const program = editor.programFrames.get(draft.programId);
  const part = label.toLowerCase();
  const own = program?.[kind] ? `${program.name}'s ${part}` : `None (${program?.name ?? "the program"} has no ${part})`;
  const fallback = draft.programId
    ? `<option value=""${chosen == null ? " selected" : ""}>${escape(own)}</option>` : "";
  const none = chosen === "none" || (chosen == null && !draft.programId);
  const frames = editor.frames.filter((frame) => frame.kind === kind);
  // A chosen one since deleted is no longer listed, but still runs: say so.
  const gone = typeof chosen === "number" && !frames.some((frame) => frame.id === chosen)
    ? `<option value="${chosen}" selected>${escape(draft.frameTitles?.[kind] ?? label)} (deleted)</option>` : "";
  const options = gone + frames
    .map((frame) => `<option value="${frame.id}"${frame.id === chosen ? " selected" : ""}>${escape(frame.label)}</option>`).join("");
  return `<label class="field"><span class="field-label">${label}</span>
    <select data-field="${kind}">${fallback}<option value="none"${none ? " selected" : ""}>None</option>${options}</select></label>`;
}

function blockCard(block, index, count) {
  const name = escape(blockName(block.label || "?"));
  const problems = editor.problems.blocks[block.key] ?? [];
  const k = block.key;
  return `
    <section class="card block editor-block${problems.length ? " has-problems" : ""}" aria-label="${name}">
      <div class="editor-block-head">
        <label class="editor-label"><span class="visually-hidden">Label of ${name}</span>
          <input data-field="label" data-key="${k}" value="${escape(block.label)}" maxlength="40" autocomplete="off"></label>
        <div class="editor-moves">
          <button type="button" class="icon-button" data-act="block-up" data-key="${k}" data-focus="block-up:${k}" aria-label="Move ${name} up"${index === 0 ? " disabled" : ""}>${icon("chevron-up")}</button>
          <button type="button" class="icon-button" data-act="block-down" data-key="${k}" data-focus="block-down:${k}" aria-label="Move ${name} down"${index === count - 1 ? " disabled" : ""}>${icon("chevron-down")}</button>
          <button type="button" class="icon-button danger" data-act="block-remove" data-key="${k}" data-focus="block-remove:${k}" aria-label="Remove ${name}">${icon("trash")}</button>
        </div>
      </div>
      <div class="editor-settings">
        ${setting("Rounds", stepper("rounds", k, block.rounds, `rounds of ${name}`))}
        ${block.rounds > 1 ? setting("Rest between rounds", stepper("rest", k, `${block.rest_seconds} s`, `rest in ${name}`)) : ""}
      </div>
      ${problems.length ? problemList(problems) : ""}
      ${block.steps.length ? `<ol class="editor-steps">${block.steps.map(stepItem).join("")}</ol>` : `<p class="muted editor-empty">No exercises yet.</p>`}
      <button type="button" class="secondary editor-add" data-act="add-step" data-key="${k}" data-focus="add-step:${k}">${icon("plus")}Add exercise</button>
    </section>`;
}

function stepItem(step) {
  const k = step.key;
  const open = editor.openSteps.has(k);
  const problems = editor.problems.steps[k] ?? [];
  const summary = draftSummary(step, (weight) => formatWeight(weight, editor.unit));
  return `
    <li class="editor-step${open ? " open" : ""}${problems.length ? " has-problems" : ""}">
      <div class="editor-step-row">
        <span class="swap-still" data-still="${k}" aria-hidden="true"></span>
        <button type="button" class="editor-step-toggle" data-act="toggle" data-key="${k}" data-focus="toggle:${k}" aria-expanded="${open}">
          <span class="row-text"><span class="row-title">${escape(step.exercise.name)}</span><span class="row-meta">${escape(summary || "Not set")}</span></span>
          ${icon(open ? "chevron-up" : "chevron-down")}
        </button>
      </div>
      ${problems.length ? problemList(problems) : ""}
      ${open ? stepPanel(step) : ""}
    </li>`;
}

function stepPanel(step) {
  const k = step.key;
  const name = escape(step.exercise.name);
  const sides = step.exercise.unilateral ? " each side" : "";
  const options = weightOptions(step, editor.inventory, editor.unit);
  const amount = step.mode === "reps"
    ? setting(`Reps${sides || (step.exercise.alternating ? " in total" : "")}`, stepper("amount", k, step.reps, `reps of ${name}`))
    : step.mode === "seconds" ? setting(`Time${sides}`, stepper("amount", k, `${step.seconds} s`, `time of ${name}`)) : "";
  return `
    <div class="editor-step-panel">
      <div class="segmented fill" role="group" aria-label="What ${name} counts">
        ${MODES.map((mode) => `<button type="button" data-act="mode" data-mode="${mode.id}" data-key="${k}" data-focus="mode-${mode.id}:${k}" aria-pressed="${step.mode === mode.id}">${mode.label}</button>`).join("")}
      </div>
      <div class="editor-settings">${amount}${options ? weightSetting(step, options) : ""}</div>
      ${options ? weightHint(step, options) : ""}
      <div class="editor-settings">
        <div class="field editor-tempo">
          <label class="field-label" for="tempo-${k}">Tempo <span class="muted">(optional)</span></label>
          <input id="tempo-${k}" data-field="tempo" data-key="${k}" value="${escape(step.tempo)}" inputmode="numeric" maxlength="4" placeholder="3110" autocomplete="off" aria-describedby="tempo-hint-${k}">
          <p class="muted editor-hint" id="tempo-hint-${k}">Seconds down, pause, up, pause</p>
        </div>
        <label class="field editor-note"><span class="field-label">Note <span class="muted">(optional)</span></span>
          <input data-field="note" data-key="${k}" value="${escape(step.note)}" maxlength="120" autocomplete="off"></label>
      </div>
      <div class="editor-step-actions">
        <button type="button" class="secondary small" data-act="step-up" data-key="${k}" data-focus="step-up:${k}" aria-label="Move ${name} up">${icon("chevron-up")}Up</button>
        <button type="button" class="secondary small" data-act="step-down" data-key="${k}" data-focus="step-down:${k}" aria-label="Move ${name} down">${icon("chevron-down")}Down</button>
        <button type="button" class="secondary small" data-act="change" data-key="${k}" data-focus="change:${k}">${icon("swap")}Change</button>
        <button type="button" class="secondary small" data-act="howto" data-key="${k}" data-focus="howto:${k}">${icon("info")}How to</button>
        <button type="button" class="secondary small danger" data-act="step-remove" data-key="${k}" data-focus="step-remove:${k}" aria-label="Remove ${name}">${icon("trash")}Remove</button>
      </div>
    </div>`;
}

function weightSetting(step) {
  const shown = step.weight ? formatWeight(step.weight, editor.unit) : "None";
  const label = (step.weights_held ?? step.exercise.weights_held) === 2 ? "Weight, each hand" : "Weight";
  return setting(label, stepper("weight", step.key, shown, `weight for ${escape(step.exercise.name)}`));
}

// What the weight means when it isn't the one sessions use, or can't step
// through owned weights.
function weightHint(step, options) {
  const hint = step.current && step.weight && !sameShownWeight(step.current, step.weight, editor.unit)
    ? `You're at ${formatWeight(step.current, editor.unit)} now; sessions use that. This is where a first session starts.`
    : step.none && step.weight ? "You do it without a weight now; sessions use that. This is where a first session starts."
    : !options.allowed.length ? "None of its equipment has weights in your inventory, so it steps by the usual increments." : "";
  return hint ? `<p class="muted editor-hint">${escape(hint)}</p>` : "";
}

function setting(label, control) {
  return `<div class="editor-setting"><span class="field-label">${label}</span>${control}</div>`;
}

function stepper(name, key, shown, what) {
  return `
    <div class="stepper">
      <button type="button" class="secondary" data-act="${name}-down" data-key="${key}" data-focus="${name}-down:${key}" aria-label="Less ${what}">${icon("minus")}</button>
      <span aria-live="polite">${escape(String(shown))}</span>
      <button type="button" class="secondary" data-act="${name}-up" data-key="${key}" data-focus="${name}-up:${key}" aria-label="More ${what}">${icon("plus")}</button>
    </div>`;
}

function problemList(lines, id = "") {
  return `<ul class="editor-problems" role="alert"${id ? ` id="${id}"` : ""}>${lines.map((line) => `<li>${escape(line)}</li>`).join("")}</ul>`;
}

// ---------- Changes ----------

function onClick(event) {
  const button = event.target.closest("button[data-act]");
  if (!button || !editor?.draft) return;
  const { draft } = editor;
  const act = button.dataset.act;
  const where = button.dataset.key ? locate(draft, button.dataset.key) : null;
  const block = where && draft.blocks[where.block];
  const step = where?.step != null ? block.steps[where.step] : null;
  const unit = editor.unit;

  switch (act) {
    case "kind": setKind(draft, button.dataset.kind, editor.defaultFrames); break;
    case "add-block": {
      const added = addBlock(draft);
      render();
      return $("edit-form").querySelector(`[data-field="label"][data-key="${added.key}"]`)?.focus();
    }
    case "block-up": case "block-down": moveBlock(draft, where.block, act === "block-up" ? "up" : "down"); break;
    case "block-remove": {
      const count = block.steps.length;
      if (count && !confirm(`Remove ${blockName(block.label || "this block")} and its ${count === 1 ? "exercise" : `${count} exercises`}?`)) return;
      removeBlock(draft, where.block);
      render();
      return $("edit-form").querySelector(".editor-add[data-act='add-block']")?.focus();
    }
    case "rounds-up": case "rounds-down": stepRounds(block, act.endsWith("up") ? "up" : "down"); break;
    case "rest-up": case "rest-down": stepRest(block, act.endsWith("up") ? "up" : "down"); break;
    case "add-step": return pick(`Add to ${blockName(block.label || "the block")}`, (exercise) => {
      const added = newStep(exercise, editor.inventory, unit);
      block.steps.push(added);
      editor.openSteps.add(added.key);
      render();
      $("edit-form").querySelector(`[data-focus="toggle:${added.key}"]`)?.focus();
    });
    case "change": return pick(`Instead of ${step.exercise.name}`, (exercise) => {
      setExercise(step, exercise, editor.inventory, unit);
      render();
      $("edit-form").querySelector(`[data-focus="change:${step.key}"]`)?.focus();
    }, step.exercise.id);
    case "toggle":
      if (editor.openSteps.has(step.key)) editor.openSteps.delete(step.key);
      else editor.openSteps.add(step.key);
      break;
    case "mode": setMode(step, button.dataset.mode); break;
    case "amount-up": case "amount-down": stepAmount(step, act.endsWith("up") ? "up" : "down"); break;
    case "weight-up": case "weight-down":
      stepDraftWeight(step, act.endsWith("up") ? "up" : "down", weightOptions(step, editor.inventory, unit), draft.weightSteps ?? undefined);
      break;
    case "step-up": case "step-down": moveStep(draft, where.block, where.step, act === "step-up" ? "up" : "down"); break;
    case "howto": return openHowto(step.exercise, { controls: true, tempo: step.tempo.trim() || null });
    case "step-remove":
      removeStep(draft, where.block, where.step);
      editor.openSteps.delete(step.key);
      render();
      return $("edit-form").querySelector(`[data-focus="add-step:${block.key}"]`)?.focus();
    default: return;
  }
  render();
}

// Typing changes the draft without drawing it again, so the cursor stays.
function onInput(event) {
  const field = event.target.dataset.field;
  if (!field || !editor?.draft) return;
  const { draft } = editor;
  const value = event.target.value;
  if (field === "title" || field === "subtitle") draft[field] = value;
  // The header names the workout as it is being renamed.
  if (field === "title") $("edit-heading").textContent = value.trim() || (editor.routeId === "new" ? "New workout" : "Untitled");
  if (field === "warmup" || field === "cooldown") draft[field] = value === "" ? null : value === "none" ? "none" : Number(value);
  const where = event.target.dataset.key && locate(draft, event.target.dataset.key);
  if (!where) return;
  const block = draft.blocks[where.block];
  if (field === "label") block.label = value;
  if (field === "tempo" || field === "note") {
    const step = block.steps[where.step];
    step[field] = value;
    const meta = event.target.closest(".editor-step")?.querySelector(".row-meta");
    if (meta) meta.textContent = draftSummary(step, (weight) => formatWeight(weight, editor.unit)) || "Not set";
  }
}

async function save() {
  const session = editor;
  if (!session?.draft) return;
  const request = saveRequest(session.draft);
  const button = $("edit-save");
  busy(button);
  $("edit-status").textContent = "Saving…";
  try {
    const response = await send(request.path, { method: request.method, body: request.body });
    const data = await response.json().catch(() => null);
    if (editor !== session) return;
    if (response.ok && data) {
      closeEditor();
      session.onSaved(data, request.method === "POST");
      return leaveTo(routeHash("workout", data.id), session.cameFrom);
    }
    session.problems = response.status === 422 ? placeProblems(data?.error?.fields, session.draft) : NO_PROBLEMS;
    if (response.status === 422 && !Object.keys(data?.error?.fields ?? {}).length) session.problems.general.push(errorMessage(data, response.status));
    for (const key of Object.keys(session.problems.steps)) session.openSteps.add(key);
    render();
    $("edit-status").textContent = response.status === 422
      ? "Not saved: see what's marked."
      : `Not saved: ${errorMessage(data, response.status)}`;
    $("edit-form").querySelector(".editor-problems")?.scrollIntoView({ block: "center", behavior: "smooth" });
  } catch {
    if (editor === session) $("edit-status").textContent = "Not saved: saving needs a connection. Your changes are still here.";
  } finally {
    busy(button, false);
  }
}

// ---------- The exercise picker ----------

// A sheet over the editor listing the library, found as on the Exercises
// page: search, body area, equipment, and only what you own (the default).
// `onPick` gets the exercise tapped; `current` is left out of the list.
function pick(title, onPick, current = null) {
  const dialog = $("picker") ?? document.body.appendChild(Object.assign(document.createElement("dialog"), { id: "picker", className: "sheet" }));
  const used = gearUsed(editor.exercises, editor.inventory);
  dialog.innerHTML = `
    <form method="dialog" class="howto picker">
      <header>
        <h2>${escape(title)}</h2>
        <button class="icon-button" aria-label="Close">${icon("close")}</button>
      </header>
      <input type="search" id="picker-search" placeholder="Search exercises" aria-label="Search exercises" value="${escape(pickerFilters.query)}" autocomplete="off">
      <div class="segmented" role="group" aria-label="Body area">
        ${[{ id: "", label: "All areas" }, ...AREAS].map((area) => `<button type="button" data-area="${area.id}">${escape(area.label)}</button>`).join("")}
      </div>
      <div class="picker-filters">
        <select id="picker-equipment" aria-label="Equipment">
          <option value="">Any equipment</option><option value="${BODYWEIGHT}">No equipment</option>
          ${editor.inventory.filter((item) => used.has(item.slug)).map((item) => `<option value="${escape(item.slug)}">${escape(item.name)}</option>`).join("")}
        </select>
        <div class="segmented fill" role="group" aria-label="Which exercises">
          <button type="button" data-owned="true">What I own</button>
          <button type="button" data-owned="false">Everything</button>
        </div>
      </div>
      <p class="muted" id="picker-count" aria-live="polite"></p>
      <ul class="list" id="picker-list"></ul>
    </form>`;
  dialog.querySelector("#picker-equipment").value = pickerFilters.equipment;

  const owned = ownedSlugs(editor.inventory);
  const names = Object.fromEntries(editor.inventory.map((item) => [item.slug, item.name]));
  let stills = [];
  let shown = [];
  const draw = () => {
    for (const button of dialog.querySelectorAll("[data-area]")) button.setAttribute("aria-pressed", String(button.dataset.area === pickerFilters.area));
    for (const button of dialog.querySelectorAll("[data-owned]")) button.setAttribute("aria-pressed", String((button.dataset.owned === "true") === pickerFilters.owned));
    const pool = editor.exercises.filter((e) => e.id !== current && matches(e, { owned: pickerFilters.owned ? owned : null }));
    shown = pool.filter((e) => matches(e, { query: pickerFilters.query, area: pickerFilters.area, equipment: pickerFilters.equipment, standIns: standIns(pickerFilters.equipment, editor.inventory), names }));
    const filtered = Boolean(pickerFilters.query || pickerFilters.area || pickerFilters.equipment);
    dialog.querySelector("#picker-count").textContent = countLine(shown.length, pool.length, { owned: pickerFilters.owned, filtered });
    stills.forEach((figure) => figure.destroy());
    stills = [];
    const list = dialog.querySelector("#picker-list");
    list.innerHTML = shown.length ? shown.map(pickerRow).join("") : `<li><p class="muted">Nothing matches. Try another area, or Everything.</p></li>`;
    for (const box of list.querySelectorAll("[data-still]")) {
      const exercise = shown[Number(box.dataset.still)];
      if (exercise.animation) stills.push(createFigure(box, exercise.animation, { still: true }));
    }
  };
  // Gear the user doesn't own is marked in the row: a cross and "not yours yet".
  const pickerRow = (exercise, i) => {
    const missing = new Set(missingGear(exercise.equipment, owned));
    const gear = (exercise.equipment ?? []).map((slug) => {
      const [name] = equipmentNames([slug]);
      return missing.has(slug) ? `<span class="gear-missing-text">${icon("close")}${escape(name)}, not yours yet</span>` : escape(name);
    });
    const meta = [escape(exercise.category), ...gear, exercise.unilateral ? "per side" : exercise.alternating ? "alternating sides" : ""].filter(Boolean).join(" · ");
    return `<li class="picker-row">
      <button type="button" class="row" data-pick="${i}">
        <span class="swap-still" data-still="${i}" aria-hidden="true"></span>
        <span class="row-text"><span class="row-title">${escape(exercise.name)}</span><span class="row-meta">${meta}</span></span>
      </button>
      <button type="button" class="icon-button" data-preview="${i}" aria-label="How to do ${escape(exercise.name)}">${icon("info")}</button>
    </li>`;
  };

  dialog.querySelector("#picker-search").addEventListener("input", (event) => {
    pickerFilters.query = event.target.value;
    draw();
  });
  // Enter in the search box would submit the dialog's form and close it.
  dialog.querySelector("#picker-search").addEventListener("keydown", (event) => {
    if (event.key === "Enter") event.preventDefault();
  });
  dialog.querySelector("#picker-equipment").addEventListener("change", (event) => {
    pickerFilters.equipment = event.target.value;
    draw();
  });
  dialog.querySelector("form").addEventListener("click", (event) => {
    const button = event.target.closest("button[type='button']");
    if (!button) return;
    if (button.dataset.area !== undefined) pickerFilters.area = button.dataset.area;
    if (button.dataset.owned) pickerFilters.owned = button.dataset.owned === "true";
    if (button.dataset.preview) return openHowto(shown[Number(button.dataset.preview)], { controls: true });
    if (button.dataset.pick) {
      const exercise = shown[Number(button.dataset.pick)];
      dialog.close();
      return onPick(exercise);
    }
    draw();
  });
  dialog.addEventListener("close", () => stills.forEach((figure) => figure.destroy()), { once: true });
  draw();
  showSheet(dialog);
  dialog.querySelector("#picker-search").focus();
}

// ---------- Wiring ----------

$("edit-form").addEventListener("click", onClick);
$("edit-form").addEventListener("input", onInput);
// The navigation, and its Offline note, is hidden in the editor: it says so
// itself, since saving needs a connection.
const OFFLINE_NOTE = "Offline: saving needs a connection. Your changes stay here.";
function showConnection() {
  if ($("edit").hidden) return;
  const status = $("edit-status");
  if (!navigator.onLine && !status.textContent) status.textContent = OFFLINE_NOTE;
  if (navigator.onLine && status.textContent === OFFLINE_NOTE) status.textContent = "";
}
window.addEventListener("offline", showConnection);
window.addEventListener("online", showConnection);
$("edit-form").addEventListener("change", onInput);
$("edit-save").onclick = save;
// Leaves the editor for `hash`: back in the history when that is where it was
// opened from, else in the editor's place, so Back doesn't return to it.
function leaveTo(hash, cameFrom) {
  if (cameFrom === hash) history.back();
  else location.replace(hash);
}

$("edit-back").onclick = () => {
  if (!editor) return history.back();
  if (unsaved() && !confirm(LEAVE_QUESTION)) return;
  const { routeId, cameFrom } = editor;
  closeEditor();
  leaveTo(routeId === "new" ? routeHash("workouts") : routeHash("workout", routeId), cameFrom);
};
// A link away (the navigation, mostly) asks before it goes, so staying
// leaves the history as it was.
document.addEventListener("click", (event) => {
  const link = event.target.closest("a[href]");
  if (!link || link.target === "_blank" || link.closest("dialog") || !unsaved() || $("edit").hidden) return;
  if (confirm(LEAVE_QUESTION)) return closeEditor();
  event.preventDefault();
}, true);
// A reload or a closed tab would lose the draft.
window.addEventListener("beforeunload", (event) => {
  if (unsaved()) event.preventDefault();
});
