import { test } from "node:test";
import assert from "node:assert/strict";
import { blockName, blockSummary, stepSummary, setWeight, includedKinds, framingFor, framePlan, gearList, carrierOf } from "../../public/js/workout.js";

const step = (overrides = {}) => ({
  per_side: false, tempo: null, note: null, suggestion: null,
  exercise: { id: 1 }, target: { reps: 8, seconds: null, weight: null },
  ...overrides,
});

test("names lettered blocks and keeps named ones", () => {
  assert.equal(blockName("A"), "Block A");
  assert.equal(blockName("Warm-up"), "Warm-up");
});

test("summarises a block's rounds and rest", () => {
  assert.equal(blockSummary({ rounds: 3, rest_seconds: 60 }), "3 rounds · 60 s rest");
  assert.equal(blockSummary({ rounds: 1, rest_seconds: 60 }), "1 round");
  assert.equal(blockSummary({ rounds: 2, rest_seconds: 0 }), "2 rounds");
});

test("summarises a step from its target", () => {
  assert.equal(stepSummary(step({ tempo: "2111" })), "8 reps · tempo 2111");
  assert.equal(stepSummary(step({ per_side: true, target: { reps: null, seconds: 45 } })), "45 s each side");
  assert.equal(stepSummary(step({ per_side: true })), "8 reps each side");
  assert.equal(stepSummary(step({ exercise: { alternating: true }, target: { reps: 10, seconds: null } })), "10 reps in total, 5 each side");
  assert.equal(stepSummary(step({ exercise: { alternating: true }, target: { reps: 9, seconds: null } })), "9 reps in total, alternating sides");
  assert.equal(stepSummary(step({ exercise: { alternating: true }, target: { reps: null, seconds: 30 } })), "30 s, alternating sides");
  assert.equal(stepSummary(step({ target: { reps: null, seconds: null }, note: "Hold the top" })), "Hold the top");
});

test("sets the weight on every step of the exercise and clears its suggestion", () => {
  const squat = step({ target: { reps: 8, weight: { value: 40, unit: "lb" } }, suggestion: { value: 45, unit: "lb" } });
  const again = step({ target: { reps: 5, weight: { value: 40, unit: "lb" } } });
  const other = step({ exercise: { id: 2 }, target: { reps: 8, weight: { value: 10, unit: "lb" } }, suggestion: { value: 12.5 } });
  const workout = { blocks: [{ steps: [squat, other] }, { steps: [again] }] };

  setWeight(workout, 1, { value: 45, unit: "lb" });

  assert.deepEqual(squat.target.weight, { value: 45, unit: "lb" });
  assert.deepEqual(again.target.weight, { value: 45, unit: "lb" });
  assert.equal(squat.suggestion, null);
  assert.deepEqual(other.target.weight, { value: 10, unit: "lb" });
  assert.deepEqual(other.suggestion, { value: 12.5 });
});

test("sets no weight, and each step's weight in its own unit", () => {
  const plain = step({ weight_unit: "lb" });
  const kettlebell = step({ weight_unit: "kg" });
  const workout = { blocks: [{ steps: [plain, kettlebell] }] };

  setWeight(workout, 1, { value: 35, unit: "lb" });
  assert.deepEqual(kettlebell.target.weight, { value: 16, unit: "kg" });
  setWeight(workout, 1, null);
  assert.equal(plain.target.weight, null);
  assert.equal(kettlebell.target.weight, null);
});

const parts = [{ kind: "warmup" }, { kind: "workout" }, { kind: "cooldown" }];

test("includes the warm-up and cool-down unless switched off, and always the workout", () => {
  assert.deepEqual(includedKinds(parts), ["warmup", "workout", "cooldown"]);
  assert.deepEqual(includedKinds(parts, { warmup: false }), ["workout", "cooldown"]);
  assert.deepEqual(includedKinds(parts, { warmup: false, cooldown: false, workout: false }), ["workout"]);
  assert.deepEqual(includedKinds([{ kind: "warmup" }], { warmup: false }), ["warmup"]);
});

test("frames a session planned with its own parts by them", () => {
  assert.deepEqual(includedKinds(parts, framingFor(["workout", "cooldown"])), ["workout", "cooldown"]);
  assert.deepEqual(framingFor(["warmup", "workout"]), { warmup: true, cooldown: false });
  assert.equal(framingFor(null), null);
});

test("cuts a plan down to the parts it runs, with their equipment and targets", () => {
  const item = (kind, id, equipment) => ({ type: "exercise", workout: { kind }, exercise: { id }, equipment });
  const plan = {
    items: [item("warmup", 1, ["wall"]), { type: "rest", workout: { kind: "workout" }, seconds: 30 }, item("workout", 2, ["dumbbell"]), item("cooldown", 3, ["mat"])],
    equipment: ["wall", "dumbbell", "mat"],
    targets: [{ exercise: { id: 2 } }, { exercise: { id: 3 } }],
  };

  const framed = framePlan(plan, ["workout"]);

  assert.equal(framed.items.length, 2);
  assert.deepEqual(framed.equipment, ["dumbbell"]);
  assert.deepEqual(framed.targets, [{ exercise: { id: 2 } }]);
  assert.deepEqual(framePlan(plan, ["warmup", "workout", "cooldown"]).items, plan.items);
});

const item = (name, equipment) => ({ type: "exercise", exercise: { name }, equipment });

