import { readSettings, vibrationPattern } from "./preferences.js";

// Short synthesized beeps, and a buzz where the phone can, as set on the
// Settings page. Browsers only allow audio after a user gesture, so call
// unlock() from the Start button's click handler.
//
// The beeps mix with whatever else is playing (music, a podcast) and follow
// the device's mute setting and volume: where the browser lets a page say so
// (Safari's navigator.audioSession), the session is "ambient", the kind
// that neither stops other audio nor sounds when muted. A call, Siri or a
// switch to another app suspends the audio (Safari calls it
// "interrupted"); it is resumed when the page is back, and failing that on
// the next tap, which every browser counts as a gesture.
let context = null;
// A beep was asked for before any audio was unlocked (a session restored
// after a reload, say): the next tap anywhere unlocks it.
let wanted = false;

export function unlock() {
  if (!context) {
    const Context = globalThis.AudioContext;
    if (!Context) return;
    if (navigator.audioSession) {
      try {
        navigator.audioSession.type = "ambient";
      } catch {
        // An older session API: the browser's default stands.
      }
    }
    context = new Context();
    // Stopped while the page shows (Siri over it, say): started again. A
    // hidden page is left stopped; coming back resumes it.
    context.addEventListener("statechange", resume);
  }
  resume();
}

// Whether the audio has stopped and should be started again.
export function needsResume(state) {
  return state === "suspended" || state === "interrupted";
}

function resume() {
  if (context && needsResume(context.state) && !globalThis.document?.hidden) context.resume().catch(() => {});
}

// Back from a call, Siri or another app, and on any tap while stopped: the
// browser may only allow a resume then.
// (Not in node, where the tests import this for needsResume.)
if (globalThis.document) {
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") resume();
  });
  window.addEventListener("pageshow", resume);
  const gesture = () => (wanted && !context ? unlock() : resume());
  for (const type of ["pointerdown", "keydown"]) document.addEventListener(type, gesture, { capture: true, passive: true });
}

function tone(frequency, duration, delay = 0) {
  if (!context) {
    wanted = true;
    return;
  }
  // Interrupted, or out of sight, the clock stands still: a tone scheduled
  // now would sound late, together with every other one, on the way back.
  if (context.state === "interrupted" || globalThis.document?.hidden) return;
  const at = context.currentTime + delay;
  const osc = context.createOscillator();
  const gain = context.createGain();
  osc.frequency.value = frequency;
  gain.gain.setValueAtTime(0.0001, at);
  gain.gain.exponentialRampToValueAtTime(0.4, at + 0.01);
  gain.gain.exponentialRampToValueAtTime(0.0001, at + duration);
  osc.connect(gain).connect(context.destination);
  osc.start(at);
  osc.stop(at + duration + 0.02);
}

export function beep(cue) {
  const { sound, vibration } = readSettings(storage());
  const pattern = vibrationPattern(cue);
  if (vibration && pattern) navigator.vibrate?.(pattern);
  if (sound) play(cue);
}

// Settings' Test sound: a countdown tick, then the start beep, whatever the
// Beeps setting, so the volume and mute can be checked before a workout.
// False where the browser has no audio, or won't start it.
export async function testSound() {
  unlock();
  if (!context) return false;
  if (context.state !== "running") await context.resume().catch(() => {});
  if (context.state !== "running") return false;
  play("tick");
  play("start", 0.4);
  return true;
}

function storage() {
  try {
    return localStorage;
  } catch {
    return { getItem: () => null };
  }
}

function play(cue, delay = 0) {
  switch (cue) {
    case "start": tone(1320, 0.35, delay); break;
    case "tick": tone(880, 0.12, delay); break;
    case "end": tone(660, 0.2, delay); tone(660, 0.2, delay + 0.25); break;
    // Rising pair, unlike the falling end beep, so it is heard as "now the other side".
    case "switch": tone(880, 0.15, delay); tone(1320, 0.25, delay + 0.18); break;
  }
}
