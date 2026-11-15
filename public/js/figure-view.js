import { shapes, stillTime, viewBox } from "./figure.js";

const SVG = "http://www.w3.org/2000/svg";
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

// Draws an exercise animation into `container` as a looping SVG. Colours and
// line weights come from CSS (.figure in app.css), so it follows dark mode and
// the accent colour. Shows a still frame when reduced motion is requested, or
// always with `still`.
export function createFigure(container, animation, { mirror = false, label = "", speed = 1, still = false } = {}) {
  const svg = document.createElementNS(SVG, "svg");
  const box = viewBox(animation, { mirror });
  svg.setAttribute("viewBox", box.join(" "));
  svg.setAttribute("class", "figure");
  // The box size in canvas units, for frames that draw every figure at one scale.
  svg.style.setProperty("--figure-w", box[2]);
  svg.style.setProperty("--figure-h", box[3]);
  svg.setAttribute("role", "img");
  if (label) svg.setAttribute("aria-label", label);
  container.replaceChildren(svg);

  let elements = [];
  let frame = null;
  let started = null;
  let pausedAt = null;

  const draw = (seconds) => {
    const list = shapes(animation, seconds, { mirror });
    if (elements.length !== list.length) {
      elements = list.map((shape) => document.createElementNS(SVG, tag(shape)));
      svg.replaceChildren(...elements);
    }
    list.forEach((shape, i) => update(elements[i], shape));
  };

  const loop = (now) => {
    started ??= now;
    draw(((now - started) / 1000) * speed);
    frame = requestAnimationFrame(loop);
  };

  const stop = () => {
    if (frame) cancelAnimationFrame(frame);
    frame = null;
  };

  const play = () => {
    if (frame) return;
    if (still || reducedMotion.matches) return draw(stillTime(animation));
    if (pausedAt !== null && started !== null) started = performance.now() - pausedAt * 1000;
    pausedAt = null;
    frame = requestAnimationFrame(loop);
  };

  const onMotionChange = () => {
    stop();
    play();
  };
  reducedMotion.addEventListener("change", onMotionChange);
  draw(0);
  play();

  return {
    pause() {
      if (!frame) return;
      pausedAt = (performance.now() - (started ?? performance.now())) / 1000;
      stop();
    },
    play,
    destroy() {
      stop();
      reducedMotion.removeEventListener("change", onMotionChange);
      svg.remove();
    },
  };
}

function tag(shape) {
  return { line: "line", circle: "circle", rect: "rect" }[shape.kind];
}

function update(element, shape) {
  element.setAttribute("class", shape.cls);
  if (shape.kind === "line") {
    set(element, { x1: shape.from[0], y1: shape.from[1], x2: shape.to[0], y2: shape.to[1] });
  } else if (shape.kind === "circle") {
    set(element, { cx: shape.c[0], cy: shape.c[1], r: shape.r });
  } else {
    set(element, { x: shape.x, y: shape.y, width: shape.w, height: shape.h });
  }
}

function set(element, attributes) {
  for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value.toFixed(1));
}