test("lists every piece of gear the session needs, weighted loads and the rest alike, in order of first use", () => {
  const items = [
    item("Goblet squat", ["kettlebell"]),
    { type: "rest", seconds: 60 },
    item("Straight-leg deadlift", ["dumbbell"]),
    item("Split squat", ["dumbbell", "bench"]),
    item("Row", ["dumbbell"]),
    item("Fly", ["dumbbell", "bench"]),
    item("Hamstring curl", ["stability_ball"]),
    item("Push-up", []),
  ];
  const target = (name, weight, held, equipment) => ({ exercise: { name }, weight: weight && { value: weight, unit: "lb" }, weight_unit: "lb", weights_held: held, weight_equipment: equipment, equipment: [equipment] });
  const rows = gearList(items, [
    target("Goblet squat", 40, 1, "kettlebell"),
    target("Straight-leg deadlift", 20, 2, "dumbbell"),
    target("Split squat", 20, 2, "dumbbell"),
    target("Fly", null, 2, "dumbbell"),
    target("Row", 10, 1, "dumbbell"),
  ]);

  assert.deepEqual(rows.map((row) => [row.equipment, row.load && [row.load.held, row.load.weight.value], row.unset, row.exercises]), [
    ["kettlebell", [1, 40], false, ["Goblet squat"]],
    ["dumbbell", [2, 20], false, ["Straight-leg deadlift", "Split squat"]],
    ["dumbbell", [1, 10], false, ["Row"]],
    ["dumbbell", null, true, ["Fly"]],
    ["bench", null, false, ["Split squat", "Fly"]],
    ["stability_ball", null, false, ["Hamstring curl"]],
  ]);
});

test("gives a weight with no gear named a row of its own, last, and none without a weight", () => {
  const items = [item("Push-up", []), item("Plank", []), item("Row", ["dumbbell"])];
  const rows = gearList(items, [
    { exercise: { name: "Push-up" }, weight: { value: 20, unit: "lb" }, weight_unit: "lb", weights_held: 1, weight_equipment: null, equipment: [] },
    { exercise: { name: "Plank" }, weight: null, weight_unit: "lb", weights_held: 1, weight_equipment: null, equipment: [] },
  ]);

  assert.deepEqual(rows.map((row) => [row.equipment, row.load && row.load.weight.value, row.exercises]), [
    ["dumbbell", null, ["Row"]],
    [null, 20, ["Push-up"]],
  ]);
});

const anyWeight = { slug: "weight", carriers: [{ value: 10, equipment: "dumbbell" }, { value: 20, equipment: "dumbbell" }, { value: 40, equipment: "kettlebell" }] };

test("names the gear that carries a weight, following the weight as it steps", () => {
  const squat = { weight: { value: 40, unit: "lb" }, weight_unit: "lb", weight_equipment: "kettlebell", any_weight: anyWeight };
  assert.equal(carrierOf(squat), "kettlebell");
  assert.equal(carrierOf(squat, { value: 20, unit: "lb" }), "dumbbell");
  assert.equal(carrierOf(squat, { value: 9.07, unit: "kg" }), "dumbbell");
  assert.equal(carrierOf(squat, null), "weight");
  assert.equal(carrierOf(squat, { value: 30, unit: "lb" }), "weight");
  // A 16 kg kettlebell in a lb plan is 35.27 lb; a remembered 35 lb is it.
  const mixed = { ...squat, any_weight: { slug: "weight", carriers: [{ value: 35.27, equipment: "kettlebell" }] } };
  assert.equal(carrierOf(mixed, { value: 35, unit: "lb" }), "kettlebell");
  assert.equal(carrierOf(mixed, { value: 16, unit: "kg" }), "kettlebell");
  assert.equal(carrierOf({ weight: { value: 20, unit: "lb" }, weight_equipment: "dumbbell", any_weight: null }), "dumbbell");
});

test("lists an exercise done with any weight under the gear that carries it, and a pair once", () => {
  const item = (name, equipment) => ({ type: "exercise", exercise: { name }, equipment });
  const items = [item("Goblet squat", ["weight"]), item("Row", ["dumbbell"]), item("Curl", ["dumbbell"]), item("Pull-over", ["weight"])];
  const target = (name, weight, held, equipment, any = null) => ({ exercise: { name }, weight: weight && { value: weight, unit: "lb" }, weight_unit: "lb", weights_held: held, weight_equipment: equipment, any_weight: any, equipment: [any ? "weight" : equipment] });
  const rows = gearList(items, [
    target("Goblet squat", 40, 1, "kettlebell", anyWeight),
    target("Row", 10, 2, "dumbbell"),
    target("Curl", 10, 1, "dumbbell"),
    target("Pull-over", 20, 1, "dumbbell", anyWeight),
  ]);

  assert.deepEqual(rows.map((row) => [row.equipment, row.load && [row.load.held, row.load.weight.value], row.exercises]), [
    // In order of first use: the squat comes first, with any weight.
    ["kettlebell", [1, 40], ["Goblet squat"]],
    ["dumbbell", [2, 10], ["Row", "Curl"]],
    ["dumbbell", [1, 20], ["Pull-over"]],
  ]);
});

test("keeps any weight with no weight set under its own name", () => {
  const items = [{ type: "exercise", exercise: { name: "Goblet squat" }, equipment: ["weight"] }];
  const rows = gearList(items, [{ exercise: { name: "Goblet squat" }, weight: null, weight_unit: "lb", weights_held: 1, weight_equipment: "weight", any_weight: anyWeight, equipment: ["weight"] }]);
  assert.deepEqual(rows.map((row) => [row.equipment, row.unset, row.exercises]), [["weight", true, ["Goblet squat"]]]);
});
