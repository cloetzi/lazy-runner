import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// Contrast of the colour tokens in app.css, so a palette tweak can't quietly
// drop a pair below WCAG AA: 4.5 for text, 3 for controls and graphics (1.4.11).
const css = readFileSync(new URL("../../public/css/app.css", import.meta.url), "utf8");

function tokens(block) {
  return Object.fromEntries([...block.matchAll(/(--[\w-]+):\s*(#[0-9a-f]{6})\s*;/gi)].map((m) => [m[1], m[2]]));
}
const light = tokens(css.slice(0, css.indexOf("@media (prefers-color-scheme: dark)")));
const dark = { ...light, ...tokens(css.match(/@media \(prefers-color-scheme: dark\) \{[\s\S]*?\n\}/)[0]) };

function luminance(hex) {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
export function ratio(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

const pairs = [
  ["--accent-text", "--accent", 4.5, "text on accent fills (badge, selected toggle, current nav item)"],
  ["--accent", "--surface", 4.5, "accent text on cards (suggestions, links)"],
  ["--accent", "--bg", 4.5, "accent text on the page"],
  ["--accent-ink", "--accent-tint", 4.5, "badge text"],
  ["--text", "--accent-tint", 4.5, "current sidebar item"],
  ["--rest", "--bg", 4.5, "rest phase label"],
  ["--danger", "--surface", 3, "delete icon on hover"],
  ["--muted", "--surface", 4.5, "muted text on cards"],
  ["--muted", "--bg", 4.5, "muted text on the page"],
  ["--text", "--surface", 4.5, "body text"],
  ["--control-border", "--surface", 3, "secondary button and input outlines on cards"],
  ["--control-border", "--bg", 3, "control outlines on the page"],
  ["--figure-far", "--surface", 3, "far limbs of the figure"],
  ["--focus", "--surface", 3, "focus ring on cards"],
  ["--focus", "--bg", 3, "focus ring on the page"],
];

for (const [scheme, palette] of [["light", light], ["dark", dark]]) {
  for (const [fg, bg, min, use] of pairs) {
    test(`${scheme}: ${fg} on ${bg} reaches ${min}:1 (${use})`, () => {
      assert.ok(palette[fg] && palette[bg], `missing ${fg} or ${bg}`);
      const r = ratio(palette[fg], palette[bg]);
      assert.ok(r >= min, `${palette[fg]} on ${palette[bg]} is ${r.toFixed(2)}:1`);
    });
  }
}

for (const page of ["index.html", "calendar.html", "equipment.html", "library.html", "settings.html"]) {
  test(`${page}: theme-color follows --bg in both schemes`, () => {
    const html = readFileSync(new URL(`../../public/${page}`, import.meta.url), "utf8");
    const color = (scheme) => html.match(new RegExp(`name="theme-color" content="(#[0-9a-f]{6})" media="\\(prefers-color-scheme: ${scheme}\\)"`))?.[1];
    assert.equal(color("light"), light["--bg"]);
    assert.equal(color("dark"), dark["--bg"]);
  });
}
