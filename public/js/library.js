import { createFigure } from "./figure-view.js";
import { openHowto, equipmentNames, learnEquipmentNames } from "./howto.js";
import { escape } from "./html.js";
import { mountNav } from "./nav.js";
import { getJson, paths, loadProblem, STALE_NOTE } from "./api.js";
import { preferredUnit } from "./weights.js";
import { AREAS, BODYWEIGHT, matches, standIns, gearUsed, countLine, lastLine, usedInLine } from "./catalog.js";

// The exercise library: every exercise with its animation and cues, found by
// search, body area and equipment, each card saying when you last did it and
// which workouts use it. "What I own" (the default) keeps to the exercises the
// equipment inventory covers. `?review` shows the animation review layout
// instead: either side, half speed, and what is still to draw.

const review = new URLSearchParams(location.search).has("review");
const settings = { side: "left", speed: 1, owned: remembered(), query: "", area: "", equipment: "" };
const storage = (() => { try { return localStorage; } catch { return null; } })();
let exercises = [];
let equipment = [];
let owned = new Set();
let logged = new Map();
let programs = [];
let stale = false;
let figures = new Map();

const observer = "IntersectionObserver" in window
  ? new IntersectionObserver(onVisibility, { rootMargin: "200px 0px" })
  : null;

async function load() {
  try {
    const answers = await Promise.all([getJson(paths.exercises), getJson(paths.equipment)]);
    const [all, inventory] = answers.map((answer) => answer.data);
    stale = answers.some((answer) => answer.stale);
    exercises = all;
    equipment = inventory;
    learnEquipmentNames(inventory);
    owned = new Set(inventory.filter((e) => e.owned).map((e) => e.slug));
    fillEquipment();
    render();
  } catch (error) {
    document.getElementById("library-count").textContent = loadProblem("the exercises", error);
    return;
  }
  // What the cards say about you comes second: the library works without it.
  const [history, workouts] = await Promise.all([optional(paths.exerciseHistory), optional(paths.workouts)]);
  logged = new Map((history ?? []).map((entry) => [entry.id, entry]));
  programs = workouts ?? [];
  if (!review) render();
}

async function optional(path) {
  try {
    return (await getJson(path)).data;
  } catch {
    return null;
  }
}

function fillEquipment() {
  const select = document.getElementById("library-equipment");
  const used = gearUsed(exercises, equipment);
  select.innerHTML = `<option value="">Any equipment</option><option value="${BODYWEIGHT}">No equipment</option>` +
    equipment.filter((item) => used.has(item.slug))
      .map((item) => `<option value="${escape(item.slug)}">${escape(item.name)}</option>`).join("");
  select.value = settings.equipment;
}

function render() {
  figures.forEach((figure) => figure.destroy());
  figures = new Map();
  observer?.disconnect();
  markSelected("[data-side]", (b) => b.dataset.side === settings.side);
  markSelected("[data-speed]", (b) => Number(b.dataset.speed) === settings.speed);
  markSelected("[data-owned]", (b) => (b.dataset.owned === "true") === settings.owned);
  markSelected("[data-area]", (b) => b.dataset.area === settings.area);

  const names = Object.fromEntries(exercises.flatMap((e) => e.equipment).map((slug) => [slug, equipmentNames([slug])[0]]));
  const pool = exercises.filter((e) => matches(e, { owned: settings.owned ? owned : null }));
  const shown = pool.filter((e) => matches(e, { query: settings.query, area: settings.area, equipment: settings.equipment, standIns: standIns(settings.equipment, equipment), names }));
  const filtered = Boolean(settings.query || settings.area || settings.equipment);

  let count;
  if (review) {
    const animated = shown.filter((e) => e.animation);
    count = `${animated.length} of ${exercises.length} animated`;
    section("animated", "Animated", animated);
    section("todo", "Still to draw", shown.filter((e) => !e.animation));
  } else {
    count = countLine(shown.length, pool.length, { owned: settings.owned, filtered, ownsNothing: owned.size === 0, more: exercises.length - pool.length });
    section("animated", "", shown);
    section("todo", "", []);
  }
  const countLineElement = document.getElementById("library-count");
  // Nothing owned yet: the way to see the rest, right after the count.
  const hint = !review && settings.owned && owned.size === 0
    ? `. <a href="/equipment.html">Tell us what you own</a> to see more.` : "";
  // "your gear" is what Equipment holds: it goes there to change it.
  countLineElement.innerHTML = escape(count).replace("your gear", `<a href="/equipment.html">your gear</a>`) + hint + (stale ? ` · ${escape(STALE_NOTE)}` : "");
  document.getElementById("library-empty").hidden = shown.length > 0;

  for (const box of document.querySelectorAll("[data-figure]")) {
    if (observer) observer.observe(box);
    else show(box);
  }
}

