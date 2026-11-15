import { test } from "node:test";
import assert from "node:assert/strict";
import { needsResume } from "../../public/js/beeper.js";

test("starts the audio again once suspended or interrupted (a call, Siri, another app)", () => {
  assert.equal(needsResume("suspended"), true);
  assert.equal(needsResume("interrupted"), true);
  assert.equal(needsResume("running"), false);
  assert.equal(needsResume("closed"), false);
});
