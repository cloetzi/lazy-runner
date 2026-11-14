// Exercise animations as data: a side-on figure on a fixed skeleton, posed by
// keyframes and interpolated in between. Pure logic, no DOM; figure-view.js
// turns the shapes into SVG.
//
// An animation looks like this (all keys but keyframes are optional):
//
//   anchor: ankle_near        joint that stays put, placed at each keyframe's `at`
//   accent: [thigh_near]      segments drawn in the accent colour (the moving limb)
//   highlight: [thigh_near]   segments or joints with a soft glow (the target muscle)
//   props: [{ type: dumbbell, at: hand_near }, { type: bench, x: 30, width: 80, height: 40 }]
//                             dumbbell and kettlebell are held at a joint, a band runs
//                             from one joint to another, a hangboard is fixed at x, y and
//                             the rest stand on the floor at x
//   still: 1                  keyframe shown when motion is reduced (default 0)
//   keyframes:
//     - pose: { torso: -90, thigh_near: 60 }   segment directions in degrees
//       at: [100, 182]
//       scale: { upper_arm_near: 0.4 }         segment lengths as seen (default 1)
//       hold: 0.5                              seconds at this pose
//       move: 1.2                              seconds to the next pose
//
// Angles are screen directions: 0 points the way the figure faces (right), 90
// straight down, -90 straight up. The neck and head are relative to the
// segment they hang from. A keyframe only lists what changes: everything else
// carries over from the previous keyframe, and the first one starts from the
// standing rest pose. After the last keyframe the loop moves back to the first.
// "near" limbs face the viewer; mirroring flips the figure to face left, which
// shows the other side, so per-side exercises are authored for the left side.
// A limb pointing towards or away from the viewer (a sideways raise seen from
// the side) looks shorter: `scale` foreshortens a segment, carried over and
// interpolated like the pose.

import skeleton from "./skeleton.json" with { type: "json" };

export { skeleton };

const DEFAULT_HOLD = 0.5;
const DEFAULT_MOVE = 1;

const SEGMENTS = Object.entries(skeleton.segments);
const PARENT = Object.fromEntries(SEGMENTS.map(([name, seg]) => [
  name, SEGMENTS.find(([, other]) => other.to === seg.from)?.[0],
]));

// Keyframes with every pose filled in and the timing defaults applied.
export function keyframes(animation) {
  let pose = skeleton.rest;
  let at = skeleton.canvas.origin;
  let scale = {};
  return animation.keyframes.map((keyframe) => {
    pose = { ...pose, ...keyframe.pose };
    at = keyframe.at ?? at;
    scale = { ...scale, ...keyframe.scale };
    return { pose, at, scale, hold: keyframe.hold ?? DEFAULT_HOLD, move: keyframe.move ?? DEFAULT_MOVE };
  });
}

export function duration(animation) {
  return keyframes(animation).reduce((sum, k) => sum + k.hold + k.move, 0);
}

// The moment the still frame is taken for reduced motion.
export function stillTime(animation) {
  return keyframes(animation).slice(0, animation.still ?? 0).reduce((sum, k) => sum + k.hold + k.move, 0);
}

// Pose and anchor position at `seconds` into the loop.
export function sample(animation, seconds) {
  const frames = keyframes(animation);
  const total = frames.reduce((sum, k) => sum + k.hold + k.move, 0);
  let t = total > 0 ? ((seconds % total) + total) % total : 0;

  for (const [i, frame] of frames.entries()) {
    if (t < frame.hold) return { pose: frame.pose, at: frame.at, scale: frame.scale };
    t -= frame.hold;
    if (t < frame.move) return blend(frame, frames[(i + 1) % frames.length], ease(t / frame.move));
    t -= frame.move;
  }
  return { pose: frames[0].pose, at: frames[0].at, scale: frames[0].scale };
}

function blend(from, to, progress) {
  const pose = {};
  const scale = {};
  for (const name of Object.keys(skeleton.rest)) pose[name] = lerpAngle(from.pose[name], to.pose[name], progress);
  for (const name of new Set([...Object.keys(from.scale ?? {}), ...Object.keys(to.scale ?? {})])) {
    scale[name] = lerp(from.scale?.[name] ?? 1, to.scale?.[name] ?? 1, progress);
  }
  return { pose, at: [lerp(from.at[0], to.at[0], progress), lerp(from.at[1], to.at[1], progress)], scale };
}

