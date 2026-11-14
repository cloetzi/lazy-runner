import { test } from "node:test";
import assert from "node:assert/strict";
import {
  draftFrom, newDraft, setKind, addBlock, newStep, setExercise, setMode, stepAmount, stepRounds, stepRest,
  weightOptions, stepDraftWeight, moveBlock, moveStep, locate, removeBlock, removeStep, saveRequest, changed,
  placeProblems, draftSummary,
} from "../../public/js/builder.js";

const inventory = [
  { slug: "mat", name: "Mat", owned: true, weights: [], unit: null },
  { slug: "dumbbell", name: "Dumbbells", owned: true, weights: [10, 20], unit: "lb" },
  { slug: "kettlebell", name: "Kettlebell", owned: true, weights: [40], unit: "lb" },
  { slug: "barbell", name: "Barbell", owned: false, weights: [], unit: "kg" },
];

const squat = { id: 1, slug: "goblet-squat", name: "Goblet squat", equipment: ["dumbbell"], unilateral: false, default_reps: 8, default_seconds: null };
const plank = { id: 2, slug: "plank", name: "Plank", equipment: ["mat"], unilateral: false, default_reps: null, default_seconds: 30 };
const lunge = { id: 3, slug: "lunge", name: "Lunge", equipment: [], unilateral: true, default_reps: null, default_seconds: null };
const press = { id: 4, slug: "barbell-press", name: "Barbell press", equipment: ["barbell"], unilateral: false, default_reps: 5, default_seconds: null };

// A workout as GET /api/workouts/:id gives it.
function served() {
  return {
    id: 7, kind: "workout", title: "Mine", subtitle: null, program_id: null, warmup: 3, cooldown: "none",
    weight_steps: { default: { lb: [{ step: 5 }], kg: [{ step: 2.5 }] } },
    blocks: [
      {
        id: 11, label: "A", position: 1, rounds: 3, rest_seconds: 60,
        steps: [
          { id: 21, position: 1, reps: 8, duration_seconds: null, tempo: "2111", weight: { value: 40, unit: "lb" }, weights_held: null,
            per_side: false, note: null, equipment: ["kettlebell"], equipment_needed: ["kettlebell"], exercise: squat, target: { reps: 8, seconds: null, weight: { value: 20, unit: "lb" } } },
          { id: 22, position: 2, reps: null, duration_seconds: 45, tempo: null, weight: null, weights_held: null,
            per_side: false, note: "Brace", equipment: null, equipment_needed: ["mat"], exercise: plank, target: { reps: null, seconds: 45, weight: null } },
        ],
      },
      { id: 12, label: "B", position: 2, rounds: 1, rest_seconds: 0, steps: [
        { id: 23, position: 1, reps: null, duration_seconds: null, tempo: null, weight: null, weights_held: 1,
          per_side: true, note: "Slow", equipment: null, equipment_needed: [], exercise: lunge, target: { reps: null, seconds: null, weight: null } },
      ] },
    ],
  };
}

test("a draft sends back what GET gave, ids and the step's own gear included", () => {
  const draft = draftFrom(served());
  const request = saveRequest(draft);
  assert.equal(request.method, "PUT");
  assert.equal(request.path, "/api/workouts/7");
  assert.deepEqual(request.body, {
    title: "Mine", subtitle: "", warmup: 3, cooldown: "none",
    blocks: [
      { id: 11, label: "A", rounds: 3, rest_seconds: 60, steps: [
        { id: 21, exercise_id: 1, reps: 8, tempo: "2111", weight: { value: 40, unit: "lb" }, equipment: ["kettlebell"] },
        { id: 22, exercise_id: 2, duration_seconds: 45, note: "Brace" },
      ] },
      { id: 12, label: "B", rounds: 1, rest_seconds: 0, steps: [{ id: 23, exercise_id: 3, weights_held: 1, note: "Slow" }] },
    ],
  });
  assert.equal(changed(draft, request.body), false);
  draft.blocks[0].steps[0].reps = 9;
  assert.equal(changed(draft, request.body), true);
});

