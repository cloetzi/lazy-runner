import { test } from "node:test";
import assert from "node:assert/strict";
import { createRunStore, restoredTimer, RUN_KEY } from "../../public/js/run-store.js";
import * as countdown from "../../public/js/countdown.js";

function memoryStorage() {
  const items = new Map();
  return { items, getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v), removeItem: (k) => items.delete(k) };
}

const blocked = {
  getItem: () => { throw new Error("SecurityError"); },
  setItem: () => { throw new Error("QuotaExceededError"); },
  removeItem: () => { throw new Error("SecurityError"); },
};

test("saves a run and loads it back after a reload", () => {
  const storage = memoryStorage();
  const run = { id: "a1", index: 3, logged: { 0: "done" }, stage: "player" };

  assert.equal(createRunStore(storage).save(run, { now: 1000 }), true);

  assert.deepEqual(createRunStore(storage).load(), { ...run, touchedAt: 1000, timer: null });
  assert.ok(storage.items.has(RUN_KEY));
});

test("keeps where a running countdown was", () => {
  const storage = memoryStorage();
  const timer = countdown.start(countdown.createCountdown(30), 0);
  const run = { id: "a1" };

  createRunStore(storage).save(run, { now: 5, phase: "work", timer, timerNow: 12_000 });

  assert.deepEqual(createRunStore(storage).load().timer, { phase: "work", totalMs: 30_000, elapsedMs: 12_000 });
});

test("brings a countdown back paused where it was", () => {
  const { phase, timer } = restoredTimer({ phase: "rest", totalMs: 60_000, elapsedMs: 20_000 });

  assert.equal(phase, "rest");
  assert.equal(countdown.isRunning(timer), false);
  assert.equal(countdown.remainingMs(timer, 999_999), 40_000);
  assert.equal(restoredTimer(null), null);
});

test("clears the saved run", () => {
  const storage = memoryStorage();
  const store = createRunStore(storage);
  store.save({ id: "a1" });

  store.clear();

  assert.equal(store.load(), null);
});

test("loads nothing from an empty or broken entry", () => {
  const storage = memoryStorage();
  assert.equal(createRunStore(storage).load(), null);
  storage.setItem(RUN_KEY, "{not json");
  assert.equal(createRunStore(storage).load(), null);
});

test("keeps running when storage is blocked", () => {
  const store = createRunStore(blocked);

  assert.equal(store.save({ id: "a1" }), false);
  assert.equal(store.load(), null);
  store.clear();
});

test("keeps a stretch's count-up and its cues, and brings it back counting up", () => {
  const storage = memoryStorage();
  const marks = [{ seconds: 30, cue: "switch" }, { seconds: 60, cue: "target" }];
  const run = { id: "a1" };

  createRunStore(storage).save(run, { now: 5, phase: "hold", timer: countdown.start(countdown.createCountUp(marks), 0), timerNow: 72_000 });
  const saved = createRunStore(storage).load().timer;
  const { phase, timer } = restoredTimer(saved);

  assert.deepEqual(saved, { phase: "hold", totalMs: 60_000, elapsedMs: 72_000, up: true, marks: [{ ms: 30_000, cue: "switch" }, { ms: 60_000, cue: "target" }] });
  assert.equal(phase, "hold");
  assert.equal(countdown.isRunning(timer), false);
  assert.equal(countdown.displaySeconds(timer, 0), 72);
  assert.equal(countdown.isFinished(timer, 0), false);
});
