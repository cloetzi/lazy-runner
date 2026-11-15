import { test } from "node:test";
import assert from "node:assert/strict";
import { previousIndex, switchesSides, mainActionLabel, stepAnnouncement, spokenTarget, spokenWeight, tapAccepted, TAP_GUARD_MS, holdStatus, MIN_HOLD_SECONDS, unloggedExercises, plannedExercise, swapExercise, swapRun, shortlist, SHORTLIST, resumeChoice, sessionProgress, endsEarly, loggedFromServer, pickUpIndex, partEnd, setLabel, minutesLeft, tempoText, leadInSeconds, GEAR_LEAD_IN, extraSeconds, upNextDetails, equipmentChanges, finishSummary, framingLine, itemPart } from "../../public/js/player.js";

const squat = { id: 1, name: "Goblet squat", equipment: ["dumbbell"], default_reps: 8, default_seconds: null };
const deadlift = { id: 2, name: "Straight-leg deadlift", equipment: ["dumbbell"], default_reps: 12, default_seconds: null };
const plank = { id: 3, name: "Plank", equipment: ["mat"], default_reps: null, default_seconds: 60 };

const set = (exercise, round, overrides = {}) => ({
  type: "exercise", mode: "reps", step_id: 10, side: null, block: { label: "A", round, rounds: 2 },
  exercise, reps: 8, seconds: null, tempo: "3010", weight: { value: 40, unit: "lb" }, weight_unit: "lb", weights_held: 1, seed_weight: { value: 40, unit: "lb" },
  allowed_weights: [20, 40], note: null, equipment: ["dumbbell"],
  ...overrides,
});
const rest = (round) => ({ type: "rest", mode: "timed", block: { label: "A", round, rounds: 2 }, seconds: 60 });

test("goes back to the step before, skipping rests", () => {
  const items = [set(squat, 1), rest(1), set(squat, 2)];

  assert.equal(previousIndex(items, 2), 0);
  assert.equal(previousIndex(items, 1), 0);
  assert.equal(previousIndex(items, 0), 0);
});

test("cues a switch only from the left side to the right side of the same set", () => {
  const left = set(squat, 1, { side: "left" });
  const right = set(squat, 1, { side: "right" });
  const items = [left, right, set(squat, 2, { side: "right" }), set(squat, 2, { side: "left" }), set(squat, 2, { side: "right", step_id: 11 })];

  assert.equal(switchesSides(items, 1), true);
  assert.equal(switchesSides(items, 0), false);
  assert.equal(switchesSides(items, 2), false);
  assert.equal(switchesSides(items, 4), false);
});

test("finishes a set with Done and cuts a lead-in or a rest short", () => {
  assert.equal(mainActionLabel("reps"), "Done");
  assert.equal(mainActionLabel("work"), "Done");
  assert.equal(mainActionLabel("lead"), "Start");
  assert.equal(mainActionLabel("rest", set(squat, 2)), "Start set 2 now");
  assert.equal(mainActionLabel("rest", { ...set(squat, 1), block: { label: "B", round: 1, rounds: 1 } }), "End rest now");
  // A first set comes after another exercise or block: not a "set 1" to start again.
  assert.equal(mainActionLabel("rest", { ...set(squat, 1), block: { label: "B", round: 1, rounds: 3 } }), "End rest now");
  assert.equal(mainActionLabel("rest"), "End rest now");
});

test("ignores the main button for a moment after its meaning changes", () => {
  assert.equal(TAP_GUARD_MS, 700);
  assert.equal(tapAccepted(null, 5), true);
  assert.equal(tapAccepted(1000, 1000), false);
  assert.equal(tapAccepted(1000, 1699), false);
  assert.equal(tapAccepted(1000, 1700), true);
  assert.equal(tapAccepted(1000, 5000), true);
});

test("logs a hold ended in its first seconds as skipped, not done", () => {
  assert.equal(MIN_HOLD_SECONDS, 3);
  assert.equal(holdStatus(0, 30), "skipped");
  assert.equal(holdStatus(2, 30), "skipped");
  assert.equal(holdStatus(3, 30), "done");
  assert.equal(holdStatus(25, 30), "done");
  // A hold shorter than the minimum counts once it is all held.
  assert.equal(holdStatus(2, 2), "done");
  assert.equal(holdStatus(1, 2), "skipped");
});