test("a new workout posts its kind, and only a main workout picks frames", () => {
  const draft = newDraft("workout", { warmup: 3, cooldown: 4 });
  assert.deepEqual(draft.blocks.map((block) => block.label), ["A"]);
  draft.title = " Legs ";
  const request = saveRequest(draft);
  assert.equal(request.method, "POST");
  assert.equal(request.path, "/api/workouts");
  assert.deepEqual(request.body, { kind: "workout", title: "Legs", subtitle: "", warmup: 3, cooldown: 4, blocks: [{ label: "A", rounds: 1, rest_seconds: 0, steps: [] }] });

  setKind(draft, "warmup");
  assert.equal("warmup" in saveRequest(draft).body, false);
  setKind(draft, "workout");
  assert.deepEqual([draft.warmup, draft.cooldown], ["none", "none"]);
  assert.throws(() => setKind(draftFrom(served()), "warmup"));
});

test("new blocks take the first free letter", () => {
  const draft = draftFrom(served());
  assert.equal(addBlock(draft).label, "C");
  draft.blocks[0].label = "Finisher";
  assert.equal(addBlock(draft).label, "A");
});

test("a new step starts from its exercise's target and the lightest owned weight", () => {
  const step = newStep(squat, inventory, "lb");
  assert.deepEqual([step.id, step.mode, step.reps, step.seconds, step.weight], [null, "reps", 8, null, { value: 10, unit: "lb" }]);
  const hold = newStep(plank, inventory, "lb");
  assert.deepEqual([hold.mode, hold.reps, hold.seconds, hold.weight], ["seconds", null, 30, null]);
  assert.equal(newStep(lunge, inventory).reps, 10);
  // Weighted gear not owned: no weight to start, but one can be added.
  assert.equal(newStep(press, inventory).weight, null);
  assert.deepEqual(weightOptions(newStep(press, inventory), inventory, "lb"), { unit: "kg", allowed: [] });
});

test("another exercise makes it a new step, keeping only the note", () => {
  const draft = draftFrom(served());
  const step = draft.blocks[0].steps[0];
  setExercise(step, plank, inventory);
  assert.deepEqual(
    [step.id, step.exercise.id, step.mode, step.seconds, step.reps, step.tempo, step.equipment, step.weight],
    [null, 2, "seconds", 30, null, "", null, null],
  );
  assert.equal(saveRequest(draft).body.blocks[0].steps[0].id, undefined);

  // Counted the same way, it still takes the new exercise's target; a weight
  // in the old exercise's unit doesn't carry over.
  const press = { id: 5, slug: "kg-press", name: "Press", equipment: ["barbell"], unilateral: false, default_reps: 5, default_seconds: null };
  const heavy = { ...newStep(press, inventory), reps: 20, weight: { value: 30, unit: "kg" } };
  setExercise(heavy, squat, inventory, "kg");
  assert.deepEqual([heavy.reps, heavy.weight], [8, { value: 10, unit: "lb" }]);
});

test("switches between reps, time and a note", () => {
  const step = newStep(squat, inventory);
  setMode(step, "seconds");
  assert.deepEqual([step.reps, step.seconds], [null, 30]);
  setMode(step, "note");
  assert.deepEqual([step.reps, step.seconds], [null, null]);
  setMode(step, "reps");
  assert.equal(step.reps, 8);
  assert.throws(() => setMode(step, "laps"));
});

