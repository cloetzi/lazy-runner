import { createFigure } from "./figure-view.js";
import { getJson, paths } from "./api.js";
import { escape, icon, showSheet } from "./html.js";
import { tempoText } from "./player.js";

// Display names for equipment slugs, as /api/equipment gives them, with a
// copy in localStorage so a screen drawn before they arrive has them too.
// Before the first answer ever, a slug reads as words.
const NAMES_KEY = "equipment-names";
let names = readNames();
let loading = null;

function readNames() {
  try { return JSON.parse(localStorage.getItem(NAMES_KEY)) ?? {}; } catch { return {}; }
}

export function learnEquipmentNames(equipment) {
  names = Object.fromEntries(equipment.map((item) => [item.slug, item.name]));
  try { localStorage.setItem(NAMES_KEY, JSON.stringify(names)); } catch { /* names stay in memory */ }
}

export function knowsEquipmentNames() {
  return Object.keys(names).length > 0;
}

// Fetches the names once per page load; never rejects.
export function loadEquipmentNames(fetchFn = fetch) {
  loading ??= getJson(paths.equipment, fetchFn)
    .then(({ data }) => learnEquipmentNames(data))
    .catch(() => { loading = null; });
  return loading;
}

export function equipmentNames(equipment) {
  return (equipment ?? []).map((slug) => names[slug] ?? slug.replaceAll("_", " ").replace(/^./, (c) => c.toUpperCase()));
}

// The how-to view: the animation large, the full instructions, cues and
// common mistakes, in a dialog over whatever is on screen. With `controls`,
// a per-side exercise can show either side and any can play at half speed,
// for learning the movement; `historyHref` adds a link to its history.
// `tempo` is the step's, written out.
export function openHowto(exercise, { mirror = false, tempo = null, onClose, controls = false, historyHref = "" } = {}) {
  const dialog = document.getElementById("howto") ?? document.body.appendChild(Object.assign(document.createElement("dialog"), { id: "howto" }));
  const list = (title, items, tag = "ul") => items?.length
    ? `<h3>${title}</h3><${tag}>${items.map((line) => `<li>${escape(line)}</li>`).join("")}</${tag}>` : "";
  const equipment = equipmentNames(exercise.equipment);
  const view = { mirror, speed: 1 };
  const toggles = controls && exercise.animation ? `
    <div class="howto-controls">
      ${exercise.unilateral ? `<div class="segmented" role="group" aria-label="Side">
        <button type="button" data-side="left">Left side</button>
        <button type="button" data-side="right">Right side</button>
      </div>` : ""}
      <div class="segmented" role="group" aria-label="Speed">
        <button type="button" data-speed="1">1×</button>
        <button type="button" data-speed="0.5">½×</button>
      </div>
    </div>` : "";

  dialog.innerHTML = `
    <form method="dialog" class="howto">
      <header>
        <h2>${escape(exercise.name)}</h2>
        <button class="icon-button" aria-label="Close">${icon("close")}</button>
      </header>
      ${exercise.animation ? `<div class="figure-box howto-figure"></div>` : ""}
      ${toggles}
      ${equipment.length ? `<p class="muted">With: ${escape(equipment.join(", "))}</p>` : ""}
      ${tempo ? `<p class="muted">Tempo ${escape(tempo)}: ${escape(tempoText(tempo))}</p>` : ""}
      ${list("How to do it", exercise.instructions, "ol")}
      ${list("Cues", exercise.cues)}
      ${list("Common mistakes", exercise.mistakes)}
      ${historyHref ? `<p><a href="${escape(historyHref)}">Your history with it</a></p>` : ""}
    </form>`;

  let figure = null;
  const draw = () => {
    figure?.destroy();
    figure = exercise.animation &&
      createFigure(dialog.querySelector(".howto-figure"), exercise.animation, { mirror: view.mirror, speed: view.speed, label: exercise.name });
    for (const button of dialog.querySelectorAll("[data-side], [data-speed]")) {
      const on = button.dataset.side ? (button.dataset.side === "right") === view.mirror : Number(button.dataset.speed) === view.speed;
      button.setAttribute("aria-pressed", String(on));
    }
  };
  const controlsElement = dialog.querySelector(".howto-controls");
  if (controlsElement) {
    controlsElement.onclick = (event) => {
      const button = event.target.closest("button");
      if (!button) return;
      if (button.dataset.side) view.mirror = button.dataset.side === "right";
      if (button.dataset.speed) view.speed = Number(button.dataset.speed);
      draw();
    };
  }
  draw();
  dialog.addEventListener("close", () => {
    figure?.destroy();
    onClose?.();
  }, { once: true });
  showSheet(dialog);
}