test("lists the exercise screens a skipped part leaves unlogged", () => {
  const items = [set(squat, 1), { type: "rest", seconds: 60 }, set(squat, 2), set(deadlift, 1), set(plank, 1)];
  assert.deepEqual(unloggedExercises(items, 0, 4), [0, 2, 3]);
  assert.deepEqual(unloggedExercises(items, 0, 4, { 0: "done" }), [2, 3]);
  assert.deepEqual(unloggedExercises(items, 2, 2), []);
});

test("adds more time to a lead-in or a rest, never to a hold", () => {
  assert.equal(extraSeconds("lead"), 10);
  assert.equal(extraSeconds("rest"), 15);
  assert.equal(extraSeconds("work"), 0);
  assert.equal(extraSeconds("reps"), 0);
});

test("says what comes after a rest", () => {
  assert.equal(upNextDetails(set(squat, 2, { side: "left" }), "40 lb"), "Set 2 of 2 · 8 reps each side · 40 lb · left side first");
  assert.equal(upNextDetails(set({ ...squat, alternating: true }, 1, { reps: 10, block: { round: 1, rounds: 1 } }), null), "10 reps in total, 5 each side");
  assert.equal(upNextDetails(set(plank, 1, { mode: "timed", reps: null, seconds: 45, block: { round: 1, rounds: 1 } }), null), "45 s");
});

test("uses the chosen lead-in when moving on with the same gear, and at most 5 s after a rest or between sets", () => {
  const left = set(plank, 1, { side: "left", mode: "timed" });
  const right = set(plank, 1, { side: "right", mode: "timed" });
  const items = [left, right, set(squat, 1), set(plank, 2, { mode: "timed" }), rest(2), set(plank, 2, { mode: "timed" })];

  assert.equal(leadInSeconds(items, 1, 10), 5);
  assert.equal(leadInSeconds(items, 3, 10), 10);
  assert.equal(leadInSeconds(items, 5, 10), 5);
  assert.equal(leadInSeconds(items, 3, 3), 3);
  assert.equal(leadInSeconds(items, 5, 3), 3);
});

test("gives longer to get into position when new gear is needed", () => {
  const squat1 = set(squat, 1);
  const hang = (round, overrides) => set(plank, round, { mode: "timed", equipment: ["hangboard"], ...overrides });
  const bodyweight = set(plank, 1, { mode: "timed", equipment: [] });
  const benchRow = set(deadlift, 1, { equipment: ["dumbbell", "bench"] });
  const dumbbellHold = set(plank, 1, { mode: "timed", equipment: ["dumbbell"] });
  const items = [hang(1), squat1, hang(1), rest(1), hang(2), squat1, bodyweight, benchRow, dumbbellHold];
  assert.equal(GEAR_LEAD_IN, 15);

  // At the start the gear still has to be fetched, unless there is none.
  assert.equal(leadInSeconds(items, 0, 5), GEAR_LEAD_IN);
  assert.equal(leadInSeconds([bodyweight], 0, 3), 3);
  assert.equal(leadInSeconds(items, 2, 3), GEAR_LEAD_IN);
  // The rest screen names the gear: set up during it.
  assert.equal(leadInSeconds(items, 4, 10), 5);
  // Nothing to pick up, or only gear put down: the chosen lead-in.
  assert.equal(leadInSeconds(items, 6, 5), 5);
  assert.equal(leadInSeconds(items, 8, 5), 5);
});

test("swaps the exercise from the current set on, keeping earlier sets", () => {
  const items = [set(squat, 1), rest(1), set(squat, 2), set(plank, 2, { step_id: 12 })];
  const swapped = swapExercise(items, 2, { ...deadlift, weight: { value: 30, unit: "lb" } });

  assert.equal(swapped[0].exercise.id, squat.id);
  assert.equal(swapped[2].exercise.id, deadlift.id);
  assert.equal(swapped[2].exercise.weight, undefined);
  assert.deepEqual(swapped[2].weight, { value: 30, unit: "lb" });
  assert.equal(swapped[2].reps, 8);
  assert.equal(swapped[2].tempo, "3010");
  assert.equal(plannedExercise(swapped[2]).id, squat.id);
  assert.equal(swapped[3].exercise.id, plank.id);
  assert.equal(swapped[1], items[1]);
});

