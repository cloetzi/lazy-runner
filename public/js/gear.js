// Owned and missing gear, wherever gear is named: the workout card, the
// workout view, Get ready, the editor's picker, the example programs and the
// Equipment page. A missing item is marked with a dashed outline, a cross and
// the words "not yours yet", never by colour alone. Kept free of the DOM.
import { html, icon } from "./html.js";

// The slugs /api/equipment says the user owns, a generic weight included when
// they own gear in set weights. Null for no answer, so nothing is marked missing.
export function ownedSlugs(inventory) {
  return Array.isArray(inventory) ? new Set(inventory.filter((item) => item.owned).map((item) => item.slug)) : null;
}

// The slugs among `slugs` the user doesn't own; none when that isn't known.
export function missingGear(slugs, owned) {
  return owned ? [...new Set(slugs ?? [])].filter((slug) => !owned.has(slug)) : [];
}

// The gear as chips: `names(slugs)` gives their display names. A missing one
// reads "Kettlebell, not yours yet" (the comma for screen readers only);
// with `tick`, an owned one has a tick and reads "Dumbbells, yours".
export function gearChips(slugs, { names, owned, label = "Equipment", classes = "equipment-list small", tick = false }) {
  const list = slugs ?? [];
  if (list.length === 0) return "";
  const shown = names(list);
  const missing = new Set(missingGear(list, owned));
  return html`<ul class="${classes}" aria-label="${label}">${list.map((slug, i) => missing.has(slug)
    ? html`<li class="gear-missing">${icon("close")}${shown[i]}<span class="gear-note"><span class="visually-hidden">,</span> not yours yet</span></li>`
    : tick ? html`<li>${icon("check")}${shown[i]}<span class="visually-hidden">, yours</span></li>` : html`<li>${shown[i]}</li>`)}</ul>`;
}

// "Kettlebell and Stability ball": names in a sentence.
export function nameList(names) {
  if (names.length <= 1) return names.join("");
  return `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`;
}

// What an item of the inventory unlocks: the exercises that need it (gear
// in set weights also counts those needing just a weight, which it does
// for) and the user's main workouts that use it.
// `exercises` from /api/exercises, `programs` from /api/workouts.
export function unlocks(item, { exercises = [], programs = [], inventory = [] } = {}) {
  const slugs = new Set([item.slug]);
  // Gear in set weights also does for an exercise that needs just a weight.
  if (item.unit && !item.any_weight) for (const other of inventory) if (other.any_weight) slugs.add(other.slug);
  const needing = exercises.filter((exercise) => (exercise.equipment ?? []).some((slug) => slugs.has(slug)));
  const workouts = programs.flatMap((program) => program.workouts)
    .filter((workout) => workout.kind === "workout" && (workout.equipment ?? []).some((slug) => slugs.has(slug)))
    .map((workout) => workout.title);
  return { exercises: needing.length, workouts: [...new Set(workouts)] };
}

// "4 exercises, used in Session A and Session B", or "No exercise needs it yet".
export function unlocksLine({ exercises, workouts }) {
  if (exercises === 0) return "No exercise needs it yet";
  const count = `${exercises} ${exercises === 1 ? "exercise" : "exercises"}`;
  return workouts.length ? `${count}, used in ${nameList(workouts)}` : count;
}

// Example programs best fit first: the fewest exercises needing gear the
// user lacks, the order given otherwise.
export function byFit(examples) {
  return examples.map((example, i) => [example, i])
    .sort(([a, i], [b, j]) => (a.missing_exercises ?? 0) - (b.missing_exercises ?? 0) || i - j)
    .map(([example]) => example);
}

// "Fits your gear", or "3 exercises need gear you don't have".
export function fitLine(example) {
  const missing = example.missing_exercises ?? 0;
  if (missing === 0) return (example.gear ?? []).length ? "Fits your gear" : "Needs no gear";
  return `${missing} ${missing === 1 ? "exercise needs" : "exercises need"} gear you don't have`;
}
