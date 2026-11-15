// The weights of a piece of gear, entered one at a time on the equipment
// list (equipment-list.js) and shown as chips. Kept free of the DOM for
// testing.

// One weight as typed: "20", "2.5" or "2,5", or with the row's unit after
// it ("20lb", "16 kg"). The other unit is refused rather than read as this
// one. Returns { weight } or { error }.
export function parseWeight(text, unit) {
  const typed = String(text ?? "").trim();
  const match = typed.match(/^(\d+(?:[.,]\d{1,2})?)\s*(lbs?|kgs?)?$/i);
  const weight = match && Number(match[1].replace(",", "."));
  if (!(weight > 0)) return { error: `"${typed}" is not a weight: type a number, such as 20.` };
  const given = match[2]?.toLowerCase().replace(/s$/, "");
  if (given && unit && given !== unit) return { error: `These are in ${unit}: switch to ${given} first, or type the weight in ${unit}.` };
  return { weight };
}

// The list with `weight` in it, sorted and without repeats.
export function withWeight(weights, weight) {
  return [...new Set([...(weights ?? []), weight])].sort((a, b) => a - b);
}

// Common sizes, by kind of gear and unit, offered as one-tap adds when the
// list doesn't have them yet. Gear other than kettlebells sizes like dumbbells.
export const COMMON_WEIGHTS = {
  kettlebell: { lb: [10, 15, 20, 25, 30, 35, 40, 45, 50], kg: [4, 6, 8, 12, 16, 20, 24] },
  dumbbell: { lb: [5, 8, 10, 12, 15, 20, 25, 30], kg: [1, 2, 2.5, 4, 5, 7.5, 10, 12.5] },
};

export function quickWeights(slug, unit, weights) {
  const sizes = (COMMON_WEIGHTS[slug] ?? COMMON_WEIGHTS.dumbbell)[unit] ?? [];
  return sizes.filter((weight) => !(weights ?? []).includes(weight));
}

// Exercises the inventory covers: everything an exercise needs is owned.
export function doable(exercise, owned) {
  return (exercise.equipment ?? []).every((slug) => owned.has(slug));
}
