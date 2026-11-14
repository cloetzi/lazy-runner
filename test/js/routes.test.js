import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PAGES, TABS, MORE, SIDEBAR, SIDEBAR_SECONDARY, parseRoute, routeHash, pageFor, isSessionView } from "../../public/js/routes.js";

test("parses the views the home page can open from the hash", () => {
  assert.deepEqual(parseRoute("#workouts"), { view: "workouts" });
  assert.deepEqual(parseRoute("#history"), { view: "history" });
  assert.deepEqual(parseRoute("#workout/12"), { view: "workout", id: "12" });
  assert.deepEqual(parseRoute("#edit/12"), { view: "edit", id: "12" });
  assert.deepEqual(parseRoute("#edit/new"), { view: "edit", id: "new" });
  assert.deepEqual(parseRoute("#exercise-history/5"), { view: "exercise-history", id: "5" });
  assert.deepEqual(parseRoute("#session/9"), { view: "session", id: "9" });
  assert.deepEqual(parseRoute("#/workouts"), { view: "workouts" });
});

test("falls back to the home page", () => {
  assert.deepEqual(parseRoute(""), { view: "home" });
  assert.deepEqual(parseRoute("#today"), { view: "home" });
  assert.deepEqual(parseRoute("#workout"), { view: "home" });
  assert.deepEqual(parseRoute("#exercise-history"), { view: "home" });
  assert.deepEqual(parseRoute("#session"), { view: "home" });
  assert.deepEqual(parseRoute("#nonsense"), { view: "home" });
  assert.deepEqual(parseRoute(undefined), { view: "home" });
});

test("gives each view a hash that parses back to it", () => {
  for (const [view, id] of [["home"], ["workouts"], ["history"], ["workout", "7"], ["edit", "7"], ["edit", "new"], ["exercise-history", "5"], ["session", "9"]]) {
    const route = parseRoute(routeHash(view, id));
    assert.equal(route.view, view);
    assert.equal(route.id, id);
  }
});

test("gives the session screens one hash of their own", () => {
  for (const view of ["ready", "player", "finish"]) {
    assert.equal(routeHash(view), "#running");
    assert.equal(isSessionView(view), true);
  }
  assert.deepEqual(parseRoute("#running"), { view: "running" });
  assert.equal(isSessionView("home"), false);
});

test("maps every view to a sidebar entry", () => {
  const ids = PAGES.map((page) => page.id);
  for (const view of ["home", "workouts", "workout", "edit", "history", "exercise-history", "session"]) assert.ok(ids.includes(pageFor(view)), view);
  assert.equal(pageFor("player"), null);
});

test("gives every tab an icon and keeps the tab bar to five with More", () => {
  const sprite = readFileSync(new URL("../../public/icons/sprite.svg", import.meta.url), "utf8");
  for (const page of TABS) assert.ok(sprite.includes(`id="${page.icon}"`), page.id);
  assert.deepEqual(TABS.map((page) => page.id), ["today", "calendar", "coach", "workouts"]);
  assert.deepEqual(MORE.map((page) => page.id), ["history", "exercises", "equipment", "settings"]);
});

test("puts Calendar second in the sidebar, keeping Exercises among the main pages there", () => {
  assert.deepEqual(SIDEBAR.map((page) => page.id), ["today", "calendar", "coach", "workouts", "history", "exercises"]);
  assert.deepEqual(SIDEBAR_SECONDARY.map((page) => page.id), ["equipment", "settings"]);
});