test("switches to a timed target when the alternative is held", () => {
  const [swapped] = swapExercise([set(squat, 1)], 0, { ...plank, weight: null });

  assert.equal(swapped.mode, "timed");
  assert.equal(swapped.seconds, 60);
  assert.equal(swapped.reps, null);
  assert.equal(swapped.tempo, null);
  assert.equal(swapped.weight, null);
  assert.deepEqual(swapped.equipment, ["mat"]);
});

test("carries the planned weight to an alternative with the same equipment and no weight of its own", () => {
  const [swapped] = swapExercise([set(squat, 1)], 0, { ...deadlift, weight: null });

  assert.deepEqual(swapped.weight, { value: 40, unit: "lb" });
  assert.deepEqual(swapped.allowed_weights, [20, 40]);
});

test("steps a swapped exercise through its own owned weights", () => {
  const [swapped] = swapExercise([set(squat, 1)], 0, { ...deadlift, weight: { value: 10, unit: "lb" }, allowed_weights: [10, 20] });
  const [held] = swapExercise([set(squat, 1)], 0, { ...plank, weight: null, allowed_weights: null });

  assert.deepEqual(swapped.allowed_weights, [10, 20]);
  assert.equal(swapped.exercise.allowed_weights, undefined);
  assert.equal(held.allowed_weights, null);
});

test("a swap takes a weight when the alternative does, even with none to start at", () => {
  const plain = set(plank, 1, { weight: null, weight_unit: null, weights_held: null, allowed_weights: null, equipment: ["mat"] });
  const [weighted] = swapExercise([plain], 0, { ...deadlift, weight: null, weight_unit: "lb", allowed_weights: [10, 20] });
  const [bodyweight] = swapExercise([set(squat, 1, { weight: null, weight_unit: "lb" })], 0, { ...plank, weight: null, weight_unit: null, allowed_weights: null });

  assert.equal(weighted.weight, null);
  assert.equal(weighted.weight_unit, "lb");
  assert.deepEqual(weighted.allowed_weights, [10, 20]);
  assert.equal(bodyweight.weight_unit, null);
  assert.equal(bodyweight.allowed_weights, null);

  const [onBench] = swapExercise([set(squat, 1, { equipment: ["dumbbell", "bench"] })], 0, { ...plank, equipment: ["bench"], weight: null, weight_unit: null, allowed_weights: null });
  assert.equal(onBench.weight, null);
  assert.equal(onBench.weight_unit, null);
});

test("swapping back puts the plan back, and a second swap still knows the plan", () => {
  const items = [set(squat, 1)];
  const once = swapExercise(items, 0, { ...plank, weight: null });
  const twice = swapExercise(once, 0, { ...deadlift, weight: null });
  const back = swapExercise(twice, 0, squat);

  assert.equal(plannedExercise(twice[0]).id, squat.id);
  assert.equal(twice[0].mode, "reps");
  assert.equal(twice[0].reps, 8);
  assert.deepEqual(back[0], items[0]);
});

const lunge = { id: 4, name: "Curtsy lunge", equipment: ["dumbbell"], default_reps: 10, default_seconds: null, unilateral: true };

test("runs a per-side alternative on both sides of each set, and back", () => {
  const items = [set(squat, 1), rest(1), set(squat, 2)];
  const swapped = swapExercise(items, 0, { ...lunge, weight: null });

  assert.deepEqual(swapped.map((i) => [i.type, i.exercise?.id, i.side]), [
    ["exercise", 4, "left"], ["exercise", 4, "right"], ["rest", undefined, undefined], ["exercise", 4, "left"], ["exercise", 4, "right"],
  ]);
  assert.equal(swapped[1].reps, 8);
  assert.deepEqual(swapExercise(swapped, 0, squat), items);
});

