// Pure logic for the workout editor: a draft of a workout's blocks and steps
// that the editor (editor.js) changes and draws, and the request that saves
// it (PUT or POST /api/workouts, see WorkoutStructure on the server). No DOM.
//
// A draft step keeps its exercise whole, so it can be drawn, and its own `id`
// when it came from the server, so the sets logged against it keep their
// link. Every block and step also has a `key`, which stays the same while it
// moves around, for the editor to follow it.

import { stepWeight } from "./weights.js";
import { amountText } from "./workout.js";

export const KINDS = [
  { id: "workout", label: "Workout" },
  { id: "warmup", label: "Warm-up" },
  { id: "cooldown", label: "Cool-down" },
];

// What a step counts: reps, seconds, or nothing but what its note says.
export const MODES = [
  { id: "reps", label: "Reps" },
  { id: "seconds", label: "Time" },
  { id: "note", label: "Note only" },
];

// Steppers: how far one press moves, and where they stop.
// The server's limits (Step::MAX_REPS, Step::MAX_SECONDS) are the tops.
const REPS = { step: 1, min: 1, max: 1000, fallback: 10 };
const SECONDS = { step: 5, min: 5, max: 3600, fallback: 30 };
const ROUNDS = { step: 1, min: 1, max: 10 };
const REST = { step: 15, min: 0, max: 300 };
// Bands for a weight with no owned weights to step through, used when the
// server's table (config/coach.yml, in GET /api/workouts/:id) isn't at hand.
const FALLBACK_STEPS = { default: { lb: [{ step: 5 }], kg: [{ step: 2.5 }] } };
const KG_PER_LB = 0.45359237;

let lastKey = 0;
const nextKey = () => `k${++lastKey}`;

// A draft of a workout from GET /api/workouts/:id.
export function draftFrom(workout) {
  return {
    id: workout.id,
    kind: workout.kind,
    title: workout.title ?? "",
    subtitle: workout.subtitle ?? "",
    warmup: workout.warmup ?? null,
    cooldown: workout.cooldown ?? null,
    programId: workout.program_id ?? null,
    weightSteps: workout.weight_steps ?? null,
    // Titles of the warm-up and cool-down it runs with, by kind.
    frameTitles: Object.fromEntries((workout.framed ?? []).filter((part) => part.kind !== "workout").map((part) => [part.kind, part.title])),
    blocks: workout.blocks.map((block) => ({
      key: nextKey(),
      id: block.id,
      label: block.label,
      rounds: block.rounds,
      rest_seconds: block.rest_seconds,
      steps: block.steps.map((step) => ({
        key: nextKey(),
        id: step.id,
        exercise: step.exercise,
        mode: step.reps != null ? "reps" : step.duration_seconds != null ? "seconds" : "note",
        reps: step.reps,
        seconds: step.duration_seconds,
        tempo: step.tempo ?? "",
        weight: step.weight ? { ...step.weight } : null,
        // What the player uses now: a remembered weight wins over the step's,
        // "no weight" included (`none`).
        current: step.target?.weight ?? null,
        none: !!(step.weight && step.target && !step.target.weight),
        weights_held: step.weights_held ?? null,
        // Only when the step names other gear than its exercise does.
        equipment: step.equipment && !sameSlugs(step.equipment, step.exercise.equipment) ? [...step.equipment] : null,
        note: step.note ?? "",
      })),
    })),
  };
}

// An empty draft of a new workout of `kind`, with one block to fill. A main
// workout starts with the warm-up and cool-down given (ids, or null).
export function newDraft(kind = "workout", { warmup = null, cooldown = null } = {}) {
  const main = kind === "workout";
  return {
    id: null, kind, title: "", subtitle: "",
    warmup: main ? warmup ?? "none" : null,
    cooldown: main ? cooldown ?? "none" : null,
    programId: null, weightSteps: null,
    blocks: [newBlock({ blocks: [] })],
  };
}

