import { test } from "node:test";
import assert from "node:assert/strict";
import { parseWeights, formatWeights, doable } from "../../public/js/inventory.js";

test("reads weights separated by commas or spaces, sorted and without repeats", () => {
  assert.deepEqual(parseWeights("20, 10 10  2.5"), { weights: [2.5, 10, 20] });
  assert.deepEqual(parseWeights(" "), { weights: [] });
});

test("rejects anything that is not a positive number", () => {
  assert.deepEqual(parseWeights("10, heavy, 0"), { error: "Not a weight: heavy, 0" });
  assert.deepEqual(parseWeights("-5"), { error: "Not a weight: -5" });
});

test("formats weights back for the field", () => {
  assert.equal(formatWeights([10, 20]), "10, 20");
  assert.equal(formatWeights(undefined), "");
});

test("an exercise is doable when everything it needs is owned", () => {
  const owned = new Set(["dumbbell", "bench"]);
  assert.equal(doable({ equipment: ["dumbbell", "bench"] }, owned), true);
  assert.equal(doable({ equipment: [] }, owned), true);
  assert.equal(doable({ equipment: ["dumbbell", "stability_ball"] }, owned), false);
});
