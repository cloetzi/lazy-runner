import { test } from "node:test";
import assert from "node:assert/strict";
import { BODYWEIGHT, matches, standIns, gearUsed, countLine, lastLine, usedInLine, areaLabel } from "../../public/js/catalog.js";

const squat = { id: 1, name: "Goblet squat", category: "strength", areas: ["legs"], equipment: ["dumbbell"], cues: ["Weight in the heels"] };
const plank = { id: 2, name: "Plank", category: "strength", areas: ["core"], equipment: [], cues: ["Ribs down"] };
const curl = { id: 3, name: "Swiss ball hamstring curl", category: "strength", areas: ["legs"], equipment: ["stability_ball"], cues: [] };
const date = (iso) => `day ${iso}`;

test("matches every search word against the name, cues, areas and equipment", () => {
  assert.ok(matches(squat, { query: "squat" }));
  assert.ok(matches(squat, { query: "GOBLET  heels" }));
  assert.ok(matches(squat, { query: "dumbbells", names: { dumbbell: "Dumbbells" } }));
  assert.ok(matches(plank, { query: "core" }));
  assert.ok(matches(curl, { query: "swiss-ball" }));
  assert.ok(!matches(squat, { query: "squat plank" }));
  assert.ok(matches(squat, { query: "  " }));
});

test("filters by body area and equipment", () => {
  assert.ok(matches(squat, { area: "legs" }));
  assert.ok(!matches(plank, { area: "legs" }));
  assert.ok(matches(squat, { equipment: "dumbbell" }));
  assert.ok(!matches(plank, { equipment: "dumbbell" }));
  assert.ok(matches(plank, { equipment: BODYWEIGHT }));
  assert.ok(!matches(squat, { equipment: BODYWEIGHT }));
});

test("finds exercises that need just a weight under any gear in set weights", () => {
  const inventory = [
    { slug: "weight", unit: "lb", any_weight: true }, { slug: "dumbbell", unit: "lb", any_weight: false },
    { slug: "kettlebell", unit: "kg", any_weight: false }, { slug: "stability_ball", unit: null, any_weight: false },
  ];
  const row = { ...squat, equipment: ["weight"] };

  assert.deepEqual(standIns("dumbbell", inventory), ["weight"]);
  assert.deepEqual(standIns("kettlebell", inventory), ["weight"]);
  assert.deepEqual(standIns("stability_ball", inventory), []);
  assert.deepEqual(standIns("weight", inventory), []);
  assert.ok(matches(row, { equipment: "kettlebell", standIns: standIns("kettlebell", inventory) }));
  assert.ok(matches(row, { equipment: "weight" }));
  assert.ok(!matches(row, { equipment: "stability_ball", standIns: standIns("stability_ball", inventory) }));
  assert.deepEqual([...gearUsed([row, curl], inventory)].sort(), ["dumbbell", "kettlebell", "stability_ball", "weight"]);
  assert.deepEqual([...gearUsed([curl], inventory)], ["stability_ball"]);
});

test("keeps to what is owned when asked", () => {
  const owned = new Set(["dumbbell"]);
  assert.ok(matches(squat, { owned }));
  assert.ok(matches(plank, { owned }));
  assert.ok(!matches(curl, { owned }));
  assert.ok(matches(curl, { owned: null }));
});

test("counts what is shown", () => {
  assert.equal(countLine(33, 33), "33 exercises");
  assert.equal(countLine(1, 1), "1 exercise");
  assert.equal(countLine(28, 28, { owned: true }), "28 with your gear");
  assert.equal(countLine(31, 31, { owned: true, more: 10 }), "31 with your gear, 10 more with other gear");
  assert.equal(countLine(4, 28, { owned: true, filtered: true, more: 10 }), "4 of 28 with your gear");
  assert.equal(countLine(4, 33, { filtered: true }), "4 of 33 exercises");
  assert.equal(countLine(22, 22, { owned: true, ownsNothing: true }), "22 that need no gear");
  assert.equal(countLine(22, 22, { owned: true, ownsNothing: true, more: 19 }), "22 that need no gear");
  assert.equal(countLine(41, 41, { ownsNothing: true }), "41 exercises");
});

test("says when an exercise was last done and its best set", () => {
  const weighted = { last_date: "2026-10-16", last_set: { reps: 8, seconds: null, weight: { value: 40, unit: "lb" } } };
  assert.equal(lastLine(weighted, "lb", date), "Last: day 2026-10-16 · 40 lb × 8");
  assert.equal(lastLine(weighted, "kg", date), "Last: day 2026-10-16 · 18 kg × 8");
  assert.equal(lastLine({ last_date: "2026-10-16", last_set: { reps: 12, seconds: null, weight: null } }, "lb", date), "Last: day 2026-10-16 · 12");
  assert.equal(lastLine({ last_date: "2026-10-16", last_set: { reps: null, seconds: 30, weight: null } }, "lb", date), "Last: day 2026-10-16 · 30 s");
  assert.equal(lastLine({ last_date: "2026-10-16" }, "lb", date), "Last: day 2026-10-16");
  assert.equal(lastLine(undefined, "lb", date), "");
});

test("names the workouts that use an exercise, main workouts first", () => {
  const programs = [{
    workouts: [
      { title: "Warm-up", kind: "warmup", exercise_ids: [2] },
      { title: "Workout 1", kind: "workout", exercise_ids: [1, 2] },
      { title: "Workout 2", kind: "workout", exercise_ids: [2] },
    ],
  }];
  assert.equal(usedInLine(programs, 2), "In: Workout 1, Workout 2, Warm-up");
  assert.equal(usedInLine(programs, 1), "In: Workout 1");
  assert.equal(usedInLine(programs, 3), "");
  assert.equal(usedInLine(null, 1), "");
});

test("labels body areas", () => {
  assert.equal(areaLabel("upper_body"), "Upper body");
  assert.equal(areaLabel("other"), "other");
});