test("runs a two-sided alternative once per set of a per-side exercise, and back", () => {
  const items = [set(lunge, 1, { side: "left" }), set(lunge, 1, { side: "right" }), set(lunge, 2, { side: "left" }), set(lunge, 2, { side: "right" })];
  const swapped = swapExercise(items, 0, { ...squat, weight: null });

  assert.deepEqual(swapped.map((i) => [i.exercise.id, i.side, i.block.round]), [[1, null, 1], [1, null, 2]]);
  assert.deepEqual(swapExercise(swapped, 0, lunge), items);
});

test("counts reps the alternative's way between per-side and alternating exercises", () => {
  const bug = { id: 5, name: "Dead bug", equipment: [], default_reps: 10, default_seconds: null, alternating: true };
  const sided = [set(lunge, 1, { side: "left" }), set(lunge, 1, { side: "right" })];
  assert.deepEqual(swapExercise(sided, 0, { ...bug, weight: null }).map((i) => [i.exercise.id, i.side, i.reps]), [[5, null, 16]]);

  const alternating = [set(bug, 1, { reps: 9 })];
  assert.deepEqual(swapExercise(alternating, 0, { ...lunge, weight: null }).map((i) => [i.side, i.reps]), [["left", 5], ["right", 5]]);
  assert.equal(swapExercise(alternating, 0, { ...squat, weight: null })[0].reps, 9);
  // The right side left after the left was done is half a set.
  assert.deepEqual(swapExercise(sided, 1, { ...bug, weight: null }).map((i) => [i.exercise.id, i.reps]), [[4, 8], [5, 8]]);
});

test("finishes a set started on the left as one set when swapped to a two-sided exercise", () => {
  const items = [set(lunge, 1, { side: "left" }), set(lunge, 1, { side: "right" }), set(lunge, 2, { side: "left" }), set(lunge, 2, { side: "right" })];
  const swapped = swapExercise(items, 1, { ...squat, weight: null });

  assert.deepEqual(swapped.map((i) => [i.exercise.id, i.side]), [[4, "left"], [1, null], [1, null]]);
});

test("keeps the logged marks on their items when a swap adds sides", () => {
  const items = [set(plank, 1, { step_id: 12 }), set(squat, 1), set(plank, 2, { step_id: 12 })];
  const run = swapRun({ items, logged: { 0: "done" } }, 1, { ...lunge, weight: null });

  assert.equal(run.items.length, 4);
  assert.deepEqual(run.logged, { 0: "done" });
  assert.deepEqual(swapRun({ items, logged: { 0: "done", 2: "skipped" } }, 1, { ...lunge, weight: null }).logged, { 0: "done", 3: "skipped" });
});

test("shortlists alternatives that train the same or a similar movement, the session's own last", () => {
  const option = (id, match) => ({ id, match });
  const found = [option(1, "same"), option(2, "similar"), option(3, "other"), option(4, "same"), option(5, "other")];

  const { best, rest } = shortlist(found, new Set([1]));
  assert.deepEqual(best.map((e) => e.id), [2, 4, 1]);
  assert.deepEqual(rest.map((e) => e.id), [3, 5]);

  const none = shortlist([option(1, "other"), option(2, "other")]);
  assert.deepEqual(none.best.map((e) => e.id), [1, 2]);
  assert.equal(shortlist(Array.from({ length: 9 }, (_, i) => option(i, "same"))).best.length, SHORTLIST);
});

const HOUR = 3_600_000;

test("resumes a run touched recently, whatever its stage", () => {
  const now = 10 * HOUR;
  for (const stage of ["ready", "player", "finish"]) {
    assert.equal(resumeChoice({ stage, startedAt: 0, touchedAt: now - HOUR }, now, 2 * HOUR), "resume");
  }
});

