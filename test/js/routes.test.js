import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PAGES, TABS, MORE, SIDEBAR, SIDEBAR_SECONDARY, parseRoute, routeHash, pageFor, isSessionView, backFor, viewLabel } from "../../public/js/routes.js";

test("parses the views the home page can open from the hash", () => {
  assert.deepEqual(parseRoute("#workouts"), { view: "workouts" });
  assert.deepEqual(parseRoute("#history"), { view: "history" });
  assert.deepEqual(parseRoute("#workout/12"), { view: "workout", id: "12" });
  assert.deepEqual(parseRoute("#edit/12"), { view: "edit", id: "12" });
  assert.deepEqual(parseRoute("#edit/new"), { view: "edit", id: "new" });
  assert.deepEqual(parseRoute("#exercise-history/5"), { view: "exercise-history", id: "5" });
  assert.deepEqual(parseRoute("#session/9"), { view: "session", id: "9" });
  assert.deepEqual(parseRoute("#examples"), { view: "examples" });
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

test("gives every page an icon and keeps the tab bar to five with More", () => {
  const sprite = readFileSync(new URL("../../public/icons/sprite.svg", import.meta.url), "utf8");
  for (const page of PAGES) assert.ok(page.icon && sprite.includes(`id="${page.icon}"`), page.id);
  assert.deepEqual(TABS.map((page) => page.id), ["today", "calendar", "coach", "workouts"]);
  assert.deepEqual(MORE.map((page) => page.id), ["history", "exercises", "equipment", "settings"]);
});

test("puts Calendar second in the sidebar, keeping Exercises among the main pages there", () => {
  assert.deepEqual(SIDEBAR.map((page) => page.id), ["today", "calendar", "coach", "workouts", "history", "exercises"]);
  assert.deepEqual(SIDEBAR_SECONDARY.map((page) => page.id), ["equipment", "settings"]);
});

const ORIGIN = "https://app.example";

test("sends Back to the view a detail was opened from on the home page", () => {
  assert.deepEqual(backFor("workout", { cameFrom: "#today" }), { label: "Today", href: "#today", page: "today", inPage: true });
  assert.deepEqual(backFor("workout", { cameFrom: "#workouts" }), { label: "Workouts", href: "#workouts", page: "workouts", inPage: true });
  assert.deepEqual(backFor("exercise-history", { cameFrom: "#session/9" }), { label: "Session", href: "#session/9", page: "history", inPage: true });
  assert.deepEqual(backFor("session", { cameFrom: "#history" }), { label: "History", href: "#history", page: "history", inPage: true });
});

test("sends Back to the page of the app that linked to a detail", () => {
  assert.deepEqual(backFor("exercise-history", { referrer: `${ORIGIN}/library.html`, origin: ORIGIN }),
    { label: "Exercises", href: "/library.html", page: "exercises", inPage: false });
  assert.deepEqual(backFor("session", { referrer: `${ORIGIN}/calendar.html`, origin: ORIGIN }),
    { label: "Calendar", href: "/calendar.html", page: "calendar", inPage: false });
});

test("falls back to a detail's usual parent", () => {
  assert.deepEqual(backFor("workout"), { label: "Workouts", href: "#workouts", page: "workouts", inPage: true });
  assert.deepEqual(backFor("session", { referrer: "https://elsewhere.example/library.html", origin: ORIGIN }),
    { label: "History", href: "#history", page: "history", inPage: true });
  assert.equal(backFor("exercise-history", { referrer: `${ORIGIN}/`, origin: ORIGIN }).label, "History");
  assert.equal(backFor("exercise-history", { referrer: "not a url", origin: ORIGIN }).label, "History");
});

test("never sends Back into a session, the editor or the view itself", () => {
  assert.equal(backFor("workout", { cameFrom: "#running" }).label, "Workouts");
  assert.equal(backFor("workout", { cameFrom: "#edit/3" }).label, "Workouts");
  assert.equal(backFor("workout", { cameFrom: "#workout/3" }).label, "Workouts");
  // The view it came from wins over the page that linked here.
  assert.equal(backFor("session", { cameFrom: "#today", referrer: `${ORIGIN}/calendar.html`, origin: ORIGIN }).label, "Today");
});

test("names every view for the tab's title", () => {
  for (const view of ["home", "workouts", "workout", "edit", "ready", "player", "finish", "history", "exercise-history", "session"]) assert.ok(viewLabel(view), view);
  assert.equal(viewLabel("home"), "Today");
  assert.equal(viewLabel("nowhere"), null);
});
