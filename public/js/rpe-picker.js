// "How hard was it?" drawn one way wherever it is asked: on the finish
// form, when logging an activity, on an activity's sheet and in Today's
// question. The anchors are the player's (RPE_ANCHORS in player.js).

import { escape } from "./html.js";
import { RPE_ANCHORS } from "./player.js";

// The anchors as buttons, `rpe` pressed. As toggles (the default) a tap
// picks one and a tap on the picked one takes it back (see toggleRpe); with
// `answer`, each closes its dialog with "rpe:<n>" as the value.
export function rpeOptions({ rpe = null, answer = false } = {}) {
  return RPE_ANCHORS.map((a) => answer
    ? `<button value="rpe:${a.rpe}">${escape(a.label)}</button>`
    : `<button type="button" data-rpe="${a.rpe}" aria-pressed="${a.rpe === rpe}">${escape(a.label)}</button>`).join("");
}

// The picker with its group around it.
export function rpePicker(options = {}) {
  return `<div class="rpe segmented fill" role="group" aria-label="How hard it was">${rpeOptions(options)}</div>`;
}

// Makes the toggles in `container` keep at most one pressed, calling
// `onChange(rpe or null)`, when given, on each tap.
export function toggleRpe(container, onChange = () => {}) {
  container.addEventListener("click", (event) => {
    const button = event.target.closest("[data-rpe]");
    if (!button) return;
    const chosen = button.getAttribute("aria-pressed") === "true" ? null : Number(button.dataset.rpe);
    for (const b of container.querySelectorAll("[data-rpe]")) b.setAttribute("aria-pressed", String(Number(b.dataset.rpe) === chosen));
    onChange(chosen);
  });
}

// The RPE pressed in `container`, or null.
export const pickedRpe = (container) => Number(container.querySelector('[data-rpe][aria-pressed="true"]')?.dataset.rpe) || null;