test("asks about an old run that started, and drops one that never left Get ready", () => {
  const now = 50 * HOUR;
  assert.equal(resumeChoice({ stage: "player", startedAt: 0, touchedAt: 3 * HOUR }, now, 2 * HOUR), "ask");
  assert.equal(resumeChoice({ stage: "finish", startedAt: 0, touchedAt: 3 * HOUR }, now, 2 * HOUR), "ask");
  assert.equal(resumeChoice({ stage: "ready", startedAt: 0, touchedAt: 3 * HOUR }, now, 2 * HOUR), "drop");
});

test("goes by the start time for a run saved before runs were stamped", () => {
  assert.equal(resumeChoice({ stage: "player", startedAt: HOUR }, 2 * HOUR, 2 * HOUR), "resume");
  assert.equal(resumeChoice({ stage: "player", startedAt: HOUR }, 4 * HOUR, 2 * HOUR), "ask");
  assert.equal(resumeChoice(null, 0, 2 * HOUR), "none");
});

test("counts the exercises with a set done, a swap counting for the planned one", () => {
  const swapped = swapExercise([set(deadlift, 1)], 0, { ...plank, weight: null })[0];
  const items = [set(squat, 1), rest(1), set(squat, 2), swapped, set(plank, 1)];
  const run = { items, logged: { 0: "done", 2: "done", 3: "done", 4: "skipped" } };

  assert.deepEqual(sessionProgress(run), { exercises: 3, done: 2, sets: 3 });
  assert.deepEqual(sessionProgress({ items }), { exercises: 3, done: 0, sets: 0 });
});

const part = (kind, item) => ({ ...item, workout: { id: 1, kind, title: kind } });

test("ends early until the player is past the main workout's last item", () => {
  const items = [part("warmup", set(plank, 1)), part("workout", set(squat, 1)), part("workout", rest(1)), part("workout", set(squat, 2)), part("cooldown", set(plank, 1))];

  assert.equal(endsEarly(items, 0), true);
  assert.equal(endsEarly(items, 3), true);
  assert.equal(endsEarly(items, 4), false);
  assert.equal(endsEarly(items, 5), false);
});

test("matches the server's logged sets to items by step, round and side", () => {
  const items = [set(squat, 1, { side: "left" }), set(squat, 1, { side: "right" }), rest(1), set(squat, 2, { side: "left" }), set(plank, 1, { step_id: 11 })];
  const sets = [
    { step_id: 10, set_number: 1, side: "left", status: "done" },
    { step_id: 10, set_number: 1, side: "right", status: "skipped" },
    { step_id: 11, set_number: 1, side: null, status: "done" },
  ];

  assert.deepEqual(loggedFromServer(items, sets), { 0: "done", 1: "skipped", 4: "done" });
  assert.deepEqual(loggedFromServer(items), {});
});

test("picks up at the first exercise after the last set logged", () => {
  const items = [set(squat, 1), rest(1), set(squat, 2), set(plank, 1)];

  assert.equal(pickUpIndex(items, { 0: "done" }), 2);
  assert.equal(pickUpIndex(items, { 0: "done", 2: "skipped" }), 3);
  assert.equal(pickUpIndex(items, {}), 0);
  assert.equal(pickUpIndex(items, { 3: "done" }), 0);
});

test("finds where the current part ends", () => {
  const warm = { id: 1, kind: "warmup" };
  const main = { id: 2, kind: "workout" };
  const items = [{ workout: warm }, { workout: warm }, { workout: main }, { workout: main }];

  assert.equal(partEnd(items, 0), 2);
  assert.equal(partEnd(items, 1), 2);
  assert.equal(partEnd(items, 2), 4);
});

test("labels the set only when a block has more than one round", () => {
  assert.equal(setLabel(set(squat, 2)), "Set 2 of 2");
  assert.equal(setLabel({ block: { round: 1, rounds: 1 } }), "");
});

test("estimates the minutes left the way the server estimates a workout", () => {
  const timed = { type: "exercise", mode: "timed", seconds: 45, side: "left", block: { round: 1, rounds: 1 } };
  const items = [set(squat, 1, { tempo: "3010" }), rest(1), timed];

  // 8 reps at 4 s + 10 s setup, 60 s rest, 45 s + 5 s setup for one side
  assert.equal(minutesLeft(items, 0), Math.ceil((42 + 60 + 50) / 60));
  assert.equal(minutesLeft(items, 2), 1);
  assert.equal(minutesLeft(items, 3), 0);
  assert.equal(minutesLeft([set(squat, 1, { tempo: null, reps: 10 })], 0), 1);
});

