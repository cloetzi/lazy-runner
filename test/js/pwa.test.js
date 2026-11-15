import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { BACKGROUNDS, startupImages, installed, installHint } from "../../public/js/pwa.js";

const PUBLIC = new URL("../../public/", import.meta.url).pathname;

test("opens on the page's own background in each scheme", () => {
  const css = readFileSync(`${PUBLIC}css/app.css`, "utf8");
  const dark = css.slice(css.indexOf("prefers-color-scheme: dark"));
  assert.equal(/--bg:\s*(#[0-9a-f]+)/i.exec(css)[1], BACKGROUNDS.light);
  assert.equal(/--bg:\s*(#[0-9a-f]+)/i.exec(dark)[1], BACKGROUNDS.dark);
  // Each page's browser bar too.
  for (const page of readdirSync(PUBLIC).filter((name) => name.endsWith(".html"))) {
    const html = readFileSync(`${PUBLIC}${page}`, "utf8");
    assert.match(html, new RegExp(`content="${BACKGROUNDS.light}" media="\\(prefers-color-scheme: light\\)"`), page);
    assert.match(html, new RegExp(`content="${BACKGROUNDS.dark}" media="\\(prefers-color-scheme: dark\\)"`), page);
  }
});

test("draws a startup image for the screen in pixels, both ways round, in both schemes", () => {
  // An 11-inch iPad, held either way.
  for (const screen of [{ width: 834, height: 1194, ratio: 2 }, { width: 1194, height: 834, ratio: 2 }]) {
    assert.deepEqual(startupImages(screen), [
      { media: "(orientation: portrait) and (prefers-color-scheme: light)", width: 1668, height: 2388, colour: BACKGROUNDS.light },
      { media: "(orientation: landscape) and (prefers-color-scheme: light)", width: 2388, height: 1668, colour: BACKGROUNDS.light },
      { media: "(orientation: portrait) and (prefers-color-scheme: dark)", width: 1668, height: 2388, colour: BACKGROUNDS.dark },
      { media: "(orientation: landscape) and (prefers-color-scheme: dark)", width: 2388, height: 1668, colour: BACKGROUNDS.dark },
    ]);
  }
});

test("recommends Add to Home Screen only in a browser tab", () => {
  const media = (matches) => () => ({ matches });
  assert.match(installHint({ standalone: false }, media(false)), /^Tap Share, then Add to Home Screen\./);
  assert.match(installHint({}, media(false)), /^Install the app from the browser's menu/);
  assert.equal(installHint({ standalone: true }, media(false)), null);
  assert.equal(installHint({}, media(true)), null);
  assert.equal(installed(undefined, undefined), false);
});
