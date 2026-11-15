export function escape(text) {
  return String(text).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

// An icon from /icons/sprite.svg, sized to the text around it. Pass `label`
// when the icon stands alone, so screen readers still get a name.
export function icon(name, label) {
  const svg = `<svg class="icon" aria-hidden="true"><use href="/icons/sprite.svg#${name}"/></svg>`;
  return label ? `${svg}<span class="visually-hidden">${escape(label)}</span>` : svg;
}

// Who put something on the calendar, when it was not you: the agent's icon
// and a line such as "Coach agent · planned today" (plannedBy in coach.js).
// Empty for yours. Never colour alone: the icon and the name say it.
export function authorLine(text, tag = "span") {
  return text ? `<${tag} class="author-line">${icon("agent")}<span>${escape(text)}</span></${tag}>` : "";
}

// A button waiting on the server: disabled, with the busy spinner (app.css)
// beside its label. `busy(button, false)` gives it back.
export function busy(button, on = true) {
  button.disabled = on;
  if (on) button.setAttribute("aria-busy", "true");
  else button.removeAttribute("aria-busy");
}
