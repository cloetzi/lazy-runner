import { test } from "node:test";
import assert from "node:assert/strict";
import { exampleSummary, workoutHeading, gearLine } from "../../public/js/example-list.js";

test("sums up an example by its main workouts and their minutes", () => {
  const workouts = [
    { kind: "warmup", estimated_minutes: 5 },
    { kind: "workout", estimated_minutes: 25 },
    { kind: "workout", estimated_minutes: 30 },
  ];
  assert.equal(exampleSummary({ workouts }), "2 workouts, 25-30 min");
  assert.equal(exampleSummary({ workouts: [workouts[0]] }), "");
});

test("heads each workout under What's in it, with minutes for main ones", () => {
  assert.equal(workoutHeading({ kind: "workout", title: "Session A", subtitle: "Knees and pull", estimated_minutes: 25 }), "Session A: Knees and pull · 25 min");
  assert.equal(workoutHeading({ kind: "warmup", title: "Warm-up", subtitle: null, estimated_minutes: 5 }), "Warm-up");
});

test("marks each piece of an example's gear as yours or not, in words", () => {
  const html = String(gearLine({ gear: [{ slug: "dumbbell", name: "Dumbbells", owned: true }, { slug: "kettlebell", name: "Kettlebell", owned: false }] }));
  assert.match(html, /#check[^]*Dumbbells<span class="visually-hidden">, yours<\/span>/);
  assert.match(html, /class="gear-missing"[^]*#close[^]*Kettlebell[^]*not yours yet/);
  assert.equal(String(gearLine({ gear: [] })), "");
});
