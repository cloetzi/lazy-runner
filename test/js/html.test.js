import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { html, raw, joined, isHtml, icon, authorLine } from "../../public/js/html.js";

const JS = new URL("../../public/js/", import.meta.url);

test("escapes every value, quotes included, and keeps the template's own markup", () => {
  const name = `<img src=x onerror="alert(1)"> & 'co'`;
  const out = html`<li title="${name}">${name}</li>`;
  assert.ok(isHtml(out));
  assert.equal(String(out), '<li title="&#60;img src=x onerror=&#34;alert(1)&#34;&#62; &#38; &#39;co&#39;">' +
    "&#60;img src=x onerror=&#34;alert(1)&#34;&#62; &#38; &#39;co&#39;</li>");
});

test("nests templates and lists without escaping them twice", () => {
  const items = ["a & b", "c"];
  const out = html`<ul>${items.map((item) => html`<li>${item}</li>`)}</ul>`;
  assert.equal(String(out), "<ul><li>a &#38; b</li><li>c</li></ul>");
  assert.equal(String(html`${html`${html`<b>${"<"}</b>`}`}`), "<b>&#60;</b>");
});

test("writes nothing for null, undefined and false, and 0 as 0", () => {
  assert.equal(String(html`[${null}${undefined}${false}${0}]`), "[0]");
});

test("raw and joined build html, joined escaping text but not html", () => {
  assert.equal(String(html`${raw("<hr>")}`), "<hr>");
  assert.equal(String(raw(null)), "");
  assert.equal(String(joined(["a<b", html`<i>c</i>`], " · ")), "a&#60;b · <i>c</i>");
  assert.equal(String(joined([], ", ")), "");
});

test("innerHTML takes html as its text", () => {
  const element = { innerHTML: "" };
  element.innerHTML = html`<p>${"x"}</p>`;
  assert.equal(element.innerHTML.toString(), "<p>x</p>");
  assert.equal(`${html`<p>${"&"}</p>`}`, "<p>&#38;</p>");
});

test("icons and author lines are html, their text escaped", () => {
  assert.match(String(icon("agent", "A <b>")), /#agent".*A &#60;b&#62;/);
  assert.match(String(authorLine("Coach <x>", "p")), /^<p class="author-line">.*Coach &#60;x&#62;.*<\/p>$/);
  assert.equal(authorLine(null), "");
});

// ---------- No markup outside html`` ----------

// Every template literal and quoted string in a module, with whether it is
// tagged html``. Comments, regular expressions and the parts of a template
// inside ${} are walked, so nested templates are found too.
function literals(source) {
  const found = [];
  let i = 0;
  const quoted = () => {
    const quote = source[i];
    const start = i++;
    while (source[i] !== quote) i += source[i] === "\\" ? 2 : 1;
    i++;
    found.push({ start, text: source.slice(start, i), tagged: false });
  };
  const regex = () => {
    let inClass = false;
    i++;
    while (inClass || source[i] !== "/") {
      if (source[i] === "\\") i++;
      else if (source[i] === "[") inClass = true;
      else if (source[i] === "]") inClass = false;
      i++;
    }
    i++;
  };
  const template = () => {
    const start = i++;
    const tagged = source.slice(Math.max(0, start - 4), start) === "html";
    while (source[i] !== "`") {
      if (source[i] === "\\") i += 2;
      else if (source[i] === "$" && source[i + 1] === "{") {
        i += 2;
        code("}");
        i++;
      } else i++;
    }
    i++;
    found.push({ start, text: source.slice(start, i), tagged });
  };
  // Code up to the `end` character at depth 0 (the end of the file for none).
  const code = (end) => {
    let depth = 0;
    while (i < source.length) {
      const c = source[i];
      if (c === end && depth === 0) return;
      if (c === "/" && source[i + 1] === "/") i = source.indexOf("\n", i);
      else if (c === "/" && source[i + 1] === "*") i = source.indexOf("*/", i) + 2;
      else if (c === "/" && /(?:[(,=:[!&|?{};]|return)\s*$/.test(source.slice(Math.max(0, i - 20), i))) regex();
      else if (c === "\"" || c === "'") quoted();
      else if (c === "`") template();
      else {
        if (c === "{" || c === "(" || c === "[") depth++;
        if (c === "}" || c === ")" || c === "]") depth--;
        i++;
      }
    }
  };
  code(null);
  return found;
}

const modules = readdirSync(JS).filter((name) => name.endsWith(".js"));
const lineOf = (source, index) => source.slice(0, index).split("\n").length;

// Text outside the ${} of a template: what it says itself.
const ownText = (text) => {
  let depth = 0;
  let out = "";
  for (let i = 0; i < text.length; i++) {
    if (depth === 0 && text[i] === "$" && text[i + 1] === "{") { depth = 1; i++; continue; }
    if (depth > 0) {
      if (text[i] === "{") depth++;
      if (text[i] === "}") depth--;
      continue;
    }
    out += text[i];
  }
  return out;
};

test("the walker finds nested templates and tells tagged ones apart", () => {
  const found = literals("const a = html`<b>${x ? `y=\"${z}\"` : \"<i>\"}</b>`; // `<no>`\nconst r = /`[\"]/;");
  assert.deepEqual(found.map((l) => [l.text, l.tagged]), [["`y=\"${z}\"`", false], ["\"<i>\"", false], ["html`<b>${x ? `y=\"${z}\"` : \"<i>\"}</b>`".slice(4), true]]);
});

test("markup is written only in html`` templates, so every value in it is escaped", () => {
  const offences = [];
  for (const name of modules) {
    const source = readFileSync(new URL(name, JS), "utf8");
    for (const literal of literals(source)) {
      if (literal.tagged) continue;
      // Selectors name attributes in brackets, which is not markup.
      const text = ownText(literal.text).replace(/\[[^\]]*\]/g, "");
      if (/<[a-z/!]/i.test(text) || /(^|[\s"'`])[a-z-]+="/.test(text)) offences.push(`${name}:${lineOf(source, literal.start)} ${literal.text.slice(0, 80)}`);
    }
  }
  // The placeholder shown in a text field, and html.js and plan-changes.js
  // opening a tag they are passed (raw, from a fixed list of callers).
  const allowed = [/^settings\.js:\d+ "<token>"$/, /^(html|plan-changes)\.js:\d+ `<\/?\$\{tag\}/];
  assert.deepEqual(offences.filter((offence) => !allowed.some((pattern) => pattern.test(offence))), []);
});

test("nothing goes to innerHTML or insertAdjacentHTML as a plain template, and nothing escapes by hand", () => {
  const offences = [];
  for (const name of modules) {
    const source = readFileSync(new URL(name, JS), "utf8");
    for (const match of source.matchAll(/(?:innerHTML|outerHTML)\s*\+?=\s*`|insertAdjacentHTML\([^,]+,\s*`/g)) {
      offences.push(`${name}:${lineOf(source, match.index)}`);
    }
    if (name !== "html.js" && /import \{[^}]*\bescape\b[^}]*\} from "\.\/html\.js"/.test(source)) offences.push(`${name} imports escape`);
  }
  assert.deepEqual(offences, []);
});
