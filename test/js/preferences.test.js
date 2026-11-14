import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULTS, LEAD_IN_CHOICES, readSettings, writeSetting, vibrationPattern } from "../../public/js/preferences.js";

function memoryStorage(initial = {}) {
  const items = new Map(Object.entries(initial));
  return { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v) };
}

test("reads the defaults from empty, broken or blocked storage", () => {
  assert.deepEqual(readSettings(memoryStorage()), DEFAULTS);
  assert.deepEqual(readSettings(memoryStorage({ settings: "{not json" })), DEFAULTS);
  assert.deepEqual(readSettings(null), DEFAULTS);
  assert.deepEqual(readSettings({ getItem: () => { throw new Error("SecurityError"); } }), DEFAULTS);
});

test("keeps each valid setting and replaces only the bad ones", () => {
  const storage = memoryStorage({ settings: JSON.stringify({ sound: false, vibration: "yes", leadIn: 7, askRpe: "no" }) });
  assert.deepEqual(readSettings(storage), { sound: false, vibration: true, leadIn: 5, askRpe: true });
});

test("saves one setting at a time and reads it back", () => {
  const storage = memoryStorage();
  writeSetting(storage, "leadIn", 10);
  writeSetting(storage, "sound", false);
  writeSetting(storage, "askRpe", false);
  assert.deepEqual(readSettings(storage), { sound: false, vibration: true, leadIn: 10, askRpe: false });
});

test("refuses unknown settings and values it would not read back", () => {
  const storage = memoryStorage();
  assert.throws(() => writeSetting(storage, "volume", 3), /unknown setting/);
  assert.throws(() => writeSetting(storage, "leadIn", 7), /bad value/);
  assert.throws(() => writeSetting(storage, "sound", "off"), /bad value/);
  assert.ok(LEAD_IN_CHOICES.includes(DEFAULTS.leadIn));
});

test("still returns the setting when storage will not save", () => {
  const storage = { getItem: () => null, setItem: () => { throw new Error("QuotaExceededError"); } };
  assert.equal(writeSetting(storage, "vibration", false).vibration, false);
});

test("has a vibration pattern for every beeper cue", () => {
  for (const cue of ["start", "tick", "end", "switch"]) assert.ok(vibrationPattern(cue).length > 0, cue);
  assert.equal(vibrationPattern("nonsense"), null);
});
