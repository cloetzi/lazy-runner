import { test } from "node:test";
import assert from "node:assert/strict";
import {
  extend, elapsed,
  createCountdown, start, pause, isRunning, remainingMs, displaySeconds, isFinished, cuesBetween,
} from "../../public/js/countdown.js";

test("counts down from start", () => {
  const c = start(createCountdown(20), 1000);
  assert.equal(displaySeconds(c, 1000), 20);
  assert.equal(displaySeconds(c, 1800), 20);
  assert.equal(displaySeconds(c, 2000), 19);
  assert.equal(isFinished(c, 20999), false);
  assert.equal(isFinished(c, 21000), true);
});

test("never goes below zero", () => {
  const c = start(createCountdown(5), 0);
  assert.equal(remainingMs(c, 99_000), 0);
});

test("pause freezes the remaining time and resume continues it", () => {
  let c = start(createCountdown(10), 0);
  c = pause(c, 4000);
  assert.equal(isRunning(c), false);
  assert.equal(remainingMs(c, 60_000), 6000);
  c = start(c, 60_000);
  assert.equal(remainingMs(c, 61_000), 5000);
});

test("start is a no-op while running", () => {
  const c = start(createCountdown(10), 0);
  assert.equal(start(c, 5000), c);
});

test("cues start, 3-2-1 and end", () => {
  const c = createCountdown(10);
  const cues = [];
  for (let t = -100; t <= 10_100; t += 100) cues.push(...cuesBetween(c, t, t + 100));
  assert.deepEqual(cues, ["start", "tick", "tick", "tick", "end"]);
});

test("a large frame gap still emits every crossed cue once", () => {
  const c = createCountdown(10);
  assert.deepEqual(cuesBetween(c, 6500, 10_500), ["tick", "tick", "tick", "end"]);
  assert.deepEqual(cuesBetween(c, 10_500, 11_000), []);
});

test("short countdowns skip ticks at or above their length", () => {
  const c = createCountdown(2);
  const cues = [];
  for (let t = -100; t <= 2100; t += 100) cues.push(...cuesBetween(c, t, t + 100));
  assert.deepEqual(cues, ["start", "tick", "end"]);
});

test("extend adds time and keeps what has elapsed", () => {
  const running = start(createCountdown(5), 0);
  const longer = extend(running, 10);

  assert.equal(displaySeconds(longer, 3000), 12);
  assert.equal(elapsed(longer, 3000), 3000);
});