// Changes a new draft's kind: only a main workout picks a warm-up and cool-down.
export function setKind(draft, kind, frames = {}) {
  if (draft.id != null) throw new Error("only a new workout can change its kind");
  draft.kind = kind;
  draft.warmup = kind === "workout" ? frames.warmup ?? "none" : null;
  draft.cooldown = kind === "workout" ? frames.cooldown ?? "none" : null;
  return draft;
}

// A block labelled with the first letter no other block of the draft uses.
export function newBlock(draft) {
  const used = new Set(draft.blocks.map((block) => block.label));
  let label = "";
  for (let i = 0; !label || used.has(label); i++) label = blockLetter(i);
  return { key: nextKey(), id: null, label, rounds: 1, rest_seconds: 0, steps: [] };
}

function blockLetter(index) {
  const letter = String.fromCharCode(65 + (index % 26));
  return index < 26 ? letter : `${letter}${Math.floor(index / 26) + 1}`;
}

export function addBlock(draft) {
  const block = newBlock(draft);
  draft.blocks.push(block);
  return block;
}

// A new step of `exercise` with the exercise's own target: its default reps
// or seconds, and the lightest weight owned for it when it takes one.
export function newStep(exercise, inventory = [], unit = "lb") {
  const step = {
    key: nextKey(), id: null, exercise, mode: "reps", reps: null, seconds: null,
    tempo: "", weight: null, current: null, weights_held: null, equipment: null, note: "",
  };
  return setExercise(step, exercise, inventory, unit);
}

// Gives a step another exercise. It becomes a new step, as the server would
// make it: its target starts from the new exercise, its note stays.
export function setExercise(step, exercise, inventory = [], unit = "lb") {
  Object.assign(step, {
    id: null, exercise, reps: null, seconds: null, weight: null, current: null, weights_held: null, equipment: null, tempo: "",
  });
  setMode(step, exercise.default_seconds != null ? "seconds" : "reps");
  const options = weightOptions(step, inventory, unit);
  step.weight = options?.allowed.length ? { value: options.allowed[0], unit: options.unit } : null;
  return step;
}

export function setMode(step, mode) {
  if (!MODES.some((m) => m.id === mode)) throw new Error(`unknown mode ${mode}`);
  step.mode = mode;
  step.reps = mode === "reps" ? step.reps ?? step.exercise.default_reps ?? REPS.fallback : null;
  step.seconds = mode === "seconds" ? step.seconds ?? step.exercise.default_seconds ?? SECONDS.fallback : null;
  return step;
}

// One press on the reps or seconds stepper.
export function stepAmount(step, direction) {
  const sign = direction === "up" ? 1 : -1;
  if (step.mode === "reps") step.reps = clamp((step.reps ?? REPS.fallback) + sign * REPS.step, REPS);
  if (step.mode === "seconds") step.seconds = clamp(roundTo((step.seconds ?? SECONDS.fallback) + sign * SECONDS.step, SECONDS.step), SECONDS);
  return step;
}

export function stepRounds(block, direction) {
  block.rounds = nudge(block.rounds, direction, ROUNDS);
  return block;
}

export function stepRest(block, direction) {
  block.rest_seconds = nudge(block.rest_seconds, direction, REST);
  return block;
}

// One step up or down, onto the step's grid, within its limits; a value
// already past the top (saved through the API) is never lowered by "up".
const clamp = (value, { min, max }) => Math.min(max, Math.max(min, value));

function nudge(value, direction, { step, min, max }) {
  if (direction === "up") return Math.max(value, Math.min(max, roundTo(value + step, step)));
  return Math.min(value, Math.max(min, roundTo(value - step, step)));
}

