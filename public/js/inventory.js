// The weights field on the equipment page: what the user types ("10, 20") to
// the list the API stores, and back. Kept free of the DOM for testing.

// Returns { weights } or { error }. Weights are sorted, without repeats.
export function parseWeights(text) {
  const parts = String(text ?? "").split(/[\s,]+/).filter(Boolean);
  const numbers = parts.map(Number);
  const bad = parts.filter((_, i) => !(numbers[i] > 0));
  if (bad.length) return { error: `Not a weight: ${bad.join(", ")}` };
  return { weights: [...new Set(numbers)].sort((a, b) => a - b) };
}

export function formatWeights(weights) {
  return (weights ?? []).join(", ");
}

// Exercises the inventory covers: everything an exercise needs is owned.
export function doable(exercise, owned) {
  return (exercise.equipment ?? []).every((slug) => owned.has(slug));
}
