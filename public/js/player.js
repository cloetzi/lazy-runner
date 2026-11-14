// Pure player logic, kept free of the DOM so it can be tested: going back,
// the switch-sides cue, the main button and swapping an exercise for the rest
// of the session. Items are the screens from the player plan.

import { amountText } from "./workout.js";

// Where Back goes: the step before, skipping rests, since a rest on its own
// has nothing to redo.
export function previousIndex(items, index) {
  for (let i = index - 1; i >= 0; i--) {
    if (items[i].type !== "rest") return i;
  }
  return Math.max(0, Math.min(index, items.length - 1));
}

// True when the item at `index` is the right side straight after the left
// side of the same set, so the player should cue the switch.
export function switchesSides(items, index) {
  const item = items[index];
  const before = items[index - 1];
  return item?.side === "right" && before?.side === "left" &&
    before.step_id === item.step_id && before.block.round === item.block.round;
}

// The main button's label. A set is done when you say so: reps, or a hold
// ended early. A lead-in or a rest can be cut short. Every countdown pauses
// with the Pause button beside it, or by tapping the time.
export function mainActionLabel(phase) {
  if (phase === "reps" || phase === "work") return "Done";
  return "Start";
}

// Seconds the button beside a countdown adds: more time to set up, or a
// longer rest. Nothing for the hold itself.
export function extraSeconds(phase) {
  return { lead: 10, rest: 15 }[phase] ?? 0;
}

// What a rest says about the exercise after it: "Set 2 of 3 · 8 reps ·
// 40 lb · left side first". `weight` is the weight as shown, if any.
export function upNextDetails(item, weight) {
  const bits = [setLabel(item)];
  bits.push(amountText({
    reps: item.mode === "timed" ? null : item.reps, seconds: item.mode === "timed" ? item.seconds : null,
    perSide: !!item.side, alternating: item.exercise?.alternating,
  }));
  bits.push(weight);
  if (item.side) bits.push(`${item.side} side first`);
  return bits.filter(Boolean).join(" · ");
}

// Seconds to get into position before a timed exercise: the lead-in chosen
// in Settings when moving on from another exercise (or at the start), and at
// most SHORT_LEAD_IN after a rest (set up during it) or between sets of the
// same exercise, such as the two sides of a stretch. When the exercise needs
// gear the one before it didn't, such as walking over to the hangboard, it is
// at least GEAR_LEAD_IN (at the start too); Start cuts it short.
const SHORT_LEAD_IN = 5;
export const GEAR_LEAD_IN = 15;

export function leadInSeconds(items, index, chosen) {
  const before = items[index - 1];
  if (before?.type === "rest") return Math.min(chosen, SHORT_LEAD_IN);
  if (needsNewGear(before, items[index])) return Math.max(chosen, GEAR_LEAD_IN);
  const again = before && before.exercise?.id === items[index].exercise?.id;
  return again ? Math.min(chosen, SHORT_LEAD_IN) : chosen;
}

// Whether an exercise needs equipment that the one before it didn't use (all
// of it at the start). Putting gear down doesn't count.
function needsNewGear(before, item) {
  return (item?.equipment ?? []).some((slug) => !before?.equipment?.includes(slug));
}

// Whether the exercise at `index` uses other equipment than the exercise
// before it (rests aside), so "With: ..." is only said when it changes.
export function equipmentChanges(items, index) {
  const before = items.slice(0, index).findLast((item) => item.type === "exercise");
  return !before || String(before.equipment ?? []) !== String(items[index]?.equipment ?? []);
}

// The exercise the program planned for this item, even when swapped.
export function plannedExercise(item) {
  return (item.planned ?? item).exercise;
}

// Swaps the planned exercise of the item at `index` for `alternative` (from
// /api/exercises/:id/alternatives), there and in every later set of it.
// Swapping back to the planned exercise puts the plan back. Earlier sets
// keep what was done. A per-side alternative for a two-sided exercise runs
// each set on both sides, with the same target per side; a two-sided one for
// a per-side exercise runs each set once. Reps change only between a
// per-side exercise and an alternating one (sideReps).
export function swapExercise(items, index, alternative) {
  return swapRun({ items }, index, alternative).items;
}

// swapExercise on a run, moving its `logged` marks (by item index) along
// when a swap changes how many items a set takes.
export function swapRun(run, index, alternative) {
  const plannedId = plannedExercise(run.items[index]).id;
  const items = [];
  const moved = {};
  run.items.forEach((item, i) => {
    moved[i] = items.length;
    if (i < index || item.type !== "exercise" || plannedExercise(item).id !== plannedId) return items.push(item);
    const swapped = swapItem(item, alternative);
    const planned = alternative.id === plannedExercise(item).id;
    const perSide = planned ? (item.planned ?? item).side != null : !!alternative.unilateral;
    for (const side of sidesFor(item.side, perSide, i === index)) items.push({ ...swapped, side });
  });
  moved[run.items.length] = items.length;
  const logged = {};
  for (const [i, status] of Object.entries(run.logged ?? {})) {
    if (moved[i] < moved[Number(i) + 1]) logged[moved[i]] = status;
  }
  return { ...run, items, logged };
}

