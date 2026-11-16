// Pure countdown logic for the player, kept free of the DOM so it can be tested.
// Times are in milliseconds; callers pass `now` so tests control the clock.

export function createCountdown(seconds) {
  return { totalMs: seconds * 1000, elapsedMs: 0, startedAt: null };
}

// A clock that counts up and never finishes, for a stretch held as long as
// it feels right. `marks` are the moments worth a cue ({ seconds, cue }, in
// order), the last one the target; its total is that target, or 0 with none.
export function createCountUp(marks = []) {
  const marksMs = marks.map(({ seconds, cue }) => ({ ms: seconds * 1000, cue }));
  return { totalMs: marksMs.at(-1)?.ms ?? 0, elapsedMs: 0, startedAt: null, up: true, marks: marksMs };
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
  const total = countdown.elapsedMs + running;
  return countdown.up ? total : Math.min(countdown.totalMs, total);
}

export function remainingMs(countdown, now) {
  return countdown.totalMs - elapsed(countdown, now);
}

// Whole seconds shown on screen: 20.0 s left shows 20, 19.2 s left shows 20.
// Counting up, the whole seconds gone: 19.8 s shows 19.
export function displaySeconds(countdown, now) {
  if (countdown.up) return Math.floor(elapsed(countdown, now) / 1000);
  return Math.ceil(remainingMs(countdown, now) / 1000);
}

export function isFinished(countdown, now) {
  return !countdown.up && remainingMs(countdown, now) <= 0;
}

// How far a count-up has got to its target, 0 to 1 (1 past it, 0 with none).
export function filled(countdown, now) {
  if (!countdown.totalMs) return 0;
  return Math.min(1, elapsed(countdown, now) / countdown.totalMs);
}

// Audio cues crossed between two moments: "start" when the countdown begins,
// "tick" at 3, 2 and 1 seconds left, and "end" when it reaches zero.
// A count-up gives "start" and the cue of each mark it passes, nothing more.
export function cuesBetween(countdown, beforeMs, afterMs) {
  const cues = [];
  if (countdown.up) {
    if (beforeMs <= 0 && afterMs > 0) cues.push("start");
    for (const mark of countdown.marks ?? []) {
      if (beforeMs < mark.ms && afterMs >= mark.ms) cues.push(mark.cue);
    }
    return cues;
  }
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