// Whether a step can carry a weight, and how: the unit it keeps weights in
// (that of the gear in set weights it is done with, its own first, else of
// its exercise's, as Step#gear_unit, else `unit`)
// and the owned weights to step through (as Equipment.allowed_for: those of
// the first owned item with set weights among what the step uses), empty to
// step by bands. Null for a step done without weighted gear and no weight.
export function weightOptions(step, inventory = [], unit = "lb") {
  const items = new Map(inventory.map((item) => [item.slug, item]));
  const gear = stepEquipment(step).map((slug) => items.get(slug)).filter(Boolean);
  if (!gear.some((item) => item.unit) && !step.weight) return null;

  const own = gear.map((item) => item.unit).find(Boolean) ?? step.exercise.equipment.map((slug) => items.get(slug)?.unit).find(Boolean);
  const keptIn = step.weight?.unit ?? own ?? unit;
  const fixed = gear.find((item) => item.owned && item.weights?.length);
  const allowed = fixed ? [...new Set(fixed.weights.map((w) => convert(w, fixed.unit, keptIn)))].sort((a, b) => a - b) : [];
  return { unit: keptIn, allowed };
}

// One press on a step's weight stepper: through the owned weights (or by the
// bands), with "no weight" below the lightest.
export function stepDraftWeight(step, direction, options, table = FALLBACK_STEPS) {
  if (!options) return step;
  const { unit, allowed } = options;
  const value = step.weight?.value;
  if (value == null) {
    if (direction === "up") step.weight = { value: allowed[0] ?? stepWeight(0, unit, stepEquipment(step), "up", table), unit };
    return step;
  }
  if (direction === "down" && (allowed.length ? value <= allowed[0] + 0.01 : value <= 0)) {
    step.weight = null;
    return step;
  }
  const next = stepWeight(value, unit, stepEquipment(step), direction, table, allowed);
  step.weight = next > 0 ? { value: next, unit } : null;
  return step;
}

// The equipment a step is done with: its own, else its exercise's.
export function stepEquipment(step) {
  return step.equipment ?? step.exercise.equipment ?? [];
}

// Moves a block up or down; returns its new index.
export function moveBlock(draft, index, direction) {
  const to = index + (direction === "up" ? -1 : 1);
  if (to < 0 || to >= draft.blocks.length) return index;
  draft.blocks.splice(to, 0, ...draft.blocks.splice(index, 1));
  return to;
}

// Moves a step up or down. Past the first or last step of its block it goes
// to the end of the block above or the start of the one below. Returns where
// it ended up: { block, step } indexes.
export function moveStep(draft, blockIndex, stepIndex, direction) {
  const steps = draft.blocks[blockIndex].steps;
  const up = direction === "up";
  const to = stepIndex + (up ? -1 : 1);
  if (to >= 0 && to < steps.length) {
    steps.splice(to, 0, ...steps.splice(stepIndex, 1));
    return { block: blockIndex, step: to };
  }
  const other = blockIndex + (up ? -1 : 1);
  if (other < 0 || other >= draft.blocks.length) return { block: blockIndex, step: stepIndex };
  const [step] = steps.splice(stepIndex, 1);
  const target = draft.blocks[other].steps;
  if (up) target.push(step);
  else target.unshift(step);
  return { block: other, step: up ? target.length - 1 : 0 };
}

// Where a block or step is, by key: { block, step } indexes (step null for a block).
export function locate(draft, key) {
  for (const [b, block] of draft.blocks.entries()) {
    if (block.key === key) return { block: b, step: null };
    const s = block.steps.findIndex((step) => step.key === key);
    if (s >= 0) return { block: b, step: s };
  }
  return null;
}

export function removeBlock(draft, index) {
  draft.blocks.splice(index, 1);
}

export function removeStep(draft, blockIndex, stepIndex) {
  draft.blocks[blockIndex].steps.splice(stepIndex, 1);
}

// The body that saves the draft: PUT /api/workouts/:id for a workout that
// exists, POST /api/workouts (with its kind) for a new one.
export function saveRequest(draft) {
  const body = {
    title: draft.title.trim(),
    subtitle: draft.subtitle.trim(),
    blocks: draft.blocks.map((block) => ({
      ...(block.id != null && { id: block.id }),
      label: block.label.trim(),
      rounds: block.rounds,
      rest_seconds: block.rest_seconds,
      steps: block.steps.map(stepBody),
    })),
  };
  if (draft.kind === "workout") Object.assign(body, { warmup: draft.warmup, cooldown: draft.cooldown });
  if (draft.id == null) return { method: "POST", path: "/api/workouts", body: { kind: draft.kind, ...body } };
  return { method: "PUT", path: `/api/workouts/${draft.id}`, body };
}

