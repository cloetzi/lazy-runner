import { mountNav } from "./nav.js";
import { mountEquipment } from "./equipment-list.js";
import { getJson, paths } from "./api.js";
import { unlocks, unlocksLine } from "./gear.js";

// The Equipment page: what you own, and its weights (equipment-list.js),
// with what each item unlocks: the exercises that need it and the workouts
// that use it.

mountNav("equipment");
let library = null;
const list = mountEquipment(document.getElementById("inventory"), {
  describe: (item, inventory) => (library ? unlocksLine(unlocks(item, { ...library, inventory })) : ""),
});
list.load();
// The line is extra: the list works without it, offline included.
Promise.all([getJson(paths.exercises), getJson(paths.workouts)])
  .then(([exercises, workouts]) => {
    library = { exercises: exercises.data, programs: workouts.data };
    list.redraw();
  })
  .catch(() => {});
