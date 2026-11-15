import { test } from "node:test";
import assert from "node:assert/strict";
import { parseWeight, withWeight, quickWeights, doable } from "../../public/js/inventory.js";

test("reads one weight, with or without a unit after it", () => {
  assert.deepEqual(parseWeight("20"), { weight: 20 });
  assert.deepEqual(parseWeight(" 2.5 "), { weight: 2.5 });
  assert.deepEqual(parseWeight("2,5"), { weight: 2.5 });
  assert.deepEqual(parseWeight("20lb", "lb"), { weight: 20 });
  assert.deepEqual(parseWeight("16 KG", "kg"), { weight: 16 });
  assert.deepEqual(parseWeight("16 kgs"), { weight: 16 });
});

test("refuses the other unit rather than reading it as this one", () => {
  assert.equal(parseWeight("35 lb", "kg").error, "These are in kg: switch to lb first, or type the weight in kg.");
});

test("rejects anything that is not one positive number", () => {
  for (const text of ["", "heavy", "0", "-5", "2x10", "10, 20", "20 stone", "1,000", "10,"]) {
    assert.ok(parseWeight(text).error, text);
  }
  assert.equal(parseWeight("2x10").error, '"2x10" is not a weight: type a number, such as 20.');
});

test("adds a weight in order, once", () => {
  assert.deepEqual(withWeight([10, 30], 20), [10, 20, 30]);
  assert.deepEqual(withWeight([10], 10), [10]);
  assert.deepEqual(withWeight(undefined, 5), [5]);
});

test("offers the common sizes of the gear not listed yet, in the unit", () => {
  assert.deepEqual(quickWeights("kettlebell", "kg", [8, 12, 16, 20, 24]), [4, 6]);
  assert.deepEqual(quickWeights("dumbbell", "kg", [1, 2, 4, 5, 10]), [2.5, 7.5, 12.5]);
  assert.deepEqual(quickWeights("something-else", "lb", [5, 8, 10, 12, 15, 20, 25]), [30]);
  assert.deepEqual(quickWeights("dumbbell", undefined, []), []);
});

test("an exercise is doable when everything it needs is owned", () => {
  const owned = new Set(["dumbbell", "bench"]);
  assert.equal(doable({ equipment: ["dumbbell", "bench"] }, owned), true);
  assert.equal(doable({ equipment: [] }, owned), true);
  assert.equal(doable({ equipment: ["dumbbell", "stability_ball"] }, owned), false);
});
