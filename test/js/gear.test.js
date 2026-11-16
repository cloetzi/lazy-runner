import { test } from "node:test";
import assert from "node:assert/strict";
import { ownedSlugs, missingGear, gearChips, nameList, unlocks, unlocksLine, byFit, fitLine } from "../../public/js/gear.js";

const names = (slugs) => slugs.map((slug) => ({ dumbbell: "Dumbbells", kettlebell: "Kettlebell", weight: "Any weight" })[slug] ?? slug);

test("reads what is owned from the inventory, and nothing when it hasn't arrived", () => {
  const owned = ownedSlugs([{ slug: "dumbbell", owned: true }, { slug: "kettlebell", owned: false }, { slug: "weight", owned: true }]);
  assert.deepEqual([...owned], ["dumbbell", "weight"]);
  assert.equal(ownedSlugs(undefined), null);
});

test("lists the gear not owned, none when what is owned isn't known", () => {
  const owned = new Set(["dumbbell"]);
  assert.deepEqual(missingGear(["dumbbell", "kettlebell", "kettlebell"], owned), ["kettlebell"]);
  assert.deepEqual(missingGear(["kettlebell"], null), []);
  assert.deepEqual(missingGear(undefined, owned), []);
});

test("marks missing gear with a cross and words, not colour alone", () => {
  const html = String(gearChips(["dumbbell", "kettlebell"], { names, owned: new Set(["dumbbell"]) }));
  assert.match(html, /<li>Dumbbells<\/li>/);
  assert.match(html, /<li class="gear-missing"><svg[^]*#close[^]*Kettlebell[^]*not yours yet<\/span><\/li>/);
  assert.doesNotMatch(String(gearChips(["kettlebell"], { names, owned: null })), /not yours yet/);
  assert.equal(String(gearChips([], { names, owned: null })), "");
});

test("names gear in a sentence", () => {
  assert.equal(nameList(["Kettlebell"]), "Kettlebell");
  assert.equal(nameList(["Kettlebell", "Bench"]), "Kettlebell and Bench");
  assert.equal(nameList(["Kettlebell", "Bench", "Step"]), "Kettlebell, Bench and Step");
});

test("says what an item unlocks: the exercises that need it and the workouts that use it", () => {
  const inventory = [{ slug: "dumbbell", unit: "lb" }, { slug: "weight", any_weight: true, unit: "lb" }, { slug: "stability_ball" }];
  const exercises = [{ equipment: ["stability_ball"] }, { equipment: ["dumbbell"] }, { equipment: ["weight"] }, { equipment: [] }];
  const programs = [{ workouts: [
    { kind: "workout", title: "Session A", equipment: ["stability_ball"] },
    { kind: "warmup", title: "Warm-up", equipment: ["stability_ball"] },
    { kind: "workout", title: "Session B", equipment: ["weight"] },
  ] }];
  const ball = unlocks({ slug: "stability_ball" }, { exercises, programs, inventory });
  assert.deepEqual(ball, { exercises: 1, workouts: ["Session A"] });
  assert.equal(unlocksLine(ball), "1 exercise, used in Session A");
  // Dumbbells also do for what needs just a weight.
  assert.deepEqual(unlocks(inventory[0], { exercises, programs, inventory }), { exercises: 2, workouts: ["Session B"] });
  assert.equal(unlocksLine({ exercises: 3, workouts: [] }), "3 exercises");
  assert.equal(unlocksLine({ exercises: 0, workouts: [] }), "No exercise needs it yet");
});

test("puts the best-fitting example first and says how it fits", () => {
  const examples = [
    { slug: "cycle-1", missing_exercises: 6, gear: [{}] },
    { slug: "home-strength", missing_exercises: 1, gear: [{}] },
    { slug: "no-gear", missing_exercises: 0, gear: [] },
    { slug: "fits", missing_exercises: 0, gear: [{}] },
  ];
  assert.deepEqual(byFit(examples).map((e) => e.slug), ["no-gear", "fits", "home-strength", "cycle-1"]);
  assert.equal(fitLine(examples[0]), "6 exercises need gear you don't have");
  assert.equal(fitLine(examples[1]), "1 exercise needs gear you don't have");
  assert.equal(fitLine(examples[2]), "Needs no gear");
  assert.equal(fitLine(examples[3]), "Fits your gear");
});
