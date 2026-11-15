// Pure helpers for the Exercises page: finding an exercise by text, body area
// and equipment, and what a card says about you (when you last did it, which
// workouts use it). No DOM; library.js draws the page.
import { formatWeight } from "./weights.js";
import { doable } from "./inventory.js";

// The body areas exercises are tagged with in db/seeds/exercises.yml.
export const AREAS = [
  { id: "legs", label: "Legs" },
  { id: "hips", label: "Hips" },
  { id: "core", label: "Core" },
  { id: "upper_body", label: "Upper body" },
];

// "bodyweight" stands for exercises that need nothing.
export const BODYWEIGHT = "bodyweight";

// The generic weights (`any_weight` items of GET /api/equipment) that the
// equipment `slug` stands in for: all of them for gear in set weights, such
// as dumbbells, since an exercise that needs just a weight can be done with it.
export function standIns(slug, inventory = []) {
  const item = inventory.find((entry) => entry.slug === slug);
  if (!item?.unit || item.any_weight) return [];
  return inventory.filter((entry) => entry.any_weight).map((entry) => entry.slug);
}

// The equipment worth offering as a filter: what some exercise needs, and
// with the generic weight among it, all the gear in set weights.
export function gearUsed(exercises, inventory = []) {
  const used = new Set(exercises.flatMap((e) => e.equipment ?? []));
  if (inventory.some((item) => item.any_weight && used.has(item.slug))) {
    for (const item of inventory) if (item.unit) used.add(item.slug);
  }
  return used;
}

// Whether an exercise matches every filter given: `query` words (each must
// appear in the name, category, areas, equipment or cues), an `area`, an
// `equipment` slug (or BODYWEIGHT; with `standIns`, the generic weights it
// stands in for count too) and, with `owned`, the equipment owned.
export function matches(exercise, { query = "", area = "", equipment = "", standIns = [], owned = null, names = {} } = {}) {
  if (area && !(exercise.areas ?? []).includes(area)) return false;
  const needs = exercise.equipment ?? [];
  if (equipment === BODYWEIGHT && needs.length > 0) return false;
  if (equipment && equipment !== BODYWEIGHT && ![equipment, ...standIns].some((slug) => needs.includes(slug))) return false;
  if (owned && !doable(exercise, owned)) return false;
  const words = normalise(query).split(" ").filter(Boolean);
  if (words.length === 0) return true;
  const text = normalise([
    exercise.name, exercise.category, ...(exercise.areas ?? []).map(areaLabel),
    ...needs.map((slug) => names[slug] ?? slug), ...(exercise.cues ?? []),
  ].join(" "));
  return words.every((word) => text.includes(word));
}

// The header line: "33 exercises", "28 with your gear, 5 more with other
// gear" (`more`: the exercises left out by what you own), or "4 of 28 …"
// when a search or filter narrows it. "What I own" with nothing owned yet
// is the exercises that need no gear. library.js links "your gear" to Equipment.
export function countLine(shown, total, { owned = false, filtered = false, ownsNothing = false, more = 0 } = {}) {
  const of = owned && ownsNothing ? `${total} that need no gear`
    : owned ? `${total} with your gear` : `${total} ${total === 1 ? "exercise" : "exercises"}`;
  if (filtered) return `${shown} of ${of}`;
  return owned && !ownsNothing && more > 0 ? `${of}, ${more} more with other gear` : of;
}

// "Last: Thu, Oct 16 · 40 lb × 8" from an entry of GET /api/history/exercises.
export function lastLine(logged, unit, formatDate) {
  if (!logged) return "";
  const set = logged.last_set;
  const amount = set && (set.reps != null ? `${set.reps}` : set.seconds != null ? `${set.seconds} s` : "");
  const what = set?.weight && amount ? `${formatWeight(set.weight, unit)} × ${amount}` : amount;
  return [`Last: ${formatDate(logged.last_date)}`, what].filter(Boolean).join(" · ");
}

// Titles of the workouts that use an exercise, from GET /api/workouts, main
// workouts first: "In: Workout 1, Workout 2".
export function usedInLine(programs, exerciseId) {
  const workouts = (programs ?? []).flatMap((program) => program.workouts)
    .filter((workout) => (workout.exercise_ids ?? []).includes(exerciseId))
    .sort((a, b) => (a.kind === "workout" ? 0 : 1) - (b.kind === "workout" ? 0 : 1));
  const titles = [...new Set(workouts.map((workout) => workout.title))];
  return titles.length ? `In: ${titles.join(", ")}` : "";
}

export function areaLabel(id) {
  return AREAS.find((area) => area.id === id)?.label ?? id;
}

function normalise(text) {
  return String(text).toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9]+/g, " ").trim();
}