// Slow in, slow out, so a pose reads as a pose rather than a bounce.
export function ease(progress) {
  return 0.5 - Math.cos(Math.PI * progress) / 2;
}

// Turns the short way round, so 170 to -170 is a 20 degree move.
export function lerpAngle(from, to, progress) {
  const delta = ((((to - from) % 360) + 540) % 360) - 180;
  return from + delta * progress;
}

function lerp(from, to, progress) {
  return from + (to - from) * progress;
}

// Joint positions for a pose, shifted so the anchor joint lands on `at`.
export function solve(pose, anchor = "hip", at = skeleton.canvas.origin, scale = {}) {
  const joints = { hip: [0, 0] };
  const directions = {};
  for (const [name, seg] of SEGMENTS) {
    const direction = seg.relative ? directions[PARENT[name]] + pose[name] : pose[name];
    const radians = (direction * Math.PI) / 180;
    const [x, y] = joints[seg.from];
    directions[name] = direction;
    const length = seg.length * (scale[name] ?? 1);
    joints[seg.to] = [x + length * Math.cos(radians), y + length * Math.sin(radians)];
  }

  const [ax, ay] = joints[anchor];
  for (const name of Object.keys(joints)) joints[name] = [joints[name][0] - ax + at[0], joints[name][1] - ay + at[1]];
  return joints;
}

// Everything to draw at `seconds`, back to front. Each shape is a line,
// circle or rect with a space-separated class list for styling.
export function shapes(animation, seconds, { mirror = false } = {}) {
  const { pose, at, scale } = sample(animation, seconds);
  const joints = solve(pose, animation.anchor, at, scale);
  const accent = new Set(animation.accent ?? []);
  const props = animation.props ?? [];
  const floor = skeleton.canvas.floor;
  const list = [];

  const line = (name, cls) => {
    const seg = skeleton.segments[name];
    list.push({ kind: "line", from: joints[seg.from], to: joints[seg.to], cls });
  };
  const segment = (name, cls) => line(name, accent.has(name) ? `${cls} accent` : cls);
  // Near limbs get a thin outline in the background colour first, so an arm
  // in front of the torso still reads as an arm.
  const nearLimbs = (names) => {
    for (const name of names) line(name, "outline");
    for (const name of names) segment(name, "limb near");
  };
  const limbs = (side) => [`thigh_${side}`, `shin_${side}`, `foot_${side}`, `upper_arm_${side}`, `forearm_${side}`];

  list.push(...floorShapes(props, floor));
  for (const prop of props.filter((p) => !IN_FRONT.has(p.type))) list.push(...propShapes(prop, joints, floor));

  // The target muscle glows as a halo behind the whole figure, so the figure
  // keeps its own colours in both schemes.
  for (const name of animation.highlight ?? []) {
    if (skeleton.segments[name]) line(name, "glow");
    else list.push({ kind: "circle", c: joints[name], r: 16, cls: "glow" });
  }

  for (const name of limbs("far")) segment(name, "limb far");
  segment("torso", "torso");
  segment("neck", "neck");
  nearLimbs(limbs("near").slice(0, 3));
  nearLimbs(limbs("near").slice(3));
  // The head comes last with its own outline, so an arm raised past it never
  // hides it.
  list.push({ kind: "circle", c: joints.head, r: skeleton.head_radius + 2, cls: "outline" });
  list.push({ kind: "circle", c: joints.head, r: skeleton.head_radius, cls: "head" });

  for (const prop of props.filter((p) => IN_FRONT.has(p.type))) list.push(...propShapes(prop, joints, floor));

  return mirror ? list.map(flip) : list;
}

// The part of the canvas the animation uses, as an SVG viewBox
// [x, y, width, height]: the bounds of the motion on both axes, padded, down
// to the floor. Every figure keeps the canvas units, so drawing each box at
// the same units-to-pixels scale shows every person at the same size. The
// floor runs on past the box; the frame decides how far it shows.
export function viewBox(animation, { mirror = false, samples = 24 } = {}) {
  const total = duration(animation);
  const floor = skeleton.canvas.floor;
  let [left, right, top] = [Infinity, -Infinity, floor];
  for (let i = 0; i < samples; i++) {
    for (const shape of shapes(animation, (total * i) / samples, { mirror })) {
      if (shape.cls === "floor") continue;
      const [x0, x1, y0] = bounds(shape);
      left = Math.min(left, x0);
      right = Math.max(right, x1);
      if (shape.cls !== "prop wall") top = Math.min(top, y0);
    }
  }
  const x = Math.floor(left - VIEW_PADDING);
  const y = Math.floor(top - VIEW_PADDING);
  return [x, y, Math.ceil(right + VIEW_PADDING) - x, floor + VIEW_PADDING / 2 - y];
}

