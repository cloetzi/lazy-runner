import { test } from "node:test";
import assert from "node:assert/strict";
import {
  skeleton, keyframes, duration, stillTime, sample, ease, lerpAngle, solve, shapes, viewBox,
} from "../../public/js/figure.js";

const close = (actual, expected, message) => assert.ok(Math.abs(actual - expected) < 1e-9, message ?? `${actual} ≉ ${expected}`);
const closePoint = (actual, expected) => { close(actual[0], expected[0]); close(actual[1], expected[1]); };
const distance = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);

// Hold 1 s standing, raise the near arm forward over 2 s, hold 1 s, return over 2 s.
const raise = {
  keyframes: [
    { pose: { upper_arm_near: 90 }, hold: 1, move: 2 },
    { pose: { upper_arm_near: 0, forearm_near: 0 }, hold: 1, move: 2 },
  ],
};

test("turns the short way round", () => {
  close(lerpAngle(170, -170, 0.5), 180);
  close(lerpAngle(-170, 170, 0.5), -180);
  close(lerpAngle(90, 0, 0.25), 67.5);
  close(lerpAngle(10, 370, 0.5), 10);
});

test("eases in and out", () => {
  close(ease(0), 0);
  close(ease(0.5), 0.5);
  close(ease(1), 1);
  assert.ok(ease(0.1) < 0.1 && ease(0.9) > 0.9);
});

test("fills keyframes from the rest pose and the previous keyframe, with default timing", () => {
  const frames = keyframes({ keyframes: [{ pose: { torso: -80 } }, { pose: { thigh_near: 45 }, hold: 2 }] });

  assert.equal(frames[0].pose.torso, -80);
  assert.equal(frames[0].pose.thigh_near, skeleton.rest.thigh_near);
  assert.equal(frames[1].pose.torso, -80);
  assert.equal(frames[1].pose.thigh_near, 45);
  assert.deepEqual(frames.map((f) => [f.hold, f.move]), [[0.5, 1], [2, 1]]);
  assert.deepEqual(frames[1].at, skeleton.canvas.origin);
});

test("holds, moves, holds and returns over one loop", () => {
  assert.equal(duration(raise), 6);
  assert.equal(sample(raise, 0.5).pose.upper_arm_near, 90);
  close(sample(raise, 2).pose.upper_arm_near, 45);
  assert.equal(sample(raise, 3.5).pose.upper_arm_near, 0);
  close(sample(raise, 5).pose.upper_arm_near, 45);
  close(sample(raise, 1.5).pose.upper_arm_near, 90 - 90 * ease(0.25));
});

test("loops forever", () => {
  assert.deepEqual(sample(raise, 6.5), sample(raise, 0.5));
  assert.deepEqual(sample(raise, 62), sample(raise, 2));
  assert.deepEqual(sample(raise, -4), sample(raise, 2));
});

test("moves the anchor point between keyframes", () => {
  const walk = { keyframes: [{ at: [80, 100] }, { at: [120, 90] }] };
  closePoint(sample(walk, 1).at, [100, 95]);
});

test("takes the still frame from the chosen keyframe", () => {
  assert.equal(stillTime(raise), 0);
  assert.equal(stillTime({ ...raise, still: 1 }), 3);
  assert.equal(sample({ ...raise, still: 1 }, stillTime({ ...raise, still: 1 })).pose.upper_arm_near, 0);
});

test("stands upright in the rest pose", () => {
  const joints = solve(skeleton.rest);
  const legs = skeleton.segments.thigh_near.length + skeleton.segments.shin_near.length;

  closePoint(joints.hip, skeleton.canvas.origin);
  closePoint(joints.ankle_near, [joints.hip[0], joints.hip[1] + legs]);
  assert.ok(joints.head[1] < joints.shoulder[1]);
  close(joints.head[0], joints.hip[0]);
});

test("keeps every bone its length in any pose", () => {
  const pose = Object.fromEntries(Object.keys(skeleton.rest).map((name, i) => [name, (i * 47) % 360 - 180]));
  const joints = solve(pose);
  for (const seg of Object.values(skeleton.segments)) close(distance(joints[seg.from], joints[seg.to]), seg.length);
});

test("hangs the neck and head off the torso", () => {
  const joints = solve({ ...skeleton.rest, torso: 0 });
  close(joints.head[1], joints.hip[1]);
  assert.ok(joints.head[0] > joints.shoulder[0]);
});

test("foreshortens scaled segments and blends the scale between keyframes", () => {
  const sideways = { keyframes: [{ pose: { upper_arm_near: 90 }, hold: 0, move: 2 }, { scale: { upper_arm_near: 0.5 }, hold: 0, move: 2 }] };
  const length = (seconds) => {
    const { pose, at, scale } = sample(sideways, seconds);
    const joints = solve(pose, "hip", at, scale);
    return distance(joints.shoulder, joints.elbow_near);
  };

  close(length(0), skeleton.segments.upper_arm_near.length);
  close(length(1), skeleton.segments.upper_arm_near.length * 0.75);
  close(length(2), skeleton.segments.upper_arm_near.length * 0.5);
  assert.deepEqual(keyframes(sideways).map((f) => f.scale), [{}, { upper_arm_near: 0.5 }]);
});

test("pins the anchor joint where the keyframe puts it", () => {
  const joints = solve({ ...skeleton.rest, thigh_near: 30 }, "ankle_near", [100, 180]);
  closePoint(joints.ankle_near, [100, 180]);
});

