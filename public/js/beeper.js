import { readSettings, vibrationPattern } from "./preferences.js";

// Short synthesized beeps, and a buzz where the phone can, as set on the
// Settings page. Browsers only allow audio after a user gesture, so call
// unlock() from the Start button's click handler.
//
// The beeps follow the device's volume. Whether they sound on a muted iPad
// or iPhone is the "When muted" setting: Safari keeps Web Audio silent in
// silent mode unless the page's audio session (navigator.audioSession) is
// "playback", which in turn pauses other audio (music, a podcast) while the
// beeps play. With the setting off the session is "ambient": mixed with
// other audio, and silent when muted. A call, Siri or a switch to another
// app suspends the audio (Safari calls it "interrupted"); it is resumed
// when the page is back, and failing that on the next tap, which every
// browser counts as a gesture.
let context = null;
// A beep was asked for before any audio was unlocked (a session restored
// after a reload, say): the next tap anywhere unlocks it.
let wanted = false;

// The audio session type for the "When muted" setting.
export function audioSessionType({ playWhenMuted }) {
  return playWhenMuted ? "playback" : "ambient";
}

// Sets the page's audio session from the settings, where the browser has
// one (Safari 17 and later). Called again when the setting changes.
export function applyAudioSession() {
  const session = globalThis.navigator?.audioSession;
  if (!session) return;
  const type = audioSessionType(readSettings(storage()));
  try {
    if (session.type !== type) session.type = type;
  } catch {
    // An older session API: the browser's default stands.
  }
}

export function unlock() {
  if (!context) {
    const Context = globalThis.AudioContext ?? globalThis.webkitAudioContext;
    if (!Context) return;
    applyAudioSession();
    try {
      context = new Context();
    } catch {
      return; // Too many contexts, or audio switched off: no beeps.
    }
    // Stopped while the page shows (Siri over it, say): started again. A
    // hidden page is left stopped; coming back resumes it.
    context.addEventListener("statechange", resume);
  }
  resume();
  prime();
}

// Safari starts a context's output only once it has played something
// inside a gesture: one silent sample, played straight away.
function prime() {
  if (!context || context.state === "closed") return;
  try {
    const source = context.createBufferSource();
    source.buffer = context.createBuffer(1, 1, context.sampleRate);
    source.connect(context.destination);
    source.start(0);
  } catch {
    // Nothing to prime with: the beeps still try.
  }
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
  const gesture = () => {
    if (wanted && !context) unlock();
    else if (context && needsResume(context.state)) unlock();
  };
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
    // A stretch's target: one low, longer tone, a nudge rather than an alarm.
    case "target": tone(523, 0.6, delay); break;
  }
}
