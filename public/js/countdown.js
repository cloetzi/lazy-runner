// Pure countdown logic for the player, kept free of the DOM so it can be tested.
// Times are in milliseconds; callers pass `now` so tests control the clock.

export function createCountdown(seconds) {
  return { totalMs: seconds * 1000, elapsedMs: 0, startedAt: null };
}

export function start(countdown, now) {
  if (countdown.startedAt !== null) return countdown;
  return { ...countdown, startedAt: now };
}

export function pause(countdown, now) {
  if (countdown.startedAt === null) return countdown;
  return { ...countdown, elapsedMs: elapsed(countdown, now), startedAt: null };
}

// More time on the clock, from wherever it is.
export function extend(countdown, seconds) {
  return { ...countdown, totalMs: countdown.totalMs + seconds * 1000 };
}

export function isRunning(countdown) {
  return countdown.startedAt !== null;
}

export function elapsed(countdown, now) {
  const running = countdown.startedAt === null ? 0 : now - countdown.startedAt;
  return Math.min(countdown.totalMs, countdown.elapsedMs + running);
}

export function remainingMs(countdown, now) {
  return countdown.totalMs - elapsed(countdown, now);
}

// Whole seconds shown on screen: 20.0 s left shows 20, 19.2 s left shows 20.
export function displaySeconds(countdown, now) {
  return Math.ceil(remainingMs(countdown, now) / 1000);
}

export function isFinished(countdown, now) {
  return remainingMs(countdown, now) <= 0;
}

// Audio cues crossed between two moments: "start" when the countdown begins,
// "tick" at 3, 2 and 1 seconds left, and "end" when it reaches zero.
export function cuesBetween(countdown, beforeMs, afterMs) {
  const cues = [];
  const left = (t) => countdown.totalMs - Math.min(countdown.totalMs, t);
  const leftBefore = left(beforeMs);
  const leftAfter = left(afterMs);

  if (beforeMs <= 0 && afterMs > 0) cues.push("start");
  for (const mark of [3000, 2000, 1000]) {
    if (mark < countdown.totalMs && leftBefore > mark && leftAfter <= mark) cues.push("tick");
  }
  if (leftBefore > 0 && leftAfter <= 0) cues.push("end");
  return cues;
}