// The sides an item becomes: a two-sided set splits into left and right, and
// a per-side set becomes one set on its left side. The right side of a set
// already started on the left stays, as the set's one remaining item.
function sidesFor(side, perSide, current) {
  if (perSide) return side == null ? ["left", "right"] : [side];
  if (side === "right" && !current) return [];
  return [null];
}

// The planned reps as the alternative counts them: a per-side exercise's
// reps are for each side and an alternating one's for both sides together,
// so 8 a side become 16 alternating, and 10 alternating 5 a side (an odd
// count rounds up). Only the left side's item stands for a whole set: a
// right side kept after its left was done is half a set, and keeps its reps.
function sideReps(planned, alternative) {
  if (planned.reps == null) return null;
  if (planned.side === "left" && alternative.alternating) return planned.reps * 2;
  if (planned.exercise.alternating && alternative.unilateral) return Math.ceil(planned.reps / 2);
  return planned.reps;
}

function swapItem(item, alternative) {
  const planned = item.planned ?? pick(item);
  if (alternative.id === planned.exercise.id) {
    const { planned: _, ...rest } = item;
    return { ...rest, ...planned };
  }

  const mode = modeFor(planned.mode, alternative);
  const sameMode = mode === planned.mode;
  const { weight, weight_unit: unit, allowed_weights: allowed, ...exercise } = alternative;
  // No weight carries over to one the server says takes none.
  const carried = weight || unit === null ? null : carriedWeight(planned, alternative);
  // Whether it takes a weight, set or not (an older server sends no unit).
  const weightUnit = carried?.unit ?? unit ?? weight?.unit ?? null;
  return {
    ...item,
    planned,
    exercise,
    mode,
    reps: mode === "reps" ? (sameMode ? sideReps(planned, alternative) : null) ?? alternative.default_reps ?? null : null,
    seconds: mode === "timed" ? (sameMode ? planned.seconds : null) ?? alternative.default_seconds ?? null : null,
    tempo: sameMode ? planned.tempo : null,
    weight: weight ?? carried,
    weight_unit: weightUnit,
    weights_held: weightUnit ? alternative.weights_held ?? 1 : null,
    allowed_weights: (carried ? planned.allowed_weights : weightUnit && allowed) ?? null,
    suggestion: null,
    note: null,
    equipment: alternative.equipment,
  };
}

// What a swap changes, kept so it can be undone.
function pick(item) {
  const { exercise, mode, reps, seconds, tempo, weight, weight_unit, weights_held, allowed_weights, seed_weight, suggestion, note, equipment, side } = item;
  return { exercise, mode, reps, seconds, tempo, weight, weight_unit, weights_held, allowed_weights, seed_weight, suggestion, note, equipment, side };
}

// An exercise with only a time is held; one with only reps is counted;
// otherwise it follows the step.
function modeFor(plannedMode, exercise) {
  if (exercise.default_seconds && !exercise.default_reps) return "timed";
  if (exercise.default_reps && !exercise.default_seconds) return "reps";
  return plannedMode;
}

// With no weight of its own, an alternative lifted with the same equipment
// starts at the planned weight.
function carriedWeight(planned, alternative) {
  if (!planned.weight) return null;
  const shared = (alternative.equipment ?? []).filter((e) => planned.equipment?.includes(e));
  return shared.length ? planned.weight : null;
}

// What to do on load with a run kept from before: "resume" it straight away
// when it was touched within `withinMs` (a reload or app switch mid-workout),
// "drop" an old one that never got past Get ready (nothing is on the server
// yet), and "ask" about any other old one. "none" when there is no run.
export function resumeChoice(run, now, withinMs) {
  if (!run) return "none";
  const touched = run.touchedAt ?? run.startedAt ?? 0;
  if (now - touched < withinMs) return "resume";
  return run.stage === "ready" ? "drop" : "ask";
}

// How far a run got: exercises in the plan, exercises with a set done and
// sets done. A swapped exercise counts for the one it stands in for.
export function sessionProgress(run) {
  const exercises = new Set();
  const done = new Set();
  let sets = 0;
  run.items.forEach((item, i) => {
    if (item.type !== "exercise") return;
    const id = plannedExercise(item).id;
    exercises.add(id);
    if (run.logged?.[i] !== "done") return;
    done.add(id);
    sets += 1;
  });
  return { exercises: exercises.size, done: done.size, sets };
}