// Covers the widest stroke (the glow) past a joint.
const VIEW_PADDING = 14;

// [left, right, top] of a shape, strokes not counted.
function bounds(shape) {
  switch (shape.kind) {
    case "line": return [Math.min(shape.from[0], shape.to[0]), Math.max(shape.from[0], shape.to[0]), Math.min(shape.from[1], shape.to[1])];
    case "circle": return [shape.c[0] - shape.r, shape.c[0] + shape.r, shape.c[1] - shape.r];
    case "rect": return [shape.x, shape.x + shape.w, shape.y];
    default: return [Infinity, -Infinity, Infinity];
  }
}

// The ground line, broken where a mat lies on it so there is one ground. It
// reaches a canvas width past either side, so it can run to the frame's edges.
function floorShapes(props, floor) {
  const mats = props.filter((p) => p.type === "mat").map((p) => [p.x, p.x + p.width]).sort((a, b) => a[0] - b[0]);
  const shapes = [];
  const width = skeleton.canvas.width;
  let x = -width;
  for (const [from, to] of mats) {
    if (from > x) shapes.push({ kind: "line", from: [x, floor], to: [from, floor], cls: "floor" });
    x = Math.max(x, to);
  }
  if (x < 2 * width) shapes.push({ kind: "line", from: [x, floor], to: [2 * width, floor], cls: "floor" });
  return shapes;
}

// Held props are drawn over the figure, everything else behind it.
const IN_FRONT = new Set(["dumbbell", "kettlebell", "band"]);

function propShapes(prop, joints, floor) {
  switch (prop.type) {
    case "mat":
      return [{ kind: "rect", x: prop.x, y: floor - 4, w: prop.width, h: 5, cls: "prop mat" }];
    case "wall":
      return [{ kind: "rect", x: prop.x, y: 0, w: 6, h: floor, cls: "prop wall" }];
    case "bench": {
      const { x, width, height } = prop;
      return [
        { kind: "rect", x: x + 6, y: floor - height, w: 4, h: height, cls: "prop" },
        { kind: "rect", x: x + width - 10, y: floor - height, w: 4, h: height, cls: "prop" },
        { kind: "rect", x, y: floor - height, w: width, h: 7, cls: "prop" },
      ];
    }
    case "block": {
      const { x, width = 24, height = 16 } = prop;
      return [{ kind: "rect", x, y: floor - height, w: width, h: height, cls: "prop" }];
    }
    // On the floor at x, or under a joint resting on top of it.
    case "swiss_ball": {
      const r = prop.r ?? 26;
      const c = prop.at ? [joints[prop.at][0], joints[prop.at][1] + r + 4] : [prop.x, floor - r];
      return [{ kind: "circle", c, r, cls: "prop ball" }];
    }
    case "dumbbell":
      return [
        { kind: "circle", c: joints[prop.at], r: 8, cls: "prop weight" },
        { kind: "circle", c: joints[prop.at], r: 2.5, cls: "prop hub" },
      ];
    // Bell below the hand that holds the handle.
    case "kettlebell": {
      const [x, y] = joints[prop.at];
      return [
        { kind: "circle", c: [x, y + 3], r: 5, cls: "prop handle" },
        { kind: "circle", c: [x, y + 14], r: 9, cls: "prop weight" },
      ];
    }
    // A board fixed at x, y (its top left), hung from by its bottom edge.
    case "hangboard": {
      const { x, y, width = 36 } = prop;
      return [{ kind: "rect", x, y, w: width, h: 8, cls: "prop" }];
    }
    case "band":
      return [{ kind: "line", from: joints[prop.from], to: joints[prop.to], cls: "band" }];
    default:
      return [];
  }
}

function flip(shape) {
  const width = skeleton.canvas.width;
  const point = ([x, y]) => [width - x, y];
  switch (shape.kind) {
    case "line": return { ...shape, from: point(shape.from), to: point(shape.to) };
    case "circle": return { ...shape, c: point(shape.c) };
    case "rect": return { ...shape, x: width - shape.x - shape.w };
    default: return shape;
  }
}
