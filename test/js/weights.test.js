import { test } from "node:test";
import assert from "node:assert/strict";
import {
  stepWeight, stepTargetWeight, sameWeight, formatWeight, inUnit, sameShownWeight, preferredUnit, setPreferredUnit,
  formatLoad, unitRequest, adoptServerUnit,
} from "../../public/js/weights.js";

const table = {
  default: { lb: [{ step: 5 }], kg: [{ step: 2.5 }] },
  dumbbell: { lb: [{ below: 15, step: 2.5 }, { step: 5 }], kg: [{ below: 7, step: 1 }, { step: 2.5 }] },
};

test("steps 5 lb or 2.5 kg by default", () => {
  assert.equal(stepWeight(40, "lb", ["band"], "up", table), 45);
  assert.equal(stepWeight(20, "kg", [], "down", table), 17.5);
});

test("steps light dumbbells in smaller increments, both ways across the band", () => {
  assert.equal(stepWeight(10, "lb", ["dumbbell"], "up", table), 12.5);
  assert.equal(stepWeight(12.5, "lb", ["dumbbell"], "up", table), 15);
  assert.equal(stepWeight(15, "lb", ["dumbbell"], "up", table), 20);
  assert.equal(stepWeight(20, "lb", ["dumbbell"], "down", table), 15);
  assert.equal(stepWeight(15, "lb", ["dumbbell"], "down", table), 12.5);
});

test("never goes below zero", () => {
  assert.equal(stepWeight(2.5, "lb", ["dumbbell"], "down", table), 0);
  assert.equal(stepWeight(0, "lb", ["dumbbell"], "down", table), 0);
});

test("formats whole and fractional weights", () => {
  assert.equal(formatWeight({ value: 40, unit: "lb" }), "40 lb");
  assert.equal(formatWeight({ value: 12.5, unit: "lb" }), "12.5 lb");
  assert.equal(formatWeight(null), "");
});

test("converts between lb and kg, rounded to the nearest half", () => {
  assert.deepEqual(inUnit({ value: 40, unit: "lb" }, "kg"), { value: 18, unit: "kg" });
  assert.deepEqual(inUnit({ value: 10, unit: "lb" }, "kg"), { value: 4.5, unit: "kg" });
  assert.deepEqual(inUnit({ value: 5, unit: "lb" }, "kg"), { value: 2.5, unit: "kg" });
  assert.deepEqual(inUnit({ value: 20, unit: "kg" }, "lb"), { value: 44, unit: "lb" });
  assert.deepEqual(inUnit({ value: 18, unit: "kg" }, "lb"), { value: 39.5, unit: "lb" });
});

test("leaves a weight already in the unit, or with no unit asked for, as it is", () => {
  assert.deepEqual(inUnit({ value: 12.5, unit: "lb" }, "lb"), { value: 12.5, unit: "lb" });
  assert.deepEqual(inUnit({ value: 12.5, unit: "lb" }), { value: 12.5, unit: "lb" });
  assert.equal(inUnit(null, "kg"), null);
});

test("formats a weight in the shown unit", () => {
  assert.equal(formatWeight({ value: 40, unit: "lb" }, "kg"), "18 kg");
  assert.equal(formatWeight({ value: 15, unit: "lb" }, "kg"), "7 kg");
  assert.equal(formatWeight({ value: 40, unit: "lb" }, "lb"), "40 lb");
});

test("steps to the next owned weight, like Coach.step_weight", () => {
  assert.equal(stepWeight(10, "lb", ["dumbbell"], "up", table, [10, 20]), 20);
  assert.equal(stepWeight(20, "lb", ["dumbbell"], "down", table, [10, 20]), 10);
  assert.equal(stepWeight(15, "lb", ["dumbbell"], "up", table, [10, 20]), 20);
  assert.equal(stepWeight(15, "lb", ["dumbbell"], "down", table, [10, 20]), 10);
});

test("stays put with nothing further owned", () => {
  assert.equal(stepWeight(10, "lb", ["dumbbell"], "down", table, [10, 20]), 10);
  assert.equal(stepWeight(20, "lb", ["dumbbell"], "up", table, [10, 20]), 20);
  assert.equal(stepWeight(40, "lb", ["kettlebell"], "up", table, [40]), 40);
});

test("steps by band without owned weights", () => {
  assert.equal(stepWeight(10, "lb", ["dumbbell"], "up", table, []), 12.5);
  assert.equal(stepWeight(10, "lb", ["dumbbell"], "up", table, null), 12.5);
});

test("rejects an unknown direction", () => {
  assert.throws(() => stepWeight(10, "lb", [], "sideways", table), /unknown direction/);
});

