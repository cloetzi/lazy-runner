// Keeps the running session in storage so a reload or an app switch picks it
// up, kept free of the DOM so save and restore can be tested. Storage can be
// blocked or full: the session still runs, it just won't survive a reload.
import * as countdown from "./countdown.js";

export const RUN_KEY = "run";

export function createRunStore(storage, key = RUN_KEY) {
  return {
    // Stamps the run and keeps where its countdown was, paused.
    save(run, { now = Date.now(), phase = null, timer = null, timerNow = 0 } = {}) {
      run.touchedAt = now;
      run.timer = timer && { phase, totalMs: timer.totalMs, elapsedMs: countdown.elapsed(timer, timerNow) };
      try {
        storage.setItem(key, JSON.stringify(run));
        return true;
      } catch {
        return false;
      }
    },

    load() {
      try {
        return JSON.parse(storage.getItem(key));
      } catch {
        return null;
      }
    },

    clear() {
      try {
        storage.removeItem(key);
      } catch {
        // Nothing saved to clear.
      }
    },
  };
}

// The countdown a saved run comes back with: paused where it was, so nothing
// runs unseen.
export function restoredTimer(saved) {
  if (!saved) return null;
  return { phase: saved.phase, timer: { ...countdown.createCountdown(saved.totalMs / 1000), elapsedMs: saved.elapsedMs } };
}
