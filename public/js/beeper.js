import { readSettings, vibrationPattern } from "./preferences.js";

// Short synthesized beeps, and a buzz where the phone can, as set on the
// Settings page. Browsers only allow audio after a user gesture, so call
// unlock() from the Start button's click handler.
let context = null;

export function unlock() {
  context ??= new AudioContext();
  if (context.state === "suspended") context.resume();
}

function tone(frequency, duration, delay = 0) {
  if (!context) return;
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

function storage() {
  try {
    return localStorage;
  } catch {
    return { getItem: () => null };
  }
}

function play(cue) {
  switch (cue) {
    case "start": tone(1320, 0.35); break;
    case "tick": tone(880, 0.12); break;
    case "end": tone(660, 0.2); tone(660, 0.2, 0.25); break;
    // Rising pair, unlike the falling end beep, so it is heard as "now the other side".
    case "switch": tone(880, 0.15); tone(1320, 0.25, 0.18); break;
  }
}