test("steps a target weight in its own unit, whatever is shown", () => {
  const fly = { value: 10, unit: "lb" };
  assert.deepEqual(stepTargetWeight(fly, ["dumbbell"], "up", table, [10, 20]), { value: 20, unit: "lb" });
  assert.deepEqual(stepTargetWeight({ value: 40, unit: "lb" }, ["band"], "up", table), { value: 45, unit: "lb" });
  assert.deepEqual(stepTargetWeight({ value: 20, unit: "kg" }, ["band"], "down", table), { value: 17.5, unit: "kg" });
});

test("starts a step without a weight at the lightest owned weight, and leaves it without one going down", () => {
  assert.deepEqual(stepTargetWeight(null, ["dumbbell"], "up", table, [10, 20], "lb"), { value: 10, unit: "lb" });
  assert.equal(stepTargetWeight(null, ["dumbbell"], "down", table, [10, 20], "lb"), null);
  assert.equal(stepTargetWeight(null, ["mat"], "up", table, null, null), null);
  assert.ok(stepTargetWeight(null, ["dumbbell"], "up", table, null, "kg").value > 0);
});

test("steps down from the lightest weight to no weight, and back up", () => {
  assert.equal(stepTargetWeight({ value: 10, unit: "lb" }, ["dumbbell"], "down", table, [10, 20], "lb"), null);
  assert.equal(stepTargetWeight({ value: 2.5, unit: "lb" }, ["band"], "down", table, null, "lb"), null);
  assert.equal(stepTargetWeight({ value: 0, unit: "lb" }, ["dumbbell"], "down", table, [10, 20], "lb"), null);
  assert.deepEqual(stepTargetWeight(null, ["dumbbell"], "up", table, [10, 20], "lb"), { value: 10, unit: "lb" });
  // At the heaviest owned weight, up changes nothing.
  assert.ok(sameWeight(stepTargetWeight({ value: 20, unit: "lb" }, ["dumbbell"], "up", table, [10, 20], "lb"), { value: 20, unit: "lb" }));
});

test("tells a changed weight from the same one, no weight included", () => {
  assert.equal(sameWeight(null, null), true);
  assert.equal(sameWeight(null, { value: 10, unit: "lb" }), false);
  assert.equal(sameWeight({ value: 10, unit: "lb" }, { value: 10.001, unit: "lb" }), true);
  assert.equal(sameWeight({ value: 10, unit: "lb" }, { value: 10, unit: "kg" }), false);
});

test("compares weights as they are shown", () => {
  assert.equal(sameShownWeight({ value: 40, unit: "lb" }, { value: 18, unit: "kg" }, "kg"), true);
  assert.equal(sameShownWeight({ value: 40, unit: "lb" }, { value: 18, unit: "kg" }, "lb"), false);
  assert.equal(sameShownWeight({ value: 40, unit: "lb" }, { value: 20.5, unit: "kg" }, "kg"), false);
});

test("keeps the unit setting in storage, lb until it is set", () => {
  const items = new Map();
  const storage = { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v) };
  assert.equal(preferredUnit(storage), "lb");
  setPreferredUnit(storage, "kg");
  assert.equal(preferredUnit(storage), "kg");
  items.set("unit", "stone");
  assert.equal(preferredUnit(storage), "lb");
  assert.throws(() => setPreferredUnit(storage, "stone"));
});

test("reads lb when storage is blocked", () => {
  const blocked = { getItem: () => { throw new Error("blocked"); }, setItem: () => { throw new Error("blocked"); } };
  assert.equal(preferredUnit(blocked), "lb");
  assert.equal(preferredUnit(null), "lb");
  setPreferredUnit(blocked, "kg");
});

test("changes the unit on the server", () => {
  assert.deepEqual(unitRequest("kg"), { method: "PATCH", path: "/api/settings", body: { unit: "kg" } });
  assert.throws(() => unitRequest("stone"));
});

test("takes the server's unit unless a change made here is still on its way", () => {
  const items = new Map([["unit", "lb"]]);
  const storage = { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v) };

  assert.equal(adoptServerUnit(storage, "kg"), "kg");
  assert.equal(preferredUnit(storage), "kg");

  setPreferredUnit(storage, "lb");
  assert.equal(adoptServerUnit(storage, "kg", { queued: [unitRequest("lb")] }), "lb");
  assert.equal(adoptServerUnit(storage, "kg", { stale: true }), "lb");
  assert.equal(adoptServerUnit(storage, undefined), "lb");
  assert.equal(preferredUnit(storage), "lb");
});

test("shows a load the way it is picked up", () => {
  assert.equal(formatLoad({ value: 20, unit: "lb" }, 2, "lb"), "2 × 20 lb");
  assert.equal(formatLoad({ value: 40, unit: "lb" }, 1, "lb"), "1 × 40 lb");
  assert.equal(formatLoad({ value: 10, unit: "lb" }, undefined, "lb"), "1 × 10 lb");
  assert.equal(formatLoad(null, 2, "lb"), "");
});
