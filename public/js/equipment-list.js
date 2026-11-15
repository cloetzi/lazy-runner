import { parseWeights, formatWeights } from "./inventory.js";
import { escape } from "./html.js";
import { getJson, errorMessage, send, STALE_NOTE } from "./api.js";

// The inventory, drawn in a list: toggle what you own, list the weights you
// have (comma-separated) and say whether they are lb or kg. Each change is
// saved straight away. An item's unit is the user's own: it follows the lb
// or kg on the Settings page until weights are listed, then stays. On the
// Equipment page and the welcome screen. The generic weight (`any_weight`)
// isn't listed: it comes with any dumbbells or kettlebells owned.

// `unitFor(item)`, if given, is the unit to show (and save weights in) for an
// item: the welcome screen shows the unit just picked for gear with no
// weights yet, even before the pick reaches the server.
export function mountEquipment(list, { unitFor = (item) => item.unit } = {}) {
  // Items whose unit was picked here: shown in their own from then on.
  const picked = new Set();

  async function load() {
    try {
      const { data, stale } = await getJson("/api/equipment");
      list.innerHTML = (stale ? `<li class="row muted">${escape(STALE_NOTE)}</li>` : "") + data.filter((item) => !item.any_weight).map(row).join("");
    } catch (error) {
      list.innerHTML = `<li class="row">Could not load the equipment (${escape(error.message)}).</li>`;
    }
  }

  function row(item) {
    const weighted = item.weights.length > 0 || item.unit;
    const unit = weighted && (picked.has(item.id) ? item.unit : unitFor(item));
    return `
      <li class="row inventory-item${item.owned ? "" : " not-owned"}" data-id="${item.id}">
        <label class="owned">
          <input type="checkbox" data-field="owned" ${item.owned ? "checked" : ""}>
          <span>${escape(item.name)}</span>
        </label>
        ${weighted ? `
          <div class="weights">
            <label>
              <span class="muted">Weights</span>
              <input type="text" data-field="weights" value="${escape(formatWeights(item.weights))}"
                placeholder="10, 20" aria-describedby="weights-hint-${item.id}" ${item.owned ? "" : "disabled"}>
            </label>
            <div class="segmented" role="group" aria-label="${escape(item.name)} weights in">
              ${["lb", "kg"].map((choice) => `<button type="button" data-unit="${choice}" aria-pressed="${choice === unit}" ${item.owned ? "" : "disabled"}>${choice}</button>`).join("")}
            </div>
            <p class="weights-hint muted" id="weights-hint-${item.id}">Every weight you have, separated by commas.</p>
          </div>` : ""}
        <p class="status muted" aria-live="polite"></p>
      </li>`;
  }

  async function save(element, changes) {
    const status = element.querySelector(".status");
    status.textContent = "Saving…";
    try {
      const response = await send(`/api/equipment/${element.dataset.id}`, { method: "PATCH", body: changes });
      const body = await response.json();
      if (!response.ok) throw new Error(errorMessage(body, response.status));
      if (changes.unit) picked.add(body.id);
      // The list may have been drawn again meanwhile: replace the row as it is now.
      const current = list.querySelector(`[data-id="${body.id}"]`);
      if (!current) return;
      current.outerHTML = row(body);
      list.querySelector(`[data-id="${body.id}"] .status`).textContent = "Saved";
    } catch (error) {
      (list.querySelector(`[data-id="${element.dataset.id}"] .status`) ?? status).textContent = `Not saved: ${error.message}`;
    }
  }

  list.addEventListener("click", (event) => {
    const button = event.target.closest("[data-unit]");
    const element = button?.closest("[data-id]");
    if (!element || button.disabled || button.getAttribute("aria-pressed") === "true") return;
    save(element, { unit: button.dataset.unit });
  });

  list.addEventListener("change", (event) => {
    const element = event.target.closest("[data-id]");
    if (!element) return;
    if (event.target.dataset.field === "owned") {
      save(element, { owned: event.target.checked });
    } else if (event.target.dataset.field === "weights") {
      const { weights, error } = parseWeights(event.target.value);
      if (error) element.querySelector(".status").textContent = error;
      // With the unit shown, so the weights are kept in it whatever the server's default.
      else save(element, { weights, unit: element.querySelector('[data-unit][aria-pressed="true"]')?.dataset.unit });
    }
  });

  return { load };
}