// True when ending at `index` leaves part of the main workout undone: the
// player has not got past its last item. Ending in the cool-down is done.
export function endsEarly(items, index) {
  const lastMain = items.findLastIndex((item) => item.workout?.kind === "workout");
  return index <= lastMain;
}

// The server's logged sets ({ step_id, set_number, side, status }) as the
// run keeps them: item index -> status.
export function loggedFromServer(items, sets = []) {
  const key = (stepId, round, side) => `${stepId}:${round}:${side ?? ""}`;
  const statuses = new Map(sets.map((s) => [key(s.step_id, s.set_number, s.side), s.status]));
  const logged = {};
  items.forEach((item, i) => {
    if (item.type !== "exercise") return;
    const status = statuses.get(key(item.step_id, item.block.round, item.side));
    if (status) logged[i] = status;
  });
  return logged;
}

// Where to pick a session up: the first exercise after the last set logged,
// or the start when nothing was logged (or nothing is left).
export function pickUpIndex(items, logged) {
  const indexes = Object.keys(logged ?? {}).map(Number);
  if (indexes.length === 0) return 0;
  const next = items.findIndex((item, i) => i > Math.max(...indexes) && item.type === "exercise");
  return next === -1 ? 0 : next;
}

// The few alternatives worth offering first: those training the same or a
// similar movement (at most SHORTLIST), else the best few of any; the rest
// wait behind "Show everything". Exercises the session already has go last.
export const SHORTLIST = 5;

export function shortlist(alternatives, inSession = new Set()) {
  const ordered = [...alternatives.filter((e) => !inSession.has(e.id)), ...alternatives.filter((e) => inSession.has(e.id))];
  const good = ordered.filter((e) => e.match === "same" || e.match === "similar");
  const best = (good.length ? good : ordered).slice(0, SHORTLIST);
  return { best, rest: ordered.filter((e) => !best.includes(e)) };
}

// The index just past the part (warm-up, workout or cool-down) the item at
// `index` belongs to.
export function partEnd(items, index) {
  const part = items[index]?.workout?.id;
  let end = index;
  while (end < items.length && items[end].workout?.id === part) end += 1;
  return end;
}

// "Set 2 of 3" for a block of more than one round, else nothing.
export function setLabel(item) {
  const { round, rounds } = item.block;
  return rounds > 1 ? `Set ${round} of ${rounds}` : "";
}

// Mirrors Step#estimated_seconds: a rep takes its tempo's seconds (or
// SECONDS_PER_REP), and each step gets SETUP_SECONDS, split between sides.
const SECONDS_PER_REP = 3;
const SETUP_SECONDS = 10;

function itemSeconds(item) {
  if (item.type === "rest") return item.seconds;
  const perRep = item.tempo ? [...item.tempo].reduce((sum, d) => sum + (Number(d) || 0), 0) : SECONDS_PER_REP;
  const work = item.mode === "timed" ? item.seconds ?? 0 : (item.reps || 1) * perRep;
  return work + (item.side ? SETUP_SECONDS / 2 : SETUP_SECONDS);
}

// Whole minutes the screens from `index` on are expected to take.
export function minutesLeft(items, index) {
  const seconds = items.slice(index).reduce((sum, item) => sum + itemSeconds(item), 0);
  return Math.ceil(seconds / 60);
}

// A tempo written out: "2111" -> "2 s down · 1 s pause · 1 s up · 1 s at
// the top". The digits are the lowering, the pause at the bottom, the lift
// and the pause at the top; a 0 lift (or X) is as fast as you can.
export function tempoText(tempo) {
  const digits = String(tempo ?? "").toUpperCase();
  if (!/^[\dX]{3,4}$/.test(digits)) return tempo ? `tempo ${tempo}` : "";
  const [down, bottom, up, top] = [...digits].map((d) => (d === "X" ? 0 : Number(d)));
  const bits = [`${down} s down`];
  if (bottom) bits.push(`${bottom} s pause`);
  bits.push(up ? `${up} s up` : "up fast");
  if (top) bits.push(`${top} s at the top`);
  return bits.join(" · ");
}

// What a finished run did: sets done of those planned, sets skipped and the
// exercises swapped for another, from the sets logged.
export function finishSummary(run) {
  const exercises = run.items.map((item, i) => [item, i]).filter(([item]) => item.type === "exercise");
  const count = (status) => exercises.filter(([, i]) => run.logged?.[i] === status).length;
  const swapped = new Set(exercises.filter(([item, i]) => item.planned && run.logged?.[i] === "done").map(([item]) => plannedExercise(item).id));
  return { ...sessionProgress(run), planned: exercises.length, skipped: count("skipped"), swaps: swapped.size };
}

// How hard a session felt, as RPE values with words to anchor them.
export const RPE_ANCHORS = [
  { rpe: 3, label: "Easy" },
  { rpe: 5, label: "Steady" },
  { rpe: 7, label: "Hard" },
  { rpe: 9, label: "All out" },
];