function stepBody(step) {
  const tempo = step.tempo.trim();
  const note = step.note.trim();
  return {
    ...(step.id != null && { id: step.id }),
    exercise_id: step.exercise.id,
    ...(step.mode === "reps" && { reps: step.reps }),
    ...(step.mode === "seconds" && { duration_seconds: step.seconds }),
    ...(tempo && { tempo }),
    ...(step.weight && { weight: { value: step.weight.value, unit: step.weight.unit } }),
    ...(step.weights_held != null && { weights_held: step.weights_held }),
    ...(step.equipment && { equipment: step.equipment }),
    ...(note && { note }),
  };
}

// Whether the draft would save anything other than `saved` (a saveRequest body).
export function changed(draft, saved) {
  return JSON.stringify(saveRequest(draft).body) !== JSON.stringify(saved);
}

// The 422's `fields` (problems keyed by request path, such as
// "blocks[0].steps[1].reps") sorted to where the editor shows them: by block
// and step key, the rest (name, warm-up, ...) as general. Each a sentence.
export function placeProblems(fields, draft) {
  const placed = { general: [], blocks: {}, steps: {} };
  for (const [path, messages] of Object.entries(fields ?? {})) {
    const match = /^blocks\[(\d+)\](?:\.steps\[(\d+)\])?(?:\.(.+))?$/.exec(path);
    const block = match && draft.blocks[Number(match[1])];
    const step = block && match[2] != null ? block.steps[Number(match[2])] : null;
    const field = match ? match[3] : path;
    const lines = [].concat(messages).map((message) => sentence(field, message));
    if (step) (placed.steps[step.key] ??= []).push(...lines);
    else if (block) (placed.blocks[block.key] ??= []).push(...lines);
    else placed.general.push(...lines);
  }
  return placed;
}

const FIELD_NAMES = {
  title: "Name", subtitle: "Description", warmup: "Warm-up", cooldown: "Cool-down", kind: "Kind",
  label: "Label", rounds: "Rounds", rest_seconds: "Rest", reps: "Reps", duration_seconds: "Time",
  tempo: "Tempo", weight: "Weight", "weight.value": "Weight", "weight.unit": "Weight unit",
  weights_held: "Weights held", per_side: "Per side", note: "Note", equipment: "Equipment",
  exercise_id: "Exercise", id: "Id",
};

function sentence(field, message) {
  const name = field && field !== "base" && field !== "blocks" && field !== "steps" ? FIELD_NAMES[field] ?? field : "";
  const text = name ? `${name} ${message}` : String(message);
  return text.charAt(0).toUpperCase() + text.slice(1).replace(/\.?$/, ".");
}

// The line under a step's name: "3 × 8 reps" style facts, its weight in `shown`.
export function draftSummary(step, formatWeight) {
  const bits = [];
  const amount = amountText({
    reps: step.mode === "reps" ? step.reps : null, seconds: step.mode === "seconds" ? step.seconds : null,
    perSide: step.exercise.unilateral, alternating: step.exercise.alternating,
  });
  if (amount) bits.push(amount);
  if (step.weight) bits.push(formatWeight(step.weight));
  if (step.tempo.trim()) bits.push(`tempo ${step.tempo.trim()}`);
  if (step.note.trim()) bits.push(step.note.trim());
  return bits.join(" · ");
}

function sameSlugs(a, b) {
  const x = [...(a ?? [])].sort();
  const y = [...(b ?? [])].sort();
  return x.length === y.length && x.every((slug, i) => slug === y[i]);
}

// As Weights.convert on the server: to two decimals.
function convert(value, from, to) {
  if (!from || !to || from === to) return value;
  return Math.round((to === "kg" ? value * KG_PER_LB : value / KG_PER_LB) * 100) / 100;
}

function roundTo(value, step) {
  return Math.round(value / step) * step;
}
