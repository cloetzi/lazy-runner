import { parseWeight, withWeight, quickWeights } from "./inventory.js";
import { html, icon } from "./html.js";
import { getJson, paths, loadProblem, errorMessage, send, STALE_NOTE } from "./api.js";

// The inventory, drawn in a list: toggle what you own and, for gear that
// comes in set weights, add the weights you have one at a time (shown as
// chips, each removable) and say whether they are lb or kg. Each change is
// saved straight away. An item's unit is the user's own: it follows the lb
// or kg on the Settings page until weights are listed, then stays. On the
// Equipment page and the welcome screen. The generic weight (`any_weight`)
// isn't listed: it comes with any dumbbells or kettlebells owned.

// `unitFor(item)`, if given, is the unit to show (and save weights in) for an
// item: the welcome screen shows the unit just picked for gear with no
// weights yet, even before the pick reaches the server. `describe(item,
// inventory)`, if given, is a line under the item's name: on the Equipment
// page, what it unlocks.
export function mountEquipment(list, { unitFor = (item) => item.unit, describe = () => "" } = {}) {
  // Items whose unit was picked here: shown in their own from then on.
  const picked = new Set();
  // The inventory as last drawn, for `describe`.
  let inventory = [];

  async function load() {
    try {
      const { data, stale } = await getJson(paths.equipment);
      inventory = data;
      list.innerHTML = html`${stale ? html`<li class="row muted">${STALE_NOTE}</li>` : ""}${data.filter((item) => !item.any_weight).map(row)}`;
    } catch (error) {
      list.innerHTML = html`<li class="row">${loadProblem("the equipment", error)}</li>`;
    }
  }

  function row(item) {
    const weighted = item.weights.length > 0 || item.unit;
    const unit = weighted && (picked.has(item.id) ? item.unit : unitFor(item));
    const line = describe(item, inventory);
    return html`
      <li class="row inventory-item${item.owned ? "" : " not-owned"}" data-id="${item.id}">
        <label class="owned">
          <input type="checkbox" data-field="owned" ${item.owned ? "checked" : ""}>
          <span>${item.name}</span>
        </label>
        ${line ? html`<p class="unlocks muted">${line}</p>` : ""}
        ${weighted && item.owned ? weightsHtml(item, unit) : ""}
        <p class="status muted" aria-live="polite"></p>
      </li>`;
  }

  // Owned gear in set weights: a chip per weight, a field and Add for one
  // more, the common sizes not listed yet, and lb or kg.
  function weightsHtml(item, unit) {
    const { name } = item;
    const quick = quickWeights(item.slug, unit, item.weights);
    return html`
      <div class="weights">
        <ul class="weight-chips" aria-label="${name} weights">${item.weights.map((weight) => html`
          <li class="weight-chip">${weight} ${unit}<button type="button" class="chip-remove" data-remove="${weight}" aria-label="Remove ${weight} ${unit}">${icon("close")}</button></li>`)}
        </ul>
        <div class="weight-add">
          <input type="text" inputmode="decimal" data-field="new-weight" placeholder="Weight" aria-label="Add a ${name} weight, in ${unit}"
            aria-describedby="weights-hint-${item.id}" enterkeyhint="done" autocomplete="off">
          <button type="button" class="secondary small" data-add-weight>Add</button>
          <div class="segmented" role="group" aria-label="${name} weights in">
            ${["lb", "kg"].map((choice) => html`<button type="button" data-unit="${choice}" aria-pressed="${choice === unit}">${choice}</button>`)}
          </div>
        </div>
        ${quick.length ? html`<div class="weight-quick" role="group" aria-label="Add a common size, in ${unit}">${quick.map((weight) => html`
          <button type="button" class="secondary small" data-quick="${weight}">+ ${weight}</button>`)}</div>` : ""}
        <p class="weights-hint muted" id="weights-hint-${item.id}">Add each weight once, even if you have a pair.</p>
        <p class="form-error" role="alert" hidden></p>
      </div>`;
  }

  const weightsOf = (element) => [...element.querySelectorAll("[data-remove]")].map((button) => Number(button.dataset.remove));
  const shownUnit = (element) => element.querySelector('[data-unit][aria-pressed="true"]')?.dataset.unit;

  // Adds what is typed in the row's field; a typo says so where it is typed.
  function addTyped(element) {
    const field = element.querySelector('[data-field="new-weight"]');
    const error = element.querySelector(".weights .form-error");
    const { weight, error: problem } = parseWeight(field.value, shownUnit(element));
    error.textContent = problem ?? "";
    error.hidden = !problem;
    field.setAttribute("aria-invalid", String(Boolean(problem)));
    if (problem) return field.focus();
    saveWeights(element, withWeight(weightsOf(element), weight), '[data-field="new-weight"]', { typed: true });
  }

  // With the unit shown, so the weights are kept in it whatever the server's default.
  const saveWeights = (element, weights, refocus, options) => save(element, { weights, unit: shownUnit(element) }, refocus, options);

  // `refocus`: what to focus in the row once it is drawn again. `typed`:
  // the weight field's text was saved, so it starts empty again; otherwise
  // what was half typed there is kept.
  async function save(element, changes, refocus, { typed = false } = {}) {
    const status = element.querySelector(".status");
    status.textContent = "Saving…";
    const draft = typed ? "" : element.querySelector('[data-field="new-weight"]')?.value ?? "";
    // One change at a time: a second tap would send a list missing the first.
    for (const control of element.querySelectorAll(".weights button, .weights input")) control.disabled = true;
    try {
      const response = await send(`/api/equipment/${element.dataset.id}`, { method: "PATCH", body: changes });
      const body = await response.json();
      if (!response.ok) throw new Error(errorMessage(body, response.status));
      if (changes.unit) picked.add(body.id);
      inventory = inventory.map((entry) => (entry.id === body.id ? body : entry));
      // The list may have been drawn again meanwhile: replace the row as it is now.
      const current = list.querySelector(`[data-id="${body.id}"]`);
      if (!current) return;
      current.outerHTML = row(body);
      list.querySelector(`[data-id="${body.id}"] .status`).textContent = "Saved";
      const field = list.querySelector(`[data-id="${body.id}"] [data-field="new-weight"]`);
      if (field) field.value = draft;
      // Drawn again, the row keeps the keyboard where it was working.
      if (refocus) list.querySelector(`[data-id="${body.id}"] ${refocus}`)?.focus();
    } catch (error) {
      (list.querySelector(`[data-id="${element.dataset.id}"] .status`) ?? status).textContent = `Not saved: ${error.message}`;
      for (const control of element.querySelectorAll(".weights button, .weights input")) control.disabled = false;
    }
  }

  list.addEventListener("click", (event) => {
    const element = event.target.closest("[data-id]");
    if (!element) return;
    const unitButton = event.target.closest("[data-unit]");
    if (unitButton) {
      if (unitButton.getAttribute("aria-pressed") !== "true") save(element, { unit: unitButton.dataset.unit }, `[data-unit="${unitButton.dataset.unit}"]`);
      return;
    }
    if (event.target.closest("[data-add-weight]")) return addTyped(element);
    const remove = event.target.closest("[data-remove]");
    const quick = event.target.closest("[data-quick]");
    // A tap leaves the focus on a button, so a phone's keyboard stays down.
    if (remove) {
      saveWeights(element, weightsOf(element).filter((weight) => weight !== Number(remove.dataset.remove)), "[data-add-weight]");
    } else if (quick) {
      saveWeights(element, withWeight(weightsOf(element), Number(quick.dataset.quick)), "[data-add-weight]");
    }
  });

  list.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" || event.target.dataset.field !== "new-weight") return;
    event.preventDefault();
    addTyped(event.target.closest("[data-id]"));
  });

  list.addEventListener("change", (event) => {
    const element = event.target.closest("[data-id]");
    if (element && event.target.dataset.field === "owned") save(element, { owned: event.target.checked }, '[data-field="owned"]');
  });

  // Draws the list again from what it last loaded: once what `describe`
  // reads has arrived.
  const redraw = () => {
    for (const element of list.querySelectorAll("[data-id]")) {
      const item = inventory.find((entry) => String(entry.id) === element.dataset.id);
      const line = item && describe(item, inventory);
      const shown = element.querySelector(".unlocks");
      if (shown && line) shown.textContent = line;
      else if (line) element.querySelector(".owned").insertAdjacentHTML("afterend", html`<p class="unlocks muted">${line}</p>`);
      else shown?.remove();
    }
  };

  return { load, redraw };
}
