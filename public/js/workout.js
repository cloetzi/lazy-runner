// Pure helpers for the workout view (GET /api/workouts/:id): how a block and
// a step read, and changing an exercise's weight everywhere it appears.

import { inUnit, sameGearWeight } from "./weights.js";

// "Block A" for a lettered block, a named one ("Warm-up") as it is.
export function blockName(label) {
  return /^[A-Z]$/.test(label) ? `Block ${label}` : label;
}

export function blockSummary(block) {
  const bits = [block.rounds === 1 ? "1 round" : `${block.rounds} rounds`];
  if (block.rounds > 1 && block.rest_seconds > 0) bits.push(`${block.rest_seconds} s rest`);
  return bits.join(" · ");
}

// How much a step asks for, saying how the sides count: a per-side step's
// reps or seconds are for each side ("8 reps each side"), an alternating
// exercise's reps are both sides together ("10 reps in total, 5 each side").
export function amountText({ reps, seconds, perSide, alternating }) {
  const amount = reps ? `${reps} reps` : seconds ? `${seconds} s` : "";
  if (perSide) return amount ? `${amount} each side` : "each side";
  if (!alternating) return amount;
  if (reps) return `${amount} ${alternatingText(reps)}`;
  return amount ? `${amount}, alternating sides` : "alternating sides";
}

// How an alternating exercise's reps split, also the player's line under "10×".
export function alternatingText(reps) {
  return reps % 2 === 0 ? `in total, ${reps / 2} each side` : "in total, alternating sides";
}

export function stepSummary(step) {
  const { reps, seconds } = step.target;
  const bits = [];
  const amount = amountText({ reps, seconds, perSide: step.per_side, alternating: step.exercise?.alternating });
  if (amount) bits.push(amount);
  if (step.tempo) bits.push(`tempo ${step.tempo}`);
  if (step.note) bits.push(step.note);
  return bits.join(" · ");
}

// A remembered weight belongs to the exercise, so every step of it changes.
export function setWeight(workout, exerciseId, weight) {
  for (const step of workout.blocks.flatMap((block) => block.steps)) {
    if (step.exercise.id !== exerciseId) continue;
    // Each step keeps it in its own unit (that of the gear it is done with).
    step.target.weight = weight && { ...inUnit(weight, step.weight_unit) };
  }
  return workout;
}

// The kinds of the parts (warm-up, workout, cool-down) a session runs. The
// workout itself always runs, as does a warm-up or cool-down started on its
// own; `framing` says whether the warm-up and the cool-down framing a workout
// do ({ warmup: false } leaves the warm-up out).
export function includedKinds(parts, framing = {}) {
  const kept = (part) => parts.length === 1 || part.kind === "workout" || framing[part.kind] !== false;
  return parts.filter(kept).map((part) => part.kind);
}

// The framing a session planned with its own parts asks for: its warm-up
// and cool-down run only when they are among them. Null when it names none.
export function framingFor(parts) {
  if (!parts) return null;
  return { warmup: parts.includes("warmup"), cooldown: parts.includes("cooldown") };
}

// A player plan cut down to the parts of `kinds`: their screens, and the
// equipment and weight targets those screens need.
export function framePlan(plan, kinds) {
  const items = plan.items.filter((item) => kinds.includes(item.workout.kind));
  const exercises = new Set(items.filter((item) => item.type === "exercise").map((item) => item.exercise.id));
  const equipment = [...new Set(items.flatMap((item) => item.equipment ?? []))];
  return { items, equipment, targets: plan.targets.filter((target) => exercises.has(target.exercise.id)) };
}

// The gear that carries `weight` for a step, target or player item: for one
// done with any weight, the owned item that has that weight (the plan says
// which, `any_weight.carriers`), so the name follows the weight as it steps;
// otherwise the gear the plan named. Null with no gear named.
export function carrierOf(thing, weight = thing.weight) {
  const carriers = thing.any_weight?.carriers;
  if (!carriers) return thing.weight_equipment ?? null;
  if (!weight) return thing.any_weight.slug;
  const unit = thing.weight_unit ?? weight.unit;
  return carriers.find((carrier) => sameGearWeight({ value: carrier.value, unit }, weight))?.equipment ?? thing.any_weight.slug;
}

// What an item is done with, the generic weight named as the gear that
// carries it: what the user actually picks up.
export function gearOf(item) {
  const generic = item.any_weight?.slug;
  return [...new Set((item.equipment ?? []).map((slug) => slug === generic ? carrierOf(item) : slug))];
}

// What to put next to the mat, from a framed plan: one row per piece of
// equipment the session needs, in order of first use, each with the
// exercises it is for. Gear that carries a weight gets a row per weight (as
// many as the most any exercise holds), and one for its exercises with no
// weight set yet. An exercise done with any weight is listed under the gear
// that carries its weight, not again under "Any weight". Weights for steps
// done with no gear named go last, under equipment null.
export function gearList(items, targets) {
  const uses = new Map(); // slug -> exercise names, in order
  for (const item of items) {
    if (item.type !== "exercise") continue;
    for (const slug of item.equipment ?? []) {
      const names = uses.get(slug) ?? uses.set(slug, []).get(slug);
      if (!names.includes(item.exercise.name)) names.push(item.exercise.name);
    }
  }
  const carried = new Map(); // slug -> rows for its weighted exercises
  const elsewhere = new Map(); // generic slug -> names carried by real gear
  const carriers = new Map(); // generic slug -> the real gear carrying them
  for (const target of targets) {
    // A weight with no gear named (a weighted push-up) is picked up as "a
    // weight"; without one there is nothing to pick up.
    const slug = (target.any_weight ? carrierOf(target) : target.weight_equipment) ?? target.equipment?.[0] ?? null;
    if (!slug && !target.weight) continue;
    if (!slug) uses.set(null, uses.get(null) ?? []);
    const generic = target.any_weight?.slug;
    if (generic && generic !== slug) {
      (elsewhere.get(generic) ?? elsewhere.set(generic, new Set()).get(generic)).add(target.exercise.name);
      (carriers.get(generic) ?? carriers.set(generic, new Set()).get(generic)).add(slug);
    }
    const rows = carried.get(slug) ?? carried.set(slug, []).get(slug);
    const held = target.weights_held ?? 1;
    const weight = target.weight ?? null;
    // One row per weight: a pair is fetched either way.
    const same = (row) => weight
      ? row.load && row.load.weight.value === weight.value && row.load.weight.unit === weight.unit
      : row.unset;
    const row = rows.find(same) ?? rows[rows.push({ equipment: slug, load: weight && { held, weight }, unset: !weight, exercises: [] }) - 1];
    if (row.load) row.load.held = Math.max(row.load.held, held);
    row.exercises.push(target.exercise.name);
  }
  // Gear that only carries any weight takes the generic's place in the order.
  const order = [...uses.keys()].flatMap((slug) => [...(carriers.get(slug) ?? [])].filter((c) => !uses.has(c)).concat([slug]));
  return [...new Set(order)].flatMap((slug) => {
    const names = uses.get(slug) ?? [];
    // Loads to pick up first, then what has no weight set yet.
    const rows = (carried.get(slug) ?? []).sort((a, b) => a.unset - b.unset);
    const covered = new Set([...rows.flatMap((row) => row.exercises), ...(elsewhere.get(slug) ?? [])]);
    const rest = names.filter((name) => !covered.has(name));
    if (!rows.length && !rest.length) return [];
    return rest.length || !rows.length ? [...rows, { equipment: slug, load: null, unset: false, exercises: rest }] : rows;
  });
}
