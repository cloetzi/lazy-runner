import { test } from "node:test";
import assert from "node:assert/strict";
import {
  extend, elapsed,
  createCountdown, start, pause, isRunning, remainingMs, displaySeconds, isFinished, cuesBetween,
  createCountUp, filled,
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

test("a count-up shows the seconds gone and never finishes", () => {
  const c = start(createCountUp([{ seconds: 30, cue: "target" }]), 1000);
  assert.equal(displaySeconds(c, 1000), 0);
  assert.equal(displaySeconds(c, 19_900), 18);
  assert.equal(displaySeconds(c, 73_000), 72);
  assert.equal(isFinished(c, 999_999), false);
});

test("a count-up fills toward its target and stays full past it", () => {
  const c = start(createCountUp([{ seconds: 30, cue: "switch" }, { seconds: 60, cue: "target" }]), 0);
  assert.equal(filled(c, 15_000), 0.25);
  assert.equal(filled(c, 90_000), 1);
  assert.equal(filled(start(createCountUp(), 0), 90_000), 0);
});

test("a count-up pauses and goes on like a countdown", () => {
  let c = start(createCountUp(), 0);
  c = pause(c, 4000);
  assert.equal(displaySeconds(c, 60_000), 4);
  c = start(c, 60_000);
  assert.equal(displaySeconds(c, 62_000), 6);
});

test("a count-up cues its start and each mark, with no ticks", () => {
  const c = createCountUp([{ seconds: 30, cue: "switch" }, { seconds: 60, cue: "target" }]);
  const cues = [];
  for (let t = -100; t <= 70_000; t += 100) cues.push(...cuesBetween(c, t, t + 100));
  assert.deepEqual(cues, ["start", "switch", "target"]);
  assert.deepEqual(cuesBetween(c, 25_000, 65_000), ["switch", "target"]);
});
