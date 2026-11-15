import { test } from "node:test";
import assert from "node:assert/strict";
import { unitSetting } from "../../public/js/unit-setting.js";

const memory = () => {
  const values = new Map();
  return { getItem: (key) => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) };
};
const setting = unitSetting({ field: "distance_unit", units: ["km", "mi"], key: "distanceUnit" });

test("keeps this device's copy, the first unit until anything is known", () => {
  const storage = memory();
  assert.equal(setting.preferred(storage), "km");
  setting.set(storage, "mi");
  assert.equal(setting.preferred(storage), "mi");
  assert.throws(() => setting.set(storage, "furlong"), /unknown distance_unit furlong/);
  assert.equal(setting.preferred({ getItem() { throw new Error("blocked"); } }), "km");
});

test("sends a change under its own field", () => {
  assert.deepEqual(setting.request("mi"), { method: "PATCH", path: "/api/settings", body: { distance_unit: "mi" } });
});

test("takes the server's unit unless a change of its own is queued or the answer is an offline copy", () => {
  const storage = memory();
  assert.equal(setting.adopt(storage, "mi"), "mi");
  assert.equal(setting.adopt(storage, "km", { stale: true }), "mi");
  assert.equal(setting.adopt(storage, "km", { queued: [setting.request("mi")] }), "mi");
  // Another setting's change doesn't hold this one back.
  assert.equal(setting.adopt(storage, "km", { queued: [{ method: "PATCH", path: "/api/settings", body: { unit: "kg" } }] }), "km");
});
