import { test } from "node:test";
import assert from "node:assert/strict";
import { needsResume } from "../../public/js/beeper.js";

test("starts the audio again once suspended or interrupted (a call, Siri, another app)", () => {
  assert.equal(needsResume("suspended"), true);
  assert.equal(needsResume("interrupted"), true);
  assert.equal(needsResume("running"), false);
  assert.equal(needsResume("closed"), false);
});

test("plays over a muted iPad or iPhone only with When muted set to Play", async () => {
  const { audioSessionType } = await import("../../public/js/beeper.js");
  const { DEFAULTS } = await import("../../public/js/preferences.js");
  assert.equal(audioSessionType({ sound: true, playWhenMuted: true }), "playback");
  assert.equal(audioSessionType({ sound: true, playWhenMuted: false }), "ambient");
  // Beeps off: nothing to stop the music for.
  assert.equal(audioSessionType({ sound: false, playWhenMuted: true }), "ambient");
  assert.equal(audioSessionType(DEFAULTS), "playback");
});
