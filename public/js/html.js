export function escape(text) {
  return String(text).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

// An icon from /icons/sprite.svg, sized to the text around it. Pass `label`
// when the icon stands alone, so screen readers still get a name.
export function icon(name, label) {
  const svg = `<svg class="icon" aria-hidden="true"><use href="/icons/sprite.svg#${name}"/></svg>`;
  return label ? `${svg}<span class="visually-hidden">${escape(label)}</span>` : svg;
}
