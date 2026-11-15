// A unit setting the server keeps (/api/settings), with this device's copy
// for when it is offline: lb or kg under `unit`, km or mi under
// `distance_unit`. Kept free of the DOM so node can test it.

const SETTINGS_PATH = "/api/settings";

// The helpers for one setting: `field` as the server names it, the `units`
// it takes (the first until anything is known), and the storage `key` of
// this device's copy.
export function unitSetting({ field, units, key }) {
  const known = (unit) => units.includes(unit);
  const check = (unit) => {
    if (!known(unit)) throw new Error(`unknown ${field} ${unit}`);
  };

  // As this device last saw it.
  function preferred(storage) {
    try {
      const unit = storage.getItem(key);
      return known(unit) ? unit : units[0];
    } catch {
      return units[0];
    }
  }

  function set(storage, unit) {
    check(unit);
    try {
      storage.setItem(key, unit);
    } catch {
      // Storage blocked: the setting is not kept.
    }
  }

  // Changing it on the server, sent through the outbox.
  function request(unit) {
    check(unit);
    return { method: "PATCH", path: SETTINGS_PATH, body: { [field]: unit } };
  }

  // The unit to show once the server has answered with its own: kept as
  // this device's copy, unless a change made here is still queued to be
  // sent, or the answer is an offline copy that may predate it.
  function adopt(storage, unit, { queued = [], stale = false } = {}) {
    const changing = queued.some((entry) => entry.path === SETTINGS_PATH && entry.body && field in entry.body);
    if (stale || !known(unit) || changing) return preferred(storage);
    set(storage, unit);
    return unit;
  }

  return { preferred, set, request, adopt };
}
