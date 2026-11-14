import { test } from "node:test";
import assert from "node:assert/strict";
import { getJson, errorMessage, send, sendChange } from "../../public/js/api.js";

const answer = (body, init = {}) => async () => Response.json(body, init);

test("returns the data, fresh from the server", async () => {
  const result = await getJson("/api/workouts", answer([1, 2]));

  assert.deepEqual(result, { data: [1, 2], stale: false });
});

test("marks a copy from the service worker's cache as stale", async () => {
  const result = await getJson("/api/workouts", answer([1], { headers: { "x-served-from": "cache" } }));

  assert.deepEqual(result, { data: [1], stale: true });
});

test("throws on an error answer", async () => {
  await assert.rejects(getJson("/api/workouts", answer({}, { status: 503 })), /HTTP 503/);
  await assert.rejects(
    getJson("/api/today", answer({ error: { code: "no_workouts", message: "nothing yet" } }, { status: 404 })),
    (error) => error.status === 404 && error.code === "no_workouts",
  );
});

test("asks for the given path", async () => {
  let asked;
  await getJson("/api/history", async (path) => { asked = path; return Response.json({}); });

  assert.equal(asked, "/api/history");
});

test("errorMessage reads the message of an API error", () => {
  assert.equal(errorMessage({ error: { code: "not_found", message: "Workout 9 not found" } }, 404), "Workout 9 not found");
  assert.equal(errorMessage(undefined, 502), "HTTP 502");
  assert.equal(errorMessage({ error: { code: "invalid" } }, 422), "HTTP 422");
});

test("send writes JSON, and asks for JSON back", async () => {
  let asked;
  await send("/api/settings", { method: "PATCH", body: { unit: "kg" }, fetchFn: async (path, init) => { asked = { path, init }; return Response.json({}); } });

  assert.equal(asked.path, "/api/settings");
  assert.equal(asked.init.method, "PATCH");
  assert.equal(asked.init.body, '{"unit":"kg"}');
  assert.deepEqual(asked.init.headers, { "Content-Type": "application/json", Accept: "application/json" });
});

test("send posts without a body when given none", async () => {
  let asked;
  await send("/api/auth/logout", { fetchFn: async (path, init) => { asked = init; return Response.json({}); } });

  assert.equal(asked.method, "POST");
  assert.equal(asked.body, undefined);
  assert.deepEqual(asked.headers, { Accept: "application/json" });
});

test("sendChange answers null once saved, else the problem to show", async () => {
  const answer = (status, body) => async () => ({ ok: status < 300, status, json: async () => body });
  assert.equal(await sendChange({ method: "POST", path: "/api/goals", body: {} }, answer(201, {})), null);
  assert.equal(await sendChange({ method: "POST", path: "/api/goals" }, answer(422, { error: { message: "Title can't be blank" } })), "Title can't be blank");
  assert.equal(await sendChange({ method: "DELETE", path: "/api/goals/1" }, async () => { throw new TypeError("offline"); }), "Can't reach the server. Try again once you're online.");
});
