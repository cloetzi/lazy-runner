function escape(text) {
  return String(text).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

// HTML that is safe to put on the page: only html`` (and the helpers here
// built on it) makes one. Assigned to innerHTML, it is its text.
class Html {
  constructor(text) {
    this.text = text;
  }

  toString() {
    return this.text;
  }
}

// What a value becomes inside html``: Html as it is, a list item by item,
// nothing for null, undefined or false, and anything else as escaped text.
// In an attribute's quotes a boolean is its word, so aria-pressed="${on}"
// says "false" rather than nothing.
function part(value, inAttribute = false) {
  if (inAttribute && typeof value === "boolean") return String(value);
  if (value instanceof Html) return value.text;
  if (Array.isArray(value)) return value.map(part).join("");
  if (value == null || value === false) return "";
  return escape(value);
}

// Items with a separator between them, as html: each escaped unless it is
// Html itself, so a list can mix text with marked-up bits.
export const joined = (items, separator) => new Html(items.map(part).join(part(separator)));

// A template whose every value is escaped unless it is Html itself:
// html`<li>${name}</li>` is safe whatever `name` holds, and templates nest
// (html`<ul>${items.map((i) => html`<li>${i}</li>`)}</ul>`). Every template
// that goes to innerHTML is one of these (test/js/html.test.js checks).
export function html(strings, ...values) {
  let out = strings[0];
  values.forEach((value, i) => {
    out += part(value, strings[i].endsWith('="')) + strings[i + 1];
  });
  return new Html(out);
}

// An icon from /icons/sprite.svg, sized to the text around it. Pass `label`
// when the icon stands alone, so screen readers still get a name.
export function icon(name, label) {
  const svg = html`<svg class="icon" aria-hidden="true"><use href="/icons/sprite.svg#${name}"/></svg>`;
  return label ? html`${svg}<span class="visually-hidden">${label}</span>` : svg;
}

// `content` in a line of its own (tag "p") or within one ("span"), with
// `className`: the two a caller can ask for, so a tag is never text.
export function inLine(tag, className, content) {
  if (tag === "p") return html`<p class="${className}">${content}</p>`;
  if (tag === "span") return html`<span class="${className}">${content}</span>`;
  throw new Error(`inLine takes p or span, not ${tag}`);
}

// Who put something on the calendar, when it was not you: the agent's icon
// and a line such as "Coach agent · planned today" (plannedBy in coach.js).
// Empty for yours. Never colour alone: the icon and the name say it.
export function authorLine(text, tag = "span") {
  return text ? inLine(tag, "author-line", html`${icon("agent")}<span>${text}</span>`) : "";
}

// A button waiting on the server: disabled, with the busy spinner (app.css)
// beside its label. `busy(button, false)` gives it back.
export function busy(button, on = true) {
  button.disabled = on;
  if (on) button.setAttribute("aria-busy", "true");
  else button.removeAttribute("aria-busy");
}

// Opens a dialog as a modal sheet, named by its first heading so a screen
// reader says "How to, dialog" rather than just "dialog".
export function showSheet(dialog) {
  const heading = dialog.querySelector("h1, h2, h3");
  if (heading) {
    heading.id ||= `${dialog.id || "sheet"}-title`;
    dialog.setAttribute("aria-labelledby", heading.id);
  } else {
    dialog.removeAttribute("aria-labelledby");
  }
  dialog.showModal();
}