test("steps reps, seconds, rounds and rest within their limits", () => {
  const step = newStep(squat, inventory);
  stepAmount(step, "up");
  assert.equal(step.reps, 9);
  step.reps = 1;
  stepAmount(step, "down");
  assert.equal(step.reps, 1);
  setMode(step, "seconds");
  stepAmount(step, "up");
  assert.equal(step.seconds, 35);
  step.seconds = 5;
  stepAmount(step, "down");
  assert.equal(step.seconds, 5);
  step.seconds = 3600;
  stepAmount(step, "up");
  assert.equal(step.seconds, 3600);
  setMode(step, "reps");
  step.reps = 1000;
  stepAmount(step, "up");
  assert.equal(step.reps, 1000);

  const block = { rounds: 1, rest_seconds: 0 };
  stepRounds(block, "down");
  stepRest(block, "down");
  assert.deepEqual(block, { rounds: 1, rest_seconds: 0 });
  stepRounds(block, "up");
  stepRest(block, "up");
  assert.deepEqual(block, { rounds: 2, rest_seconds: 15 });
  // Past the top (saved through the API): up keeps it, down comes back.
  const long = { rounds: 12, rest_seconds: 600 };
  stepRounds(long, "up");
  stepRest(long, "up");
  assert.deepEqual(long, { rounds: 12, rest_seconds: 600 });
  stepRounds(long, "down");
  stepRest(long, "down");
  assert.deepEqual(long, { rounds: 11, rest_seconds: 585 });
});

test("an exercise that needs just a weight steps through every weight owned", () => {
  // As GET /api/equipment gives the generic weight: owned with the dumbbells, all their weights.
  const withWeight = [...inventory, { slug: "weight", name: "Weight", owned: true, weights: [10, 20, 40], unit: "lb", any_weight: true }];
  const step = newStep({ ...squat, equipment: ["weight"] }, withWeight);
  assert.deepEqual(weightOptions(step, withWeight, "kg"), { unit: "lb", allowed: [10, 20, 40] });
});

test("weights step through what the step's gear owns, with no weight below the lightest", () => {
  const draft = draftFrom(served());
  const step = draft.blocks[0].steps[0]; // goblet squat with the kettlebell, kept in lb
  const options = weightOptions(step, inventory, "kg");
  assert.deepEqual(options, { unit: "lb", allowed: [40] });
  stepDraftWeight(step, "up", options);
  assert.deepEqual(step.weight, { value: 40, unit: "lb" });
  stepDraftWeight(step, "down", options);
  assert.equal(step.weight, null);
  stepDraftWeight(step, "down", options);
  assert.equal(step.weight, null);
  stepDraftWeight(step, "up", options);
  assert.deepEqual(step.weight, { value: 40, unit: "lb" });

  const dumbbells = newStep(squat, inventory);
  const pair = weightOptions(dumbbells, inventory, "lb");
  stepDraftWeight(dumbbells, "up", pair);
  assert.deepEqual(dumbbells.weight, { value: 20, unit: "lb" });
  stepDraftWeight(dumbbells, "up", pair);
  assert.deepEqual(dumbbells.weight, { value: 20, unit: "lb" });

  // Owned weights in another unit are converted to the one the exercise keeps.
  const kg = [{ slug: "dumbbell", owned: true, weights: [5], unit: "kg" }];
  assert.deepEqual(weightOptions(newStep({ ...squat, equipment: ["dumbbell"] }, kg), kg, "lb"), { unit: "kg", allowed: [5] });
  const mixed = { ...newStep(squat, inventory), equipment: ["kettlebell"], weight: null };
  mixed.exercise = { ...squat, equipment: ["dumbbell"] };
  assert.deepEqual(weightOptions(mixed, [...inventory.filter((i) => i.slug !== "kettlebell"), { slug: "kettlebell", owned: true, weights: [16], unit: "kg" }], "lb"), { unit: "lb", allowed: [35.27] });
});

test("without owned weights a weight steps by the bands, and none below zero", () => {
  const step = newStep(press, inventory);
  const options = weightOptions(step, inventory, "lb");
  stepDraftWeight(step, "up", options);
  assert.deepEqual(step.weight, { value: 2.5, unit: "kg" });
  stepDraftWeight(step, "up", options);
  assert.deepEqual(step.weight, { value: 5, unit: "kg" });
  stepDraftWeight(step, "down", options);
  stepDraftWeight(step, "down", options);
  assert.equal(step.weight, null);
});