test("draws the far side first, the near side and held props last", () => {
  const list = shapes({ ...raise, props: [{ type: "bench", x: 20, width: 60, height: 40 }, { type: "dumbbell", at: "hand_near" }] }, 0);
  const index = (cls) => list.findIndex((s) => s.cls.split(" ").includes(cls));

  assert.equal(list[0].cls, "floor");
  assert.ok(index("prop") < index("far"));
  assert.ok(index("far") < index("torso"));
  assert.ok(index("torso") < index("near"));
  assert.equal(list.at(-1).cls, "prop hub");
});

test("marks accent segments and glows highlights on segments or joints", () => {
  const list = shapes({ ...raise, accent: ["upper_arm_near"], highlight: ["thigh_near", "hip"] }, 0);

  assert.equal(list.filter((s) => s.cls.includes("accent")).length, 1);
  assert.deepEqual(list.filter((s) => s.cls === "glow").map((s) => s.kind), ["line", "circle"]);
});

test("draws the glow behind the figure and the head over the near arm", () => {
  const overhead = { highlight: ["upper_arm_near"], keyframes: [{ pose: { upper_arm_near: -95, forearm_near: 100 } }] };
  const list = shapes({ ...overhead, props: [{ type: "dumbbell", at: "hand_near" }] }, 0);
  const index = (cls) => list.findIndex((s) => s.cls.split(" ").includes(cls));
  const last = (cls) => list.findLastIndex((s) => s.cls.split(" ").includes(cls));

  assert.ok(index("glow") < index("far"));
  assert.ok(last("near") < index("head"));
  assert.equal(list[index("head") - 1].cls, "outline");
  assert.ok(index("head") < index("prop"));
});

test("hangs a kettlebell below the hand and a hangboard where it is fixed", () => {
  const list = shapes({ ...raise, props: [{ type: "kettlebell", at: "hand_near" }, { type: "hangboard", x: 80, y: 10 }] }, 0);
  const handle = list.find((s) => s.cls === "prop handle");
  const bell = list.find((s) => s.cls === "prop weight");
  const board = list.find((s) => s.kind === "rect" && s.cls === "prop");

  assert.equal(bell.c[0], handle.c[0]);
  assert.ok(bell.c[1] > handle.c[1] + handle.r);
  assert.deepEqual([board.x, board.y], [80, 10]);
  assert.equal(list.at(-1).cls, "prop weight");
});

test("breaks the floor line where a mat lies on it", () => {
  const floor = skeleton.canvas.floor;
  const list = shapes({ ...raise, props: [{ type: "mat", x: 30, width: 120 }] }, 0);
  const floors = list.filter((s) => s.cls === "floor").map((s) => [s.from[0], s.to[0]]);
  const mat = list.find((s) => s.cls === "prop mat");

  assert.deepEqual(floors, [[-skeleton.canvas.width, 30], [150, 2 * skeleton.canvas.width]]);
  assert.ok(mat.y < floor && mat.y + mat.h > floor);
});

test("mirrors for the other side", () => {
  const animation = { ...raise, props: [{ type: "block", x: 20, width: 30, height: 10 }] };
  const plain = shapes(animation, 3.5);
  const mirrored = shapes(animation, 3.5, { mirror: true });
  const width = skeleton.canvas.width;

  plain.forEach((shape, i) => {
    const other = mirrored[i];
    if (shape.kind === "line") {
      closePoint(other.from, [width - shape.from[0], shape.from[1]]);
      closePoint(other.to, [width - shape.to[0], shape.to[1]]);
    } else if (shape.kind === "circle") {
      closePoint(other.c, [width - shape.c[0], shape.c[1]]);
    } else {
      close(other.x, width - 50);
    }
  });
});

test("frames the motion on both axes, down to the floor", () => {
  const lying = { anchor: "shoulder", keyframes: [{ pose: { torso: 180, thigh_near: 0, shin_near: 0, thigh_far: 0, shin_far: 0, upper_arm_near: 0, forearm_near: 0, upper_arm_far: 0, forearm_far: 0 }, at: [40, 175] }, {}] };
  const [x, y, width, height] = viewBox(lying);
  const [sx, sy, swidth, sheight] = viewBox(raise);

  assert.ok(y > 140, `top ${y}`);
  assert.ok(y + height > skeleton.canvas.floor);
  assert.ok(x > -20 && x < 20, `left ${x}`);
  assert.ok(width > height, "a lying figure is wide and short");
  assert.ok(sy < y && sheight > height, "a standing figure is taller");
  assert.ok(swidth < width, "and narrower");
  assert.ok(sx > 0 && sx + swidth < skeleton.canvas.width);
});

test("frames the mirrored motion for the other side", () => {
  const lunge = { keyframes: [{ pose: { thigh_near: 30 } }], props: [{ type: "block", x: 20, width: 30, height: 10 }] };
  const [x, y, width, height] = viewBox(lunge);
  const [mx, my, mwidth, mheight] = viewBox(lunge, { mirror: true });

  assert.deepEqual([my, mwidth, mheight], [y, width, height]);
  assert.ok(Math.abs(mx - (skeleton.canvas.width - x - width)) <= 1);
});

test("runs the floor past the canvas on both sides", () => {
  const floors = shapes(raise, 0).filter((s) => s.cls === "floor");
  assert.ok(floors[0].from[0] < 0 && floors.at(-1).to[0] > skeleton.canvas.width);
});
