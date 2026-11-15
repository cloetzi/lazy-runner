import { equipmentNames } from "./howto.js";
import { createFigure } from "./figure-view.js";
import { formatWeight } from "./weights.js";
import { escape, icon, showSheet } from "./html.js";
import { getJson } from "./api.js";
import { shortlist } from "./player.js";

// Alternatives per planned exercise, fetched once per page load so a swap
// still works if the connection drops mid-session.
const alternatives = new Map();

export function prefetchAlternatives(exerciseIds) {
  for (const id of new Set(exerciseIds)) loadAlternatives(id).catch(() => {});
}

// Forgets them all: what is owned changed, and with it what can stand in.
export function forgetAlternatives() {
  alternatives.clear();
}

function loadAlternatives(id) {
  if (!alternatives.has(id)) {
    const request = getJson(`/api/exercises/${id}/alternatives`).then(({ data }) => data);
    alternatives.set(id, request);
    request.catch(() => alternatives.delete(id));
  }
  return alternatives.get(id);
}

// The swap picker: the planned exercise's alternatives, best match first,
// in a dialog like the how-to. Exercises the session already has go last,
// so a swap doesn't double up. `onPick` gets the chosen exercise, or the
// planned one to undo a swap. Weights are shown in `unit`. `note` says what
// a swap changes and `alreadyIn` tags an exercise of `inSession`: the
// workout view swaps a step of the workout itself.
export function openSwap({
  planned, current, inSession = new Set(), unit, onPick, onClose,
  note = "For the rest of this session. The program stays as it is.", alreadyIn = "In this session",
}) {
  const dialog = document.getElementById("swap") ?? document.body.appendChild(Object.assign(document.createElement("dialog"), { id: "swap", className: "sheet" }));
  dialog.innerHTML = `
    <form method="dialog" class="howto">
      <header>
        <h2>Swap ${escape(current.name)}</h2>
        <button class="icon-button" aria-label="Close">${icon("close")}</button>
      </header>
      <p class="muted">${escape(note)}</p>
      <div class="list" id="swap-list"><p class="muted">Loading…</p></div>
    </form>`;

  let options = [];
  let stills = [];
  const list = dialog.querySelector("#swap-list");
  list.onclick = (event) => {
    const button = event.target.closest("button[data-pick]");
    if (!button) return;
    event.preventDefault();
    const choice = options[Number(button.dataset.pick)];
    dialog.close();
    onPick(choice);
  };
  dialog.addEventListener("close", () => {
    stills.forEach((figure) => figure.destroy());
    onClose?.();
  }, { once: true });
  showSheet(dialog);

  loadAlternatives(planned.id).then((found) => {
    const others = found.filter((e) => e.id !== current.id);
    const { best, rest } = shortlist(others, inSession);
    const back = current.id === planned.id ? [] : [planned];
    const draw = (shown) => {
      stills.forEach((figure) => figure.destroy());
      stills = [];
      options = [...back, ...shown];
      list.innerHTML = options.length ? options.map((exercise, i) => row(exercise, i)).join("") +
        (shown.length < best.length + rest.length ? `<button type="button" class="row more" data-more>Show everything (${best.length + rest.length - shown.length} more)</button>` : "")
        : `<p class="muted">Nothing in the library can stand in for this one.</p>`;
      list.querySelectorAll("[data-still]").forEach((box) => {
        const exercise = options[Number(box.dataset.still)];
        if (exercise.animation) stills.push(createFigure(box, exercise.animation, { still: true }));
      });
    };
    const row = (exercise, i) => {
      const bits = exercise.id === planned.id ? equipmentNames(exercise.equipment) : [exercise.reason ?? equipmentNames(exercise.equipment).join(", ")];
      if (exercise.weight) bits.push(formatWeight(exercise.weight, unit));
      const meta = bits.filter(Boolean).join(" · ");
      const backLabel = exercise.id === planned.id ? "Back to planned: " : "";
      const tag = exercise.id !== planned.id && inSession.has(exercise.id) ? `<span class="tag">${escape(alreadyIn)}</span>` : "";
      return `<button class="row" data-pick="${i}">
        <span class="swap-still" data-still="${i}" aria-hidden="true"></span>
        <span class="row-text"><span class="row-title">${backLabel}${escape(exercise.name)}${tag}</span>${meta ? `<span class="row-meta">${escape(meta)}</span>` : ""}</span>
        ${icon("chevron-right")}
      </button>`;
    };
    list.addEventListener("click", (event) => {
      if (!event.target.closest("[data-more]")) return;
      event.preventDefault();
      draw([...best, ...rest]);
    });
    draw(best);
  }, () => {
    list.innerHTML = `<p>Swapping needs a connection the first time. Try again once you're back online.</p>`;
  });
}
