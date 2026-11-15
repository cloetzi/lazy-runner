import { getJson, paths, send } from "./api.js";
import { adoptAccount, checkSignedIn, nextPath, pageAccount, signInHref } from "./account.js";
import { adoptServerUnit, preferredUnit, setPreferredUnit, unitRequest } from "./weights.js";
import { createOutbox } from "./outbox.js";
import { mountEquipment } from "./equipment-list.js";
import { mountExamples } from "./example-list.js";

// The welcome screen, shown once, on a user's first sign-in (signin.js):
// lb or kg, the gear they own, and the example programs. Each step is
// skippable and saves as it goes. Finishing or skipping the last step tells
// the server (`welcomed`), then goes on to `?next=`.

const storage = (() => {
  try {
    return localStorage;
  } catch {
    return null;
  }
})();
const $ = (id) => document.getElementById(id);
const steps = [...document.querySelectorAll("[data-step]")];
const next = nextPath(location.search);
const units = $("welcome-units");
// The unit goes through the outbox, as on Settings: sent later if it can't be now.
const outbox = storage && createOutbox({ storage, fetch: (...args) => fetch(...args), locks: navigator.locks, user: pageAccount(storage).id });

function show(index) {
  steps.forEach((step, i) => (step.hidden = i !== index));
  steps[index].querySelector("h2").setAttribute("tabindex", "-1");
  steps[index].querySelector("h2").focus();
}

async function finish() {
  // Offline, the server isn't told and the welcome shows again next time.
  await send("/api/account/welcome", { body: {} }).catch(() => null);
  location.replace(next);
}

// Gear with no weights yet follows the unit picked in step 1, sent or not.
const equipment = mountEquipment($("welcome-inventory"), { unitFor: (item) => (item.weights.length ? item.unit : preferredUnit(storage)) });
// The unit pick being saved, if any: the gear step waits for it.
let unitSaved = Promise.resolve();

steps.forEach((step, index) => {
  for (const button of step.querySelectorAll("[data-next]")) {
    button.onclick = async () => {
      if (index + 1 === steps.length) return finish();
      // Gear with no weights listed yet follows the unit: draw it in the one picked.
      if (steps[index + 1].contains($("welcome-inventory"))) {
        await unitSaved;
        await equipment.load();
      }
      show(index + 1);
    };
  }
  step.querySelector("[data-back]")?.addEventListener("click", () => show(index - 1));
});

const press = (value) => {
  for (const button of units.querySelectorAll("[data-value]")) button.setAttribute("aria-pressed", String(button.dataset.value === value));
};

units.onclick = (event) => {
  const value = event.target.closest("[data-value]")?.dataset.value;
  if (!value) return;
  setPreferredUnit(storage, value);
  press(value);
  if (outbox) {
    outbox.enqueue(unitRequest(value));
    unitSaved = outbox.flush().catch(() => {});
  } else {
    unitSaved = send("/api/settings", { method: "PATCH", body: { unit: value } }).catch(() => {});
  }
};

const me = await checkSignedIn({ storage, caches: globalThis.caches });
if (me.signedOut || me.user?.password_change_required) {
  location.replace(signInHref(location, { gate: me.gate }));
} else {
  if (me.user) await adoptAccount(me.user, { storage, caches: globalThis.caches });
  $("welcome-status").hidden = true;
  press(preferredUnit(storage));
  getJson(paths.settings)
    .then(({ data, stale }) => {
      // A pick queued meanwhile wins over the server's answer.
      adoptServerUnit(storage, data.unit, { queued: outbox?.queued() ?? [], stale });
      press(preferredUnit(storage));
    })
    .catch(() => {});
  mountExamples({ list: $("welcome-examples"), error: $("welcome-examples-error"), done: $("welcome-examples-done") }).load();
  show(0);
}