test("writes a tempo out", () => {
  assert.equal(tempoText("2111"), "2 s down · 1 s pause · 1 s up · 1 s at the top");
  assert.equal(tempoText("3010"), "3 s down · 1 s up");
  assert.equal(tempoText("2020"), "2 s down · 2 s up");
  assert.equal(tempoText("31X0"), "3 s down · 1 s pause · up fast");
  assert.equal(tempoText("301"), "3 s down · 1 s up");
  assert.equal(tempoText("slow"), "tempo slow");
  assert.equal(tempoText(null), "");
});

test("sums up a finished run from the sets logged", () => {
  const swapped = swapExercise([set(deadlift, 1)], 0, { ...plank, weight: null })[0];
  const items = [set(squat, 1), rest(1), set(squat, 2), swapped, set(plank, 1)];
  const run = { items, logged: { 0: "done", 2: "skipped", 3: "done" } };

  assert.deepEqual(finishSummary(run), { exercises: 3, done: 2, sets: 2, planned: 4, skipped: 1, swaps: 1, frames: [] });
});

test("reports the main workout apart from a skipped warm-up and the cool-down done", () => {
  const warmup = { id: 7, kind: "warmup", title: "Warm-up" };
  const main = { id: 2, kind: "workout", title: "Workout 1" };
  const cooldown = { id: 8, kind: "cooldown", title: "Cool-down" };
  const items = [
    ...Array.from({ length: 4 }, (_, i) => set(plank, 1, { step_id: 20 + i, workout: warmup })),
    set(squat, 1, { workout: main }), rest(1), set(squat, 2, { workout: main }), set(deadlift, 1, { workout: main }),
    set(plank, 1, { step_id: 30, workout: cooldown }), set(plank, 2, { step_id: 30, workout: cooldown }),
  ];
  const logged = { 0: "skipped", 1: "skipped", 2: "skipped", 3: "skipped", 4: "done", 6: "done", 7: "done", 8: "done", 9: "done" };

  const summary = finishSummary({ items, logged, workoutId: 2 });

  assert.deepEqual(summary, {
    exercises: 2, done: 2, sets: 3, planned: 3, skipped: 0, swaps: 0,
    frames: [{ part: "warmup", sets: 0, skipped: 4, planned: 4 }, { part: "cooldown", sets: 2, skipped: 0, planned: 2 }],
  });
  assert.equal(framingLine(summary.frames), "Warm-up skipped · cool-down done");
  assert.equal(framingLine([{ part: "cooldown", sets: 0, skipped: 0, planned: 9 }]), "Cool-down not reached");
  assert.equal(framingLine([{ part: "cooldown", sets: 4, planned: 9 }]), "Cool-down 4 of 9 sets");
});

test("counts a stretch routine run on its own as the main workout", () => {
  const stretch = { id: 9, kind: "cooldown", title: "Stretch" };
  const items = [set(plank, 1, { workout: stretch }), set(plank, 2, { workout: stretch })];

  assert.equal(itemPart(items[0], 9), "workout");
  assert.deepEqual(finishSummary({ items, logged: { 0: "done" }, workoutId: 9 }), { exercises: 1, done: 1, sets: 1, planned: 2, skipped: 0, swaps: 0, frames: [] });
});

test("a swap holds as many weights as the exercise swapped in", () => {
  const [pair] = swapExercise([set(squat, 1)], 0, { ...deadlift, weights_held: 2, weight: { value: 20, unit: "lb" }, allowed_weights: [10, 20] });
  const [bodyweight] = swapExercise([set(squat, 1)], 0, { ...plank, equipment: [], weight: null });

  assert.equal(pair.weights_held, 2);
  assert.equal(bodyweight.weights_held, null);
});

