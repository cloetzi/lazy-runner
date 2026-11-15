// End to end: a session run in a real browser against a running server,
// with the connection lost before the finish. Needs a server with a fresh
// database at BASE_URL, logging to SERVER_LOG (CI starts one, with
// SECURE_COOKIES=false for plain http); run with `npm run test:e2e`. The
// first thing it does is what a new install's owner does: read the setup
// code in the log, create the account on the setup screen and import an
// example program.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { chromium, request } from "playwright";

// axe-core, run in the page at a few points along the way: WCAG A and AA
// plus axe's best practices, so a missing name or a skipped heading fails.
const axeSource = await readFile(createRequire(import.meta.url).resolve("axe-core/axe.min.js"), "utf8");

const BASE_URL = process.env.BASE_URL ?? "http://localhost:3000";
const SERVER_LOG = process.env.SERVER_LOG ?? "server.log";
const OWNER = { username: "e2e-runner", password: "a long enough password" };

let browser;
let api;
// The owner's cookies, for every browser context and the API checks.
let signedIn;

// The main button ignores a tap just after its meaning changes (a double
// tap), so a quick test waits that out as a person would.
async function tapMain(page) {
  await page.waitForTimeout(750);
  await page.locator("#main-action").click();
}

// The server may still be installing gems or migrating when this starts.
async function serverUp({ timeout = 300_000 } = {}) {
  const until = Date.now() + timeout;
  for (;;) {
    try {
      if ((await api.get("/api/version")).ok()) return;
    } catch {
      // Not listening yet.
    }
    if (Date.now() > until) throw new Error(`no server at ${BASE_URL}`);
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
}

// The code the boot printed for a fresh install's owner.
async function setupCode() {
  const log = await readFile(SERVER_LOG, "utf8").catch(() => "");
  const code = [...log.matchAll(/the setup code ([A-Z0-9-]+)/g)].at(-1)?.[1];
  assert.ok(code, `no setup code in ${SERVER_LOG}: start the server on a fresh database, logging there`);
  return code;
}

// No axe violations on what the page shows now.
async function accessible(page, where) {
  if (!(await page.evaluate(() => "axe" in window))) await page.evaluate(axeSource);
  const { violations } = await page.evaluate(() => axe.run(document, {
    runOnly: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa", "best-practice"],
  }));
  const found = violations.map((v) => `${v.id}: ${v.nodes.map((node) => node.target.join(" ")).join(", ")}`);
  assert.deepEqual(found, [], `axe on ${where}`);
}

// Opens a page as the owner, its errors collected.
async function ownerPage(options = {}) {
  const context = await browser.newContext({ baseURL: BASE_URL, viewport: { width: 390, height: 844 }, storageState: signedIn, ...options });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  return { context, page, errors };
}

before(async () => {
  api = await request.newContext({ baseURL: BASE_URL });
  await serverUp();
  browser = await chromium.launch();

  // A fresh install sends you to set it up, then signs you in.
  const context = await browser.newContext({ baseURL: BASE_URL, viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  await page.goto("/calendar.html");
  await page.waitForURL(/\/signin\.html\?next=%2Fcalendar\.html/);
  const setup = page.locator("#setup-form");
  await setup.locator('input[name="setup_code"]').fill(await setupCode());
  await setup.locator('input[name="username"]').fill(OWNER.username);
  await setup.locator('input[name="password"]').fill(OWNER.password);
  await setup.getByRole("button", { name: "Create the account" }).click();

  // A first sign-in shows the welcome screen, which can be skipped whole.
  await page.waitForURL(/\/welcome\.html\?next=%2Fcalendar\.html/);
  await page.getByText("Step 1 of 4").waitFor();
  await page.getByRole("button", { name: "Skip set-up" }).click();
  await page.waitForURL(/\/calendar\.html(#.*)?$/);

  // A new account has nothing to train: Today points at the example
  // programs, with the rest of set-up under it, and importing one on
  // Settings fills the workouts.
  await page.goto("/");
  await page.locator("#setup-later").getByRole("link", { name: "Invite someone" }).waitFor();
  assert.equal(await page.locator("#today-setup").isHidden(), true);
  await page.locator("#setup-examples").click();
  await page.waitForURL(/\/settings\.html#examples$/);
  for (const [slug, name] of [["cycle-1", "Cycle 1"], ["home-strength", "Home strength"]]) {
    await page.locator(`#example-list [data-import="${slug}"]`).click();
    await page.locator("#examples-done").getByText(`${name} is in your workouts`).waitFor();
    await page.locator("#example-list > li", { hasText: name }).getByText("Imported ✓").waitFor();
  }
  // What is left of set-up is on Today, until hidden.
  await page.goto("/");
  const setupCard = page.locator("#today-setup");
  await setupCard.getByRole("link", { name: "Tell the app what you own" }).waitFor();
  await setupCard.getByText("Add it to your Home Screen").waitFor();
  await accessible(page, "Today with the set-up card");
  await setupCard.getByRole("button", { name: "Hide" }).click();
  await page.reload();
  await page.locator("#today h2").waitFor();
  assert.equal(await setupCard.isHidden(), true);
  signedIn = await context.storageState();
  await context.close();

  await api.dispose();
  api = await request.newContext({ baseURL: BASE_URL, storageState: signedIn });
}, { timeout: 360_000 });

after(async () => {
  await browser?.close();
  await api?.dispose();
});

async function getJson(path) {
  const response = await api.get(path);
  assert.equal(response.status(), 200, `GET ${path}`);
  return response.json();
}

// Waits for the outbox to empty into the server, which it does on its own
// once the browser is back online.
async function eventually(check, { timeout = 15_000 } = {}) {
  const until = Date.now() + timeout;
  for (;;) {
    const result = await check();
    if (result) return result;
    if (Date.now() > until) assert.fail("timed out waiting for the server");
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}

test("runs Workout 1, finishes offline and syncs once back online", async () => {
  const programs = await getJson("/api/workouts");
  const workout = programs.flatMap((program) => program.workouts).find((w) => w.example_slug === "cycle-1-workout-1");
  const { context, page, errors } = await ownerPage();

  await page.goto(`/#workout/${workout.id}`);
  await page.locator("#workout-start").click();
  await page.locator("#ready-go").waitFor();
  await accessible(page, "Get ready");
  // Start is on screen without scrolling, named for what it starts.
  assert.equal(await page.locator("#ready-go").textContent(), "Start warm-up");
  const start = await page.locator("#ready-go").boundingBox();
  assert.ok(start.y + start.height <= page.viewportSize().height, "Start is below the fold");
  await page.locator("#ready-go").click();

  // The warm-up comes first; skip the rest of it in one go, which can be undone.
  await page.locator("#skip-part").click();
  await page.locator("#player").getByText("Goblet squat", { exact: true }).waitFor();
  await page.locator("#toast").getByRole("button", { name: "Undo" }).click();
  await page.locator("#skip-part").waitFor(); // back in the warm-up
  await page.locator("#skip-part").click();
  await page.locator("#player").getByText("Goblet squat", { exact: true }).waitFor();
  await accessible(page, "the player");
  await tapMain(page); // goblet squat, set 1
  await page.locator("#player").getByText("Straight-leg deadlift", { exact: true }).waitFor();
  await tapMain(page); // deadlift, set 1

  const sessionId = await eventually(async () => {
    const sessions = await getJson("/api/sessions");
    return sessions.find((s) => s.workout.id === workout.id && s.status === "in_progress" && s.sets_done === 2)?.id;
  });

  // A rest shows its dial where the figure goes, not an exercise animation.
  await page.locator("#rest-dial").waitFor();
  assert.equal(await page.locator("#figure").isHidden(), true);

  // Every countdown has a visible Pause button that turns into Resume.
  await page.locator("#pause").click();
  await page.locator("#paused-note").waitFor();
  await accessible(page, "a paused rest");
  assert.equal(await page.locator("#pause").textContent(), "Resume");
  await page.locator("#pause").click();
  await page.locator("#paused-note").waitFor({ state: "hidden" });

  await context.setOffline(true);
  // A rest has one way forward, named for it.
  assert.equal(await page.locator("#skip").isHidden(), true);
  assert.equal(await page.locator("#main-action").textContent(), "Start set 2 now");
  await tapMain(page); // the rest
  await page.locator("#player").getByText("Goblet squat", { exact: true }).waitFor();
  await tapMain(page); // goblet squat, set 2, logged offline
  await page.locator("#quit").click();
  await page.locator('#end-sheet button[value="finish"]').waitFor();
  await accessible(page, "the end sheet");
  await page.locator('#end-sheet button[value="finish"]').click();
  await page.locator('[data-feedback="right"]').waitFor();
  await accessible(page, "the finish screen");
  await page.locator('[data-feedback="right"]').click();
  await page.locator("#finish-note").fill("Left knee complained on the step-downs");
  await page.locator("#finish-save").click();
  await page.locator("#finish-result").getByText("Saved on this device").waitFor();

  const offline = await getJson(`/api/sessions/${sessionId}`);
  assert.equal(offline.status, "in_progress");

  await context.setOffline(false);
  const session = await eventually(async () => {
    const found = await getJson(`/api/sessions/${sessionId}`);
    return found.status === "done" && found;
  });

  assert.equal(session.completion.ended_early, true);
  assert.equal(session.completion.feedback, "right");
  assert.equal(session.completion.note, "Left knee complained on the step-downs");
  assert.equal(session.exercises.find((e) => e.exercise.name === "Goblet squat").part, "workout");
  const done = session.exercises.flatMap((e) => e.sets.filter((s) => s.status === "done").map(() => e.exercise.name));
  assert.deepEqual(done.sort(), ["Goblet squat", "Goblet squat", "Straight-leg deadlift"]);
  assert.deepEqual(errors, []);
  await context.close();
});

// Fetched ahead while online, the whole app opens offline (#267): a workout
// never opened before, the calendar, the coach board and history.
test("opens another workout, the calendar, the coach board and history offline", async () => {
  const programs = await getJson("/api/workouts");
  const other = programs.flatMap((program) => program.workouts).find((w) => w.example_slug === "home-strength-b");
  const { context, page, errors } = await ownerPage({ viewport: { width: 820, height: 1180 } });

  await page.goto("/");
  await page.locator("#today h2, #today .card").first().waitFor();
  // Once the page has fetched ahead, the worker has the workout it never opened.
  await eventually(() => page.evaluate(async (id) => {
    const data = await caches.open("data");
    return Boolean(await data.match(`/api/workouts/${id}`)) && Boolean(await data.match(`/api/coach?today=${new Date().toLocaleDateString("sv")}`));
  }, other.id));

  await context.setOffline(true);
  await page.goto("/#history");
  await page.locator("#history-week").getByText("This week").waitFor();
  await page.locator(".offline-badge:visible").getByText("Offline").waitFor();
  await page.goto("/calendar.html");
  await page.locator("#calendar-body .week-days").waitFor();
  assert.doesNotMatch(await page.locator("#calendar-note").textContent(), /Could not load|no copy/);
  await page.goto("/coach.html");
  await page.locator("#coach-note").getByText("Writing notes and goals needs a connection.").waitFor();
  assert.doesNotMatch(await page.locator("#coach-note").textContent(), /no copy/);
  // Last: Get ready keeps the session on screen from here on.
  await page.goto(`/#workout/${other.id}`);
  await page.locator("#workout-title").getByText(other.title).waitFor();
  await page.locator("#workout-start").click();
  await page.locator("#ready-go").waitFor();

  assert.deepEqual(errors, []);
  // The session never started online: closing drops what this page queued.
  await context.close();
});

test("plans a session on the calendar and moves it to another day", async () => {
  const { context, page, errors } = await ownerPage();

  await page.goto("/calendar.html");
  const today = await page.evaluate(() => {
    const now = new Date();
    return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
  });
  const later = await page.evaluate((date) => {
    const day = new Date(`${date}T12:00:00Z`);
    day.setUTCDate(day.getUTCDate() + 9);
    return day.toISOString().slice(0, 10);
  }, today);

  // Today's plus offers a workout or an activity.
  await page.locator(`[data-add="${today}"]`).click();
  await page.locator('#add-sheet button[value="workout"]').click();
  await page.locator("#plan-sheet").getByText("Session A", { exact: true }).click();
  await page.locator('#plan-sheet textarea[name="note"]').fill("Easy legs before the long run");
  await page.locator('#plan-sheet button[value="plan"]').click();

  const planned = await eventually(async () => {
    const sessions = await getJson(`/api/sessions?from=${today}&to=${today}`);
    return sessions.find((s) => s.workout.title === "Session A" && s.status === "planned");
  });
  assert.equal(planned.note, "Easy legs before the long run");
  assert.equal(planned.created_by, "manual");

  // The calendar reads the server again once the plan is sent: open it by its id.
  await page.locator(`[data-open="${planned.id}"]`).click();
  await page.locator("#session-sheet [data-later]").click();
  await page.locator('#session-sheet input[name="later"]').fill(later);
  await page.locator("#session-sheet [data-move-later]").click();

  const moved = await eventually(async () => {
    const found = (await getJson(`/api/sessions?from=${today}&to=${later}`)).find((s) => s.id === planned.id);
    return found?.date === later && found;
  });
  assert.equal(moved.status, "planned");

  // Its week shows it, under the day it moved to.
  await page.goto(`/calendar.html#${later}`);
  await page.locator(`[data-date="${later}"] [data-open="${planned.id}"]`).waitFor();
  assert.deepEqual(errors, []);
  await context.close();
});

test("logs a run on the calendar, and Today asks how hard an imported one was", async () => {
  const { context, page, errors } = await ownerPage();

  await page.goto("/calendar.html");
  const today = await page.evaluate(() => {
    const now = new Date();
    return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
  });

  await page.locator(`[data-add="${today}"]`).click();
  await page.locator('#add-sheet button[value="activity"]').waitFor();
  await accessible(page, "the calendar with the add sheet open");
  await page.locator('#add-sheet button[value="activity"]').click();
  const sheet = page.locator("#activity-log-sheet");
  await sheet.locator('input[name="sport"]').fill("Run");
  await sheet.locator('input[name="time"]').fill("32");
  await sheet.locator('input[name="distance"]').fill("5.2");
  await sheet.getByText("Steady", { exact: true }).click();
  await sheet.locator('button[value="log"]').click();

  const logged = await eventually(async () => {
    const activities = await getJson(`/api/activities?from=${today}&to=${today}`);
    return activities.find((a) => a.sport === "run");
  });
  assert.equal(logged.distance_m, 5200);
  assert.equal(logged.moving_seconds, 1920);
  assert.equal(logged.rpe, 5);
  await page.locator(`[data-date="${today}"] [data-activity="${logged.id}"]`).waitFor();

  // An activity sent by a script, as a watch export would be: Today asks once.
  const response = await api.post("/api/activities", {
    headers: { "Sec-Fetch-Site": "same-origin" },
    data: { activities: [{ date: today, today, sport: "trail_running", source: "watch", external_id: "e2e-1", distance_m: 8000 }] },
  });
  assert.equal(response.status(), 200);
  const [imported] = (await response.json()).activities;

  await page.goto("/");
  const ask = page.locator("#rpe-sheet");
  await ask.waitFor();
  await ask.getByRole("button", { name: "Hard" }).click();
  await eventually(async () => (await getJson(`/api/activities?from=${today}&to=${today}`)).find((a) => a.id === imported.id)?.rpe === 7);
  await page.locator(`[data-today-activity="${imported.id}"]`).waitFor();

  await page.reload();
  await page.locator(`[data-today-activity="${imported.id}"]`).waitFor();
  assert.equal(await page.locator("#rpe-sheet[open]").count(), 0, "asked once only");
  assert.deepEqual(errors, []);
  await context.close();
});

test("plans a weekly ride and a maybe-hike, and logging the hike ticks it off", async () => {
  const { context, page, errors } = await ownerPage();

  await page.goto("/calendar.html");
  const today = await page.evaluate(() => {
    const now = new Date();
    return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
  });

  // Every week on today's weekday, from today: tentative until I'm going.
  await page.locator(`[data-add="${today}"]`).click();
  await page.locator('#add-sheet button[value="routine"]').click();
  const form = page.locator("#routine-sheet");
  await form.locator('input[name="sport"]').fill("Ride");
  await form.locator('input[name="minutes"]').fill("90");
  await form.getByRole("button", { name: "Plan" }).click();
  const ride = page.locator(`[data-date="${today}"] .routine-row`, { hasText: "Ride" });
  await ride.getByText("Maybe").waitFor();
  await ride.locator("button").click();
  await page.locator("#routine-day-sheet").getByRole("button", { name: "I'm going" }).click();
  await ride.getByText("Planned").waitFor();

  // A one-off hike today, as a maybe; Log it now links the activity to it.
  await page.locator(`[data-add="${today}"]`).click();
  await page.locator('#add-sheet button[value="once"]').click();
  await form.locator('input[name="sport"]').fill("Hike");
  await form.getByRole("button", { name: "Plan" }).click();
  const hike = page.locator(`[data-date="${today}"] .routine-row`, { hasText: "Hike" });
  await hike.locator("button").click();
  await page.locator("#routine-day-sheet").getByRole("button", { name: "Log it now" }).click();
  const log = page.locator("#activity-log-sheet");
  assert.equal(await log.locator('input[name="sport"]').inputValue(), "Hike");
  await log.locator('input[name="time"]').fill("2:10:00");
  await log.locator('button[value="log"]').click();
  await hike.waitFor({ state: "detached" });
  await page.locator(`[data-date="${today}"] .activity-row`, { hasText: "✓ Hike" }).waitFor();

  const calendar = await getJson(`/api/calendar?from=${today}&to=${today}&today=${today}`);
  assert.deepEqual(calendar.routine_days.map((d) => d.state).sort(), ["confirmed", "done"]);
  assert.deepEqual(errors, []);
  await context.close();
});

test("builds a workout of your own in the editor and runs it", async () => {
  const { context, page, errors } = await ownerPage();
  const form = page.locator("#edit-form");
  const addExercise = async (name) => {
    await form.locator("[data-act=add-step]").click();
    await page.locator("#picker-search").fill(name);
    await page.locator("#picker [data-pick]").filter({ has: page.getByText(name, { exact: true }) }).click();
  };

  await page.goto("/#workouts");
  await page.locator("#new-workout").click();
  await form.locator("input[data-field=title]").fill("Quick core");
  await form.locator("select[data-field=warmup]").selectOption("none");
  await form.locator("select[data-field=cooldown]").selectOption("none");
  await addExercise("Dead bug");
  // The editor hides the navigation: no tap on a tab can leave the draft.
  assert.equal(await page.locator(".tabbar").isVisible(), false);
  await accessible(page, "the editor");
  await addExercise("Push-up");
  // Push-ups first: the step's own up button, then fewer reps.
  const pushUp = form.locator(".editor-step", { hasText: "Push-up" });
  await pushUp.locator("[data-act=step-up]").click();
  await pushUp.locator("[data-act=amount-down]").click();
  await page.locator("#edit-save").click();

  await page.waitForURL(/#workout\/\d+$/);
  await page.locator("#workout-saved").getByText("Created").waitFor();
  const id = Number(page.url().split("/").pop());
  const workout = await getJson(`/api/workouts/${id}`);
  assert.deepEqual(workout.blocks[0].steps.map((s) => [s.exercise.name, s.reps]), [["Push-up", 9], ["Dead bug", 10]]);
  assert.deepEqual([workout.warmup, workout.cooldown], ["none", "none"]);
  // Edit is at the top; Duplicate and Delete are under More.
  await page.locator("#workout-edit").waitFor();
  await page.locator(".more-actions summary").click();
  await page.locator('[data-own="duplicate"]').waitFor();
  await accessible(page, "the workout view with More open");
  await page.keyboard.press("Escape");
  await page.locator('[data-own="duplicate"]').waitFor({ state: "hidden" });

  // Nothing to pick up, so no Get ready: the player starts.
  await page.locator("#workout-start").click();
  await page.locator("#player").getByText("Push-up", { exact: true }).waitFor();
  await tapMain(page);
  await page.locator("#player").getByText("Dead bug", { exact: true }).waitFor();
  await tapMain(page);
  await page.locator("#finish-save").click();
  await page.locator("#finish-done").waitFor();

  const session = await eventually(async () => {
    const found = (await getJson("/api/sessions")).find((s) => s.workout.id === id && s.status === "done");
    return found && getJson(`/api/sessions/${found.id}`);
  });
  assert.deepEqual(session.exercises.map((e) => e.exercise.name), ["Push-up", "Dead bug"]);
  assert.deepEqual(errors, []);
  await context.close();
});

test("sets a goal on the Coach tab, writes a status, and accepts the agent's proposal", async () => {
  const { context, page, errors } = await ownerPage();

  await page.goto("/coach.html");
  // A new account's Coach tab explains itself and starts with a goal.
  await page.locator(".coach-intro").getByRole("button", { name: "Add a goal" }).click();
  const goalSheet = page.locator("#goal-sheet");
  await goalSheet.locator('input[name="title"]').waitFor();
  await accessible(page, "the Coach tab with the goal sheet open");
  await goalSheet.locator('input[name="title"]').fill("Ski season with quiet knees");
  await goalSheet.getByRole("button", { name: "Save" }).click();
  await page.locator(".goal-list").getByText("Ski season with quiet knees").waitFor();

  await page.locator('[data-write="status"]').click();
  const noteSheet = page.locator("#note-sheet");
  await noteSheet.locator('textarea[name="body"]').fill("Base block, week 1.");
  await noteSheet.locator('select[name="author"]').selectOption("other");
  await noteSheet.locator('input[name="authorName"]').fill("Mara");
  await noteSheet.getByRole("button", { name: "Save" }).click();
  await page.locator("#status-title").locator("..").locator("..").getByText("Base block, week 1.").waitFor();
  const board = await getJson("/api/coach");
  assert.equal(board.status.author_kind, "human");
  assert.equal(board.status.author_name, "Mara");

  // An agent can only propose a goal: it waits on the board for Accept.
  const token = await api.post("/api/account/tokens", { headers: { "Sec-Fetch-Site": "same-origin" }, data: { name: "Coach e2e" } });
  const { secret } = await token.json();
  const agent = await request.newContext({ baseURL: BASE_URL });
  const proposed = await agent.post("/mcp", {
    headers: { Accept: "application/json, text/event-stream", Host: new URL(BASE_URL).host, Authorization: `Bearer ${secret}` },
    data: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "propose_goal", arguments: { title: "Core twice a week", reason: "Your back gets stiff on long runs" } } },
  });
  assert.equal(proposed.status(), 200);
  await agent.dispose();
  await page.reload();
  await page.getByText("Proposed: Core twice a week").waitFor();
  await page.getByRole("button", { name: "Accept" }).click();
  await page.locator(".goal-list").getByText("Core twice a week").waitFor();
  assert.deepEqual((await getJson("/api/goals")).goals.map((g) => g.title), ["Ski season with quiet knees", "Core twice a week"]);
  assert.deepEqual(errors, []);
  await context.close();
});

test("makes an API token on Settings that an assistant signs in to /mcp with", async () => {
  const { context, page, errors } = await ownerPage();

  await page.goto("/settings.html");
  // The About card names the running version: a release, or a dev build.
  await page.locator("#about-version").getByText(/^The Lazy Runner( \d+\.\d+\.\d+|, development build)$/).waitFor();
  await accessible(page, "Settings");
  // Test sound plays where the browser has audio, and says so where not.
  await page.getByRole("button", { name: "Test sound" }).click();
  await page.waitForTimeout(200);
  assert.equal(await page.locator("#test-sound-note").isHidden(), true);
  assert.deepEqual(errors, []);
  await page.locator('#new-token input[name="name"]').fill("Trainer agent");
  await page.locator("#new-token").getByRole("button", { name: "Make a token" }).click();
  await page.waitForFunction(() => document.querySelector("#new-token-secret input").value !== "");
  const secret = await page.locator("#new-token-secret input").inputValue();
  assert.match(secret, /^lr_[A-Za-z0-9_-]{43}$/);
  await page.locator("#tokens").getByText("Trainer agent").waitFor();
  // The card says where to connect, with the new token in the command.
  const mcpUrl = `${new URL(BASE_URL).origin}/mcp`;
  assert.equal(await page.locator("#mcp-url input").inputValue(), mcpUrl);
  assert.equal(await page.locator("#mcp-command input").inputValue(),
    `claude mcp add --transport http lazy-runner ${mcpUrl} --header "Authorization: Bearer ${secret}"`);

  const agent = await request.newContext({ baseURL: BASE_URL });
  const call = (headers) => agent.post("/mcp", {
    headers: { Accept: "application/json, text/event-stream", Host: new URL(BASE_URL).host, ...headers },
    data: { jsonrpc: "2.0", id: 1, method: "tools/list" },
  });
  assert.equal((await call({})).status(), 401);
  const listed = await call({ Authorization: `Bearer ${secret}` });
  assert.equal(listed.status(), 200);
  assert.ok((await listed.json()).result.tools.some((tool) => tool.name === "plan_sessions"));

  // Revoking it takes it out of the command again, and the assistant out.
  page.once("dialog", (dialog) => dialog.accept());
  await page.locator("#tokens li", { hasText: "Trainer agent" }).getByRole("button", { name: "Revoke" }).click();
  await page.waitForFunction(() => document.querySelector("#mcp-command input").value.endsWith('Bearer <token>"'));
  assert.equal(await page.locator("#new-token-secret").isHidden(), true);
  assert.equal((await call({ Authorization: `Bearer ${secret}` })).status(), 401);
  await agent.dispose();
  assert.deepEqual(errors, []);
  await context.close();
});

test("invites a second user, who is welcomed and sees none of the owner's things", async () => {
  const owner = await ownerPage();
  await owner.page.goto("/settings.html");
  await owner.page.locator("#user-list").getByText(OWNER.username).waitFor();
  await owner.page.locator('#new-invite-form input[name="label"]').fill("For a friend");
  await owner.page.locator("#new-invite").click();
  const linkField = owner.page.locator("#new-invite-link input");
  await linkField.waitFor();
  const link = await linkField.inputValue();
  assert.match(link, /\/signin\.html#invite\/[A-Za-z0-9_-]{43}$/);
  await owner.page.locator("#invite-list").getByText("For a friend").waitFor();

  // The invite opens on another device, nobody signed in there.
  const context = await browser.newContext({ baseURL: BASE_URL, viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(link);
  const join = page.locator("#join-form");
  await join.waitFor();
  await accessible(page, "the join form");
  await join.locator('input[name="username"]').fill("e2e-friend");
  await join.locator('input[name="password"]').fill("another long password");
  // The password can be shown, to check it before it makes the account.
  await join.getByRole("button", { name: "Show password" }).click();
  assert.equal(await join.locator('input[name="password"]').getAttribute("type"), "text");
  await join.getByRole("button", { name: "Create my account" }).click();

  // Welcome: kilograms, a kettlebell, and one example program.
  await page.waitForURL(/\/welcome\.html$/);
  const step = () => page.locator("[data-step]:not([hidden])");
  await step().getByRole("button", { name: "kg" }).waitFor();
  await accessible(page, "the welcome screen");
  await step().getByRole("button", { name: "kg" }).click();
  await step().locator('[data-value="kg"][aria-pressed="true"]').waitFor();
  await step().getByRole("button", { name: "mi" }).click();
  await step().getByRole("button", { name: "Continue" }).click();
  // Back to the units and on again; gear with no weights yet asks in kg.
  await step().getByRole("button", { name: "Back" }).click();
  await step().locator('[data-value="kg"][aria-pressed="true"]').waitFor();
  await step().getByRole("button", { name: "Continue" }).click();
  const kettlebell = step().locator("#welcome-inventory li", { hasText: "Kettlebell" });
  // Its weights show once it is ticked.
  assert.equal(await kettlebell.locator('input[data-field="new-weight"]').count(), 0);
  await kettlebell.locator('input[data-field="owned"]').check();
  await kettlebell.getByText("Saved").waitFor();
  await kettlebell.locator('[data-unit="kg"][aria-pressed="true"]').waitFor();
  // Weights go in one at a time, as chips: a typo says so, Enter adds, and
  // a common size is one tap.
  const newWeight = kettlebell.locator('input[data-field="new-weight"]');
  await newWeight.fill("2x10");
  await newWeight.press("Enter");
  await kettlebell.getByText("is not a weight").waitFor();
  await newWeight.fill("35 kg");
  await newWeight.press("Enter");
  await kettlebell.getByRole("button", { name: "Remove 35 kg" }).waitFor();
  assert.equal(await newWeight.evaluate((field) => field === document.activeElement), true, "the field keeps the focus");
  await kettlebell.getByRole("button", { name: "+ 8" }).click();
  await kettlebell.getByRole("button", { name: "Remove 8 kg" }).click();
  await kettlebell.getByRole("button", { name: "+ 8" }).waitFor();
  await accessible(page, "the gear step with weights");
  await step().getByRole("button", { name: "Continue" }).click();
  // What an example holds shows before importing it.
  const homeStrength = step().locator("#welcome-examples > li", { hasText: "Home strength" });
  await homeStrength.getByText("What's in it").click();
  await homeStrength.getByText("Goblet squat").first().waitFor();
  await step().locator('[data-import="home-strength"]').click();
  await step().getByText("Home strength is in your workouts").waitFor();
  await step().getByRole("button", { name: "Continue" }).click();
  // Training days: Session A and B take turns on them, every week.
  await step().getByText("Session A and Session B take turns").waitFor();
  await accessible(page, "the training days step");
  for (const day of ["Monday", "Wednesday", "Friday"]) await step().getByRole("checkbox", { name: day }).check();
  await step().getByRole("button", { name: "Done" }).click();
  await page.waitForURL(`${BASE_URL}/`);
  // Gear, a program and the week: nothing is left to set up.
  await page.locator("#today h2").waitFor();
  assert.equal(await page.locator("#today-setup").isHidden(), true);

  const friend = await request.newContext({ baseURL: BASE_URL, storageState: await context.storageState() });
  const read = async (path) => (await friend.get(path)).json();
  assert.deepEqual((await read("/api/me")).user, { ...(await read("/api/me")).user, owner: false, welcomed: true });
  assert.equal((await read("/api/settings")).unit, "kg");
  assert.equal((await read("/api/settings")).distance_unit, "mi");
  assert.deepEqual((await read("/api/routines")).routines.map((routine) => [routine.workout.title, routine.weekdays]),
    [["Session A", [1, 5]], ["Session B", [3]]]);
  assert.deepEqual((await read("/api/equipment")).find((item) => item.slug === "kettlebell"), {
    ...(await read("/api/equipment")).find((item) => item.slug === "kettlebell"), owned: true, weights: [35], unit: "kg",
  });
  assert.deepEqual((await read("/api/workouts")).map((program) => program.name), ["Home strength"]);
  assert.deepEqual(await read("/api/sessions"), []);
  assert.ok((await getJson("/api/sessions")).length > 0, "the owner has sessions of their own");
  // The generic weight comes with the kettlebell.
  const owned = (await read("/api/equipment")).filter((item) => item.owned);
  assert.deepEqual(owned.map((item) => [item.slug, item.weights]), [["weight", [35]], ["kettlebell", [35]]]);

  // The used link, opened again on another device, says so before any form.
  const stranger = await browser.newContext({ baseURL: BASE_URL });
  const strangerPage = await stranger.newPage();
  await strangerPage.goto(link);
  await strangerPage.locator("#invite-gone").getByText("This invite link doesn't work").waitFor();
  assert.equal(await strangerPage.locator("#join-form").isHidden(), true);
  await accessible(strangerPage, "a used invite link");
  await strangerPage.getByRole("button", { name: "I have an account: sign in" }).click();
  await strangerPage.locator("#signin-form").getByText("Forgot it?").waitFor();
  await stranger.close();

  // Only the owner manages users; the owner now sees them, the invite used.
  await page.goto("/settings.html");
  await page.locator("#account-who").getByText("e2e-friend").waitFor();
  assert.equal(await page.locator("#users").isHidden(), true);
  await owner.page.reload();
  await owner.page.locator("#user-list").getByText("e2e-friend").waitFor();
  await owner.page.locator("#invite-list").getByText("No invites waiting").waitFor();

  assert.deepEqual(errors, []);
  assert.deepEqual(owner.errors, []);
  await friend.dispose();
  await context.close();
  await owner.context.close();
});

test("signs out on Settings, and back in on the sign-in screen", async () => {
  const { context, page, errors } = await ownerPage();

  await page.goto("/settings.html");
  await page.locator("#account-who").getByText(OWNER.username).waitFor();
  await page.locator("#devices").getByText("(this device)").waitFor();
  await page.locator("#sign-out").click();
  await page.waitForURL(/\/signin\.html$/);
  assert.equal(await page.evaluate(() => localStorage.getItem("account")), null);

  // Signed out: the app's pages send you to sign in, and back afterwards.
  await page.goto("/settings.html");
  await page.waitForURL(/\/signin\.html\?next=%2Fsettings\.html$/);
  const form = page.locator("#signin-form");
  await form.locator('input[name="password"]').fill("not the password");
  await form.locator('input[name="username"]').fill(OWNER.username);
  await form.getByRole("button", { name: "Sign in" }).click();
  await form.getByText("Wrong username or password").waitFor();
  await form.locator('input[name="password"]').fill(OWNER.password);
  await form.getByRole("button", { name: "Sign in" }).click();
  await page.waitForURL(/\/settings\.html$/);
  await page.locator("#account-who").getByText(OWNER.username).waitFor();
  assert.deepEqual(errors, []);
  await context.close();
});