test("bodyweight steps take no weight", () => {
  assert.equal(weightOptions(newStep(lunge, inventory), inventory), null);
  assert.equal(weightOptions(newStep(plank, inventory), inventory), null);
});

test("moves blocks, and steps within and across blocks", () => {
  const draft = draftFrom(served());
  assert.equal(moveBlock(draft, 0, "up"), 0);
  assert.equal(moveBlock(draft, 0, "down"), 1);
  assert.deepEqual(draft.blocks.map((b) => b.label), ["B", "A"]);
  moveBlock(draft, 1, "up");

  const lungeKey = draft.blocks[1].steps[0].key;
  assert.deepEqual(moveStep(draft, 1, 0, "up"), { block: 0, step: 2 });
  assert.deepEqual(locate(draft, lungeKey), { block: 0, step: 2 });
  assert.equal(draft.blocks[1].steps.length, 0);
  assert.deepEqual(moveStep(draft, 0, 2, "up"), { block: 0, step: 1 });
  assert.deepEqual(draft.blocks[0].steps.map((s) => s.exercise.slug), ["goblet-squat", "lunge", "plank"]);
  assert.deepEqual(moveStep(draft, 0, 2, "down"), { block: 1, step: 0 });
  assert.deepEqual(moveStep(draft, 0, 0, "up"), { block: 0, step: 0 });
  assert.deepEqual(moveStep(draft, 1, 0, "down"), { block: 1, step: 0 });
  assert.deepEqual(locate(draft, draft.blocks[1].key), { block: 1, step: null });
  assert.equal(locate(draft, "nope"), null);

  removeStep(draft, 0, 0);
  removeBlock(draft, 1);
  assert.deepEqual(saveRequest(draft).body.blocks.map((b) => b.steps.map((s) => s.id)), [[23]]);
});

test("puts each problem next to the block or step it names", () => {
  const draft = draftFrom(served());
  const placed = placeProblems({
    "blocks[0].steps[1].reps": ["must be greater than 0"],
    "blocks[0].steps[1]": ["needs reps or seconds, not both"],
    "blocks[1].label": ["is already the label of block 1"],
    "blocks[1].steps": ["needs at least one step"],
    "blocks[0].steps[0].weight.value": ["must be greater than or equal to 0"],
    title: ["can't be blank"],
    blocks: ["needs at least one block"],
  }, draft);
  const [a, b] = draft.blocks;
  assert.deepEqual(placed.steps[a.steps[1].key], ["Reps must be greater than 0.", "Needs reps or seconds, not both."]);
  assert.deepEqual(placed.steps[a.steps[0].key], ["Weight must be greater than or equal to 0."]);
  assert.deepEqual(placed.blocks[b.key], ["Label is already the label of block 1.", "Needs at least one step."]);
  assert.deepEqual(placed.general, ["Name can't be blank.", "Needs at least one block."]);
  assert.deepEqual(placeProblems(undefined, draft), { general: [], blocks: {}, steps: {} });
});

test("summarises a draft step", () => {
  const draft = draftFrom(served());
  const shown = (weight) => `${weight.value} ${weight.unit}`;
  assert.equal(draftSummary(draft.blocks[0].steps[0], shown), "8 reps · 40 lb · tempo 2111");
  assert.equal(draftSummary(draft.blocks[0].steps[1], shown), "45 s · Brace");
  assert.equal(draftSummary(draft.blocks[1].steps[0], shown), "each side · Slow");
  const bug = { ...draft.blocks[0].steps[0], exercise: { ...squat, alternating: true }, reps: 10, weight: null, tempo: "" };
  assert.equal(draftSummary(bug, shown), "10 reps in total, 5 each side");
});
