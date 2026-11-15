// Pure weight stepper logic, the app's only one (the server keeps the
// increments, config/coach.yml, and steps nothing itself). Each
// weighted step comes with its `allowed_weights` (the owned dumbbells or
// kettlebells, in the weight's unit) and the stepper moves through those;
// without them it steps by the increments table from /api/today
// (config/coach.yml).
//
// Each exercise keeps its weights in one unit, the one the server sends them
// in. The lb or kg setting only changes how they are shown: the stepper steps
// the weight in its own unit and the result is shown converted.

const UNITS = ["lb", "kg"];
const KG_PER_LB = 0.45359237;
// A converted weight is rounded to this, so 40 lb shows as 18 kg.
const CONVERTED_TO_NEAREST = 0.5;
const UNIT_KEY = "unit";
const SETTINGS_PATH = "/api/settings";

// Owned weights closer than this count as the weight itself.
const SAME_WEIGHT = 0.01;

export function stepWeight(value, unit, equipment, direction, table, allowed) {
  if (direction !== "up" && direction !== "down") throw new Error(`unknown direction ${direction}`);
  if (allowed?.length) return stepOwned(value, allowed, direction);

  const bands = weightBands(unit, equipment, table);
  if (direction === "up") {
    return round(value + bands.find((b) => b.below == null || value < b.below).step);
  }
  return Math.max(0, round(value - bands.find((b) => b.below == null || value <= b.below).step));
}

// The next owned weight up or down; the same weight when there is none.
function stepOwned(value, allowed, direction) {
  const next = direction === "up"
    ? Math.min(...allowed.filter((w) => w > value + SAME_WEIGHT))
    : Math.max(...allowed.filter((w) => w < value - SAME_WEIGHT));
  return Number.isFinite(next) ? next : value;
}

// One stepper press on a step or player item's weight, kept in its unit;
// null is no weight. A step with no weight yet starts from nothing in
// `unit`: up gives the lightest owned weight (or the first step), down
// leaves it without one. Down from the lightest owned weight (or the last
// step down) is no weight again. Whether anything changed is for
// `sameWeight` to say.
export function stepTargetWeight(weight, equipment, direction, table, allowed, unit) {
  if (!weight) {
    if (direction === "down" || !unit) return null;
    weight = { value: 0, unit };
  }
  if (direction === "down" && allowed?.length && weight.value <= Math.min(...allowed) + SAME_WEIGHT) return null;
  const value = stepWeight(weight.value, weight.unit, equipment, direction, table, allowed);
  return value > 0 ? { value, unit: weight.unit } : null;
}

// Whether two weights (or no weight, null) are the same as kept.
export function sameWeight(a, b) {
  if (!a || !b) return !a && !b;
  return a.unit === b.unit && Math.abs(a.value - b.value) < SAME_WEIGHT;
}

function weightBands(unit, equipment, table) {
  const kind = (equipment ?? []).find((e) => e in table) ?? "default";
  return table[kind][unit] ?? table.default[unit];
}

export function inUnit(weight, unit) {
  if (!weight || !unit || weight.unit === unit) return weight;
  const value = unit === "kg" ? weight.value * KG_PER_LB : weight.value / KG_PER_LB;
  return { value: Math.round(value / CONVERTED_TO_NEAREST) * CONVERTED_TO_NEAREST, unit };
}

// Whether two weights, in any units, are the same piece of gear: within
// Weights::TOLERANCE on the server (a quarter of a kilo), so a 16 kg
// kettlebell is the 35 lb weight it was converted to.
const GEAR_TOLERANCE = { kg: 0.25, lb: 0.25 / KG_PER_LB };
export function sameGearWeight(a, b) {
  if (!a || !b) return !a && !b;
  const value = a.unit === b.unit ? b.value : a.unit === "kg" ? b.value * KG_PER_LB : b.value / KG_PER_LB;
  return Math.abs(a.value - value) <= GEAR_TOLERANCE[a.unit];
}

// Whether two weights look the same once shown in `unit`.
export function sameShownWeight(a, b, unit) {
  return formatWeight(a, unit) === formatWeight(b, unit);
}

export function formatWeight(weight, unit) {
  if (!weight) return "";
  const shown = inUnit(weight, unit);
  return `${shownValue(shown.value)} ${shown.unit}`;
}

// A weight's number as shown: whole, or to two decimals at most.
export function shownValue(value) {
  return Number.isInteger(value) ? value : Number(value.toFixed(2));
}

function round(value) {
  return Math.round(value * 100) / 100;
}

// The setting is kept on the server; this device keeps a copy for when it is
// offline, lb until anything is known.
export function preferredUnit(storage) {
  try {
    const unit = storage.getItem(UNIT_KEY);
    return UNITS.includes(unit) ? unit : "lb";
  } catch {
    return "lb";
  }
}

export function setPreferredUnit(storage, unit) {
  if (!UNITS.includes(unit)) throw new Error(`unknown unit ${unit}`);
  try {
    storage.setItem(UNIT_KEY, unit);
  } catch {
    // Storage blocked: the setting is not kept.
  }
}

// A weight the way it is picked up: "2 × 20 lb" for a pair, "1 × 40 lb"
// for one, never a bare total.
export function formatLoad(weight, held, unit) {
  if (!weight) return "";
  return `${held ?? 1} × ${formatWeight(weight, unit)}`;
}

// Changing the unit on the server, sent through the outbox.
export function unitRequest(unit) {
  if (!UNITS.includes(unit)) throw new Error(`unknown unit ${unit}`);
  return { method: "PATCH", path: SETTINGS_PATH, body: { unit } };
}

// The unit to show once the server has answered with its own: kept as this
// device's copy, unless a change made here is still queued to be sent, or the
// answer is an offline copy that may predate it.
export function adoptServerUnit(storage, unit, { queued = [], stale = false } = {}) {
  if (stale || !UNITS.includes(unit) || queued.some((entry) => entry.path === SETTINGS_PATH && entry.body && "unit" in entry.body)) return preferredUnit(storage);
  setPreferredUnit(storage, unit);
  return unit;
}
