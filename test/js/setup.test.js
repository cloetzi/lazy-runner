import { test } from "node:test";
import assert from "node:assert/strict";
import { setupRows, setupLeft, weekPlan, programToPlan } from "../../public/js/setup.js";

const fresh = { gear: false, workouts: false, planned: false, assistant: false, invited: null };

test("a new user's card has gear, a program, the week and the Home Screen", () => {
  assert.deepEqual(setupRows(fresh).map((row) => row.key), ["gear", "program", "plan", "install"]);
  assert.equal(setupLeft(setupRows(fresh)), true);
});

test("the owner also invites and connects an assistant", () => {
  const rows = setupRows({ ...fresh, invited: false }, { standalone: true });
  assert.deepEqual(rows.map((row) => row.key), ["gear", "program", "plan", "invite", "assistant"]);
});

test("installed and all set, nothing is left", () => {
  const rows = setupRows({ gear: true, workouts: true, planned: true, assistant: true, invited: true }, { standalone: true });
  assert.equal(rows.every((row) => row.done), true);
  assert.equal(setupLeft(rows), false);
});

test("the Home Screen row is offered, never owed, in a browser tab", () => {
  const rows = setupRows({ gear: true, workouts: true, planned: true, assistant: false, invited: null });
  assert.equal(setupLeft(rows), false);
  assert.equal(rows.find((row) => row.key === "install").href, null);
});

test("workouts take turns through the week", () => {
  const a = { id: 1 };
  const b = { id: 2 };
  assert.deepEqual(weekPlan([a, b], [5, 1, 3]), [{ workout_id: 1, weekdays: [1, 5] }, { workout_id: 2, weekdays: [3] }]);
  assert.deepEqual(weekPlan([a, b, { id: 3 }], [2]), [{ workout_id: 1, weekdays: [2] }]);
  assert.deepEqual(weekPlan([a], [1, 1, 4]), [{ workout_id: 1, weekdays: [1, 4] }]);
  assert.deepEqual(weekPlan([], [1]), []);
  assert.deepEqual(weekPlan([a, b], []), []);
});

test("the newest program with a main workout is planned, its workouts in order", () => {
  const workout = (id, kind, position, archived = false) => ({ id, kind, position, archived });
  const programs = [
    { id: 1, workouts: [workout(10, "workout", 0)] },
    { id: 2, workouts: [workout(20, "warmup", 0), workout(22, "workout", 2), workout(21, "workout", 1), workout(23, "workout", 3, true)] },
    { id: 3, workouts: [workout(30, "cooldown", 0)] },
  ];
  const plan = programToPlan(programs);
  assert.equal(plan.program.id, 2);
  assert.deepEqual(plan.workouts.map((w) => w.id), [21, 22]);
  assert.equal(programToPlan([]), null);
});