test("says what equipment to use only when it changes from the exercise before", () => {
  const items = [set(squat, 1), rest(1), set(squat, 2), set(plank, 1, { equipment: [] }), set(deadlift, 1, { equipment: ["kettlebell"] })];

  assert.equal(equipmentChanges(items, 0), true);
  assert.equal(equipmentChanges(items, 2), false);
  assert.equal(equipmentChanges(items, 3), true);
  assert.equal(equipmentChanges(items, 4), true);
});

test("counts a change of the gear carrying any weight as a change", () => {
  const anyWeight = { slug: "weight", carriers: [{ value: 20, equipment: "dumbbell" }, { value: 40, equipment: "kettlebell" }] };
  const generic = (weight) => ({ ...set(squat, 1), equipment: ["weight"], any_weight: anyWeight, weight: { value: weight, unit: "lb" } });
  assert.equal(equipmentChanges([generic(40), generic(20)], 1), true);
  assert.equal(equipmentChanges([generic(40), generic(40)], 1), false);
  assert.equal(equipmentChanges([{ ...set(squat, 1), equipment: ["dumbbell"] }, generic(20)], 1), false);
});

test("says a step as one sentence for a screen reader", () => {
  const squat2 = { ...set(squat, 2), block: { label: "A", round: 2, rounds: 3 } };
  assert.equal(stepAnnouncement(squat2, { weight: { value: 40, unit: "lb" } }), "Goblet squat, set 2 of 3, 8 reps, 40 pounds");
  assert.equal(stepAnnouncement({ ...squat2, weights_held: 2 }, { weight: { value: 10, unit: "lb" } }), "Goblet squat, set 2 of 3, 8 reps, 10 pounds in each hand");
  assert.equal(stepAnnouncement({ ...set(plank, 1), mode: "timed", reps: null, seconds: 30, block: { label: "B", round: 1, rounds: 1 } }), "Plank, 30 seconds");
  const right = { ...set(plank, 1), mode: "timed", reps: null, seconds: 20, side: "right", block: { label: "B", round: 1, rounds: 1 } };
  assert.equal(stepAnnouncement(right, { switching: true }), "Switch sides. Plank, right side, 20 seconds");
  assert.equal(stepAnnouncement({ ...set(squat, 1), reps: 1, block: { label: "C", round: 1, rounds: 1 } }), "Goblet squat, 1 rep");
  assert.equal(stepAnnouncement({ ...set(squat, 1), reps: 10, exercise: { ...squat, alternating: true }, block: { label: "C", round: 1, rounds: 1 } }), "Goblet squat, 10 reps in total");
});

test("says a rest and what comes after it", () => {
  assert.equal(stepAnnouncement({ type: "rest", seconds: 60 }, { next: set(deadlift, 1) }), "Rest, 60 seconds. Next: Straight-leg deadlift");
  assert.equal(stepAnnouncement({ type: "rest", seconds: 60 }), "Rest, 60 seconds");
});

test("says the big count with its unit", () => {
  assert.equal(spokenTarget(set(squat, 1), { phase: "reps" }), "8 reps");
  assert.equal(spokenTarget({ ...set(squat, 1), reps: null, note: "To failure" }, { phase: "reps" }), "To failure");
  assert.equal(spokenTarget({ ...set(squat, 1), reps: 10, exercise: { ...squat, alternating: true } }, { phase: "reps" }), "10 reps in total");
  assert.equal(spokenTarget({ ...set(squat, 1), reps: null }, { phase: "reps" }), "Go");
  assert.equal(spokenTarget(set(plank, 1), { phase: "work", seconds: 1 }), "1 second");
  assert.equal(spokenTarget({ type: "rest", seconds: 60 }, { phase: "rest", seconds: 45 }), "45 seconds");
});

test("says a weight in words", () => {
  assert.equal(spokenWeight({ value: 20, unit: "kg" }), "20 kilograms");
  assert.equal(spokenWeight({ value: 1, unit: "lb" }), "1 pound");
  assert.equal(spokenWeight({ value: 2.5, unit: "kg" }), "2.5 kilograms");
  assert.equal(spokenWeight(null), "");
  assert.equal(spokenWeight({ value: 0, unit: "lb" }), "");
});