function markSelected(selector, selected) {
  for (const button of document.querySelectorAll(selector)) button.setAttribute("aria-pressed", String(selected(button)));
}

// Cards take the level under the section's title, or under the page's.
function section(id, title, list) {
  const element = document.getElementById(id);
  element.hidden = list.length === 0;
  const level = title ? 3 : 2;
  element.innerHTML = `${title ? `<h2>${title}</h2>` : ""}<div class="library-grid">${list.map((exercise) => card(exercise, level)).join("")}</div>`;
}

function card(exercise, level) {
  const details = [exercise.category, ...equipmentNames(exercise.equipment)];
  if (exercise.unilateral) details.push("per side");
  if (exercise.alternating) details.push("alternating sides");
  const you = review ? [] : [lastLine(logged.get(exercise.id), preferredUnit(storage), weekdayDate), usedInLine(programs, exercise.id)].filter(Boolean);
  return `
    <article class="card figure-card">
      ${exercise.animation
        ? `<div class="figure-box" data-figure="${exercise.id}"></div>`
        : `<div class="figure-box placeholder"><span>No animation yet</span></div>`}
      <h${level}>${escape(exercise.name)}</h${level}>
      <p class="muted">${escape(details.join(" · "))}</p>
      ${you.map((line) => `<p class="card-you">${escape(line)}</p>`).join("")}
      <ul class="card-cues">${exercise.cues.map((cue) => `<li>${escape(cue)}</li>`).join("")}</ul>
      <div class="card-actions">
        <button class="secondary small" data-howto="${exercise.id}">How to</button>
        ${!review && logged.has(exercise.id) ? `<a class="button secondary small" href="${historyHref(exercise)}">History</a>` : ""}
      </div>
    </article>`;
}

// Animate only the cards on or near the screen, so a long list stays smooth.
function onVisibility(entries) {
  for (const entry of entries) {
    if (entry.isIntersecting) show(entry.target);
    else figures.get(entry.target)?.pause();
  }
}

function show(box) {
  const figure = figures.get(box);
  if (figure) return figure.play();
  const exercise = exercises.find((e) => String(e.id) === box.dataset.figure);
  if (exercise) {
    figures.set(box, createFigure(box, exercise.animation, {
      mirror: mirrored(exercise), speed: review ? settings.speed : 1, label: exercise.name,
    }));
  }
}

function mirrored(exercise) {
  return review && exercise.unilateral && settings.side === "right";
}

function historyHref(exercise) {
  return `/#exercise-history/${exercise.id}`;
}

function weekdayDate(iso) {
  return new Date(`${iso}T12:00:00`).toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
}

// The filter choice is a convenience for this browser only; "What I own"
// until changed.
function remembered() {
  try {
    return localStorage.getItem("library-owned") !== "false";
  } catch {
    return true;
  }
}

function remember(value) {
  try {
    localStorage.setItem("library-owned", String(value));
  } catch {
    // Storage blocked: the choice lasts for this page load.
  }
}

document.getElementById("library-areas").innerHTML = [{ id: "", label: "All areas" }, ...AREAS]
  .map((area) => `<button data-area="${area.id}">${escape(area.label)}</button>`).join("");
document.getElementById("review-controls").hidden = !review;

for (const controls of document.querySelectorAll(".library-controls")) {
  controls.addEventListener("click", (event) => {
    const button = event.target.closest("button");
    if (!button) return;
    if (button.dataset.side) settings.side = button.dataset.side;
    if (button.dataset.speed) settings.speed = Number(button.dataset.speed);
    if (button.dataset.owned) remember(settings.owned = button.dataset.owned === "true");
    if (button.dataset.area !== undefined) settings.area = button.dataset.area;
    render();
  });
}

document.getElementById("library-search").addEventListener("input", (event) => {
  settings.query = event.target.value;
  render();
});

document.getElementById("library-equipment").addEventListener("change", (event) => {
  settings.equipment = event.target.value;
  render();
});

document.getElementById("library-clear").onclick = () => {
  Object.assign(settings, { query: "", area: "", equipment: "" });
  document.getElementById("library-search").value = "";
  document.getElementById("library-equipment").value = "";
  render();
};

document.querySelector(".library").addEventListener("click", (event) => {
  const id = event.target.closest("[data-howto]")?.dataset.howto;
  const exercise = exercises.find((e) => String(e.id) === id);
  if (!exercise) return;
  if (review) return openHowto(exercise, { mirror: mirrored(exercise) });
  openHowto(exercise, { controls: true, historyHref: logged.has(exercise.id) ? historyHref(exercise) : "" });
});

mountNav("exercises");
load();
