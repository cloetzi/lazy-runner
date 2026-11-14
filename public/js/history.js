// Pure helpers for History: how one session's sets of an exercise read (in
// the exercise history and a past session), and how a session is summed up.
import { formatWeight, sameShownWeight } from "./weights.js";

// "3 × 8 @ 35 lb", or "8, 8, 6 @ 40 lb" when the reps differ, with a part per
// weight used. Per-side sets read "8 each side", or "8/7" when the sides differ.
// Weights are shown in `unit` (lb or kg) when one is given.
export function setsSummary(sets, unit) {
  const groups = [];
  for (const set of collapseSides(sets)) {
    const last = groups.at(-1);
    if (last && sameShownWeight(last.weight, set.weight, unit)) last.values.push(set.value);
    else groups.push({ weight: set.weight, values: [set.value] });
  }
  const perSide = sets.some((set) => set.side);
  return groups.map(({ weight, values }) => {
    const same = values.every((value) => value === values[0]);
    let text = same && values.length > 1 ? `${values.length} × ${values[0]}` : values.join(", ");
    if (perSide && same && !values[0].includes("/")) text += " each side";
    return weight ? `${text} @ ${formatWeight(weight, unit)}` : text;
  }).join(" · ");
}

const FEEDBACK = { too_easy: "too easy", right: "felt right", too_hard: "too hard" };

// The line under a session: "26 min · felt right · RPE 6", or what is known
// of it. `minutes` is null when the start or finish was not recorded.
export function sessionSummary(session) {
  const bits = [];
  if (session.completion?.ended_early) bits.push("ended early");
  else if (session.status !== "done") bits.push(session.status.replace("_", " "));
  if (session.minutes) bits.push(`${session.minutes} min`);
  else if (session.sets_done != null) bits.push(`${session.sets_done} ${session.sets_done === 1 ? "set" : "sets"}`);
  const feedback = FEEDBACK[session.completion?.feedback];
  if (feedback) bits.push(feedback);
  if (session.completion?.rpe) bits.push(`RPE ${session.completion.rpe}`);
  return bits.join(" · ");
}

// One exercise of a past session (GET /api/sessions/:id): what was done and
// how many sets were skipped. `done` is "" when every set was skipped.
export function exerciseSummary(entry, unit) {
  const done = entry.sets.filter((set) => set.status === "done");
  // The two sides of a set count as one.
  const skipped = new Set(entry.sets.filter((set) => set.status !== "done").map((set) => set.set_number)).size;
  return { done: done.length ? setsSummary(done, unit) : "", skipped };
}

// One entry per set number, the left and right sides of it together.
function collapseSides(sets) {
  const byNumber = new Map();
  for (const set of sets) {
    const entry = byNumber.get(set.set_number) ?? { weight: set.weight, sides: [] };
    entry.sides.push(amount(set));
    byNumber.set(set.set_number, entry);
  }
  return [...byNumber.values()].map(({ weight, sides }) => ({
    weight,
    value: sides.every((side) => side === sides[0]) ? sides[0] : sides.join("/"),
  }));
}

// A hold ended early reads "32 of 45 s".
function amount(set) {
  if (set.reps != null) return String(set.reps);
  const target = set.target?.seconds;
  if (set.seconds != null && target && set.seconds < target) return `${set.seconds} of ${target} s`;
  if (set.seconds != null) return `${set.seconds} s`;
  return "done";
}
