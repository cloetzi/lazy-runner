// Settings kept on this device, apart from lb or kg (preferredUnit in
// weights.js). Pure logic over a Storage-like object, so it is testable;
// settings.js draws the page and beeper.js and app.js read them.

export const LEAD_IN_CHOICES = [3, 5, 10];
// askRpe: Today asks how hard an activity sent from elsewhere was.
export const DEFAULTS = { sound: true, vibration: true, leadIn: 5, askRpe: true };
const KEY = "settings";

// Unknown or broken values fall back to the default, one setting at a time.
const VALID = {
  sound: (value) => typeof value === "boolean",
  vibration: (value) => typeof value === "boolean",
  leadIn: (value) => LEAD_IN_CHOICES.includes(value),
  askRpe: (value) => typeof value === "boolean",
};

export function readSettings(storage) {
  let stored = {};
  try {
    stored = JSON.parse(storage.getItem(KEY)) ?? {};
  } catch {
    // Blocked storage or bad JSON: the defaults.
  }
  return Object.fromEntries(Object.entries(DEFAULTS).map(([name, fallback]) =>
    [name, VALID[name](stored[name]) ? stored[name] : fallback]));
}

export function writeSetting(storage, name, value) {
  if (!VALID[name]) throw new Error(`unknown setting ${name}`);
  if (!VALID[name](value)) throw new Error(`bad value for ${name}: ${value}`);
  const settings = { ...readSettings(storage), [name]: value };
  try {
    storage.setItem(KEY, JSON.stringify(settings));
  } catch {
    // Blocked: the setting holds for this page only.
  }
  return settings;
}

// How long to buzz, in ms, for each beeper cue: one pulse to start, a short
// tick, two pulses at the end and a long-short pair to switch sides.
const PATTERNS = {
  start: [300],
  tick: [60],
  end: [150, 100, 150],
  switch: [400, 120, 120],
  // A stretch's target reached: one soft buzz, nothing to hurry for.
  target: [200],
};

export function vibrationPattern(cue) {
  return PATTERNS[cue] ?? null;
}
