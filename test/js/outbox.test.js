import { test } from "node:test";
import assert from "node:assert/strict";
import { createOutbox, describeChange, PARK_AFTER } from "../../public/js/outbox.js";

function memoryStorage() {
  const items = new Map();
  return { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v) };
}

// `/api/version` answers `version` (200 unless told), apart from `responses`.
function fakeServer(responses, { version = { status: 200 } } = {}) {
  const calls = [];
  const fetch = async (path, options) => {
    if (path === "/api/version") {
      if (version === "offline") throw new TypeError("Failed to fetch");
      return { ok: version.status < 300, status: version.status, redirected: false, json: async () => ({}) };
    }
    calls.push({ path, method: options.method, body: options.body && JSON.parse(options.body), user: options.headers?.["X-Lazy-Runner-User"] });
    const next = responses.shift();
    if (next === "offline") throw new TypeError("Failed to fetch");
    return {
      ok: next.status >= 200 && next.status < 300,
      status: next.status,
      redirected: next.redirected ?? false,
      json: async () => {
        if (next.html) throw new SyntaxError("Unexpected token '<'");
        return next.json;
      },
    };
  };
  return { fetch, calls };
}

test("sends requests in order and fills in saved ids", async () => {
  const server = fakeServer([{ status: 201, json: { id: 7 } }, { status: 201, json: {} }]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  outbox.enqueue({ method: "POST", path: "/api/sessions", body: { workout_id: 1 }, saveAs: "session:a" });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{session:a}/sets", body: { set_number: 1 } });

  assert.equal(await outbox.flush(), true);
  assert.deepEqual(server.calls.map((c) => c.path), ["/api/sessions", "/api/sessions/7/sets"]);
  assert.equal(outbox.pending(), 0);
  assert.deepEqual(outbox.result("session:a"), { id: 7 });
});

test("keeps requests while offline and sends them later", async () => {
  const storage = memoryStorage();
  const server = fakeServer(["offline", { status: 200, json: {} }]);
  const outbox = createOutbox({ storage, fetch: server.fetch });

  outbox.enqueue({ method: "PUT", path: "/api/exercises/3/weight", body: { value: 45, unit: "lb" } });
  assert.equal(await outbox.flush(), false);
  assert.equal(outbox.pending(), 1);
  assert.deepEqual(outbox.queued().map((e) => e.path), ["/api/exercises/3/weight"]);

  // A reload builds a new outbox from storage.
  const reloaded = createOutbox({ storage, fetch: server.fetch });
  assert.equal(await reloaded.flush(), true);
  assert.deepEqual(reloaded.queued(), []);
  assert.equal(server.calls.length, 2);
});

test("retries server errors but rejects requests the server refuses", async () => {
  const server = fakeServer([{ status: 503 }, { status: 422, json: { error: { code: "invalid", message: "Reps must be greater than 0", fields: { reps: ["must be greater than 0"] } } } }, { status: 200, json: {} }]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, now: () => "2026-10-24T10:00:00Z" });

  outbox.enqueue({ method: "POST", path: "/a" });
  outbox.enqueue({ method: "POST", path: "/b" });
  assert.equal(await outbox.flush(), false);
  assert.equal(outbox.pending(), 2);
  assert.equal(outbox.waiting(), "server");

  assert.equal(await outbox.flush(), true);
  assert.deepEqual(server.calls.map((c) => c.path), ["/a", "/a", "/b"]);
  assert.equal(outbox.waiting(), null);
  assert.deepEqual(outbox.rejected(), [
    { entry: { method: "POST", path: "/a" }, status: 422, error: "Reps must be greater than 0", at: "2026-10-24T10:00:00Z" },
  ]);
});

for (const status of [401, 403, 407]) {
  test(`keeps the whole session queued on ${status} until sign-in works again`, async () => {
    const storage = memoryStorage();
    const server = fakeServer([{ status }, { status: 201, json: { id: 9 } }, { status: 201, json: {} }]);
    const outbox = createOutbox({ storage, fetch: server.fetch });

    outbox.enqueue({ method: "POST", path: "/api/sessions", saveAs: "session:d" });
    outbox.enqueue({ method: "POST", path: "/api/sessions/{session:d}/sets" });
    assert.equal(await outbox.flush(), false);
    assert.equal(outbox.pending(), 2);
    assert.equal(outbox.waiting(), "auth");
    assert.deepEqual(outbox.rejected(), []);

    const reloaded = createOutbox({ storage, fetch: server.fetch });
    assert.equal(await reloaded.flush(), true);
    assert.deepEqual(server.calls.map((c) => c.path), ["/api/sessions", "/api/sessions", "/api/sessions/9/sets"]);
  });
}

for (const status of [408, 425, 429]) {
  test(`retries ${status} later`, async () => {
    const server = fakeServer([{ status }]);
    const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

    outbox.enqueue({ method: "POST", path: "/a" });
    assert.equal(await outbox.flush(), false);
    assert.equal(outbox.pending(), 1);
    assert.equal(outbox.waiting(), "server");
  });
}

test("treats a redirect to a sign-in page as not sent", async () => {
  const server = fakeServer([{ status: 200, redirected: true, html: true }]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  outbox.enqueue({ method: "POST", path: "/api/sessions", saveAs: "session:e" });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{session:e}/sets" });
  assert.equal(await outbox.flush(), false);
  assert.equal(outbox.pending(), 2);
  assert.equal(outbox.waiting(), "auth");
  assert.equal(outbox.result("session:e"), undefined);
});

test("keeps a request whose id is needed when the 200 is not JSON", async () => {
  const server = fakeServer([{ status: 200, html: true }]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  outbox.enqueue({ method: "POST", path: "/api/sessions", saveAs: "session:f" });
  assert.equal(await outbox.flush(), false);
  assert.equal(outbox.pending(), 1);
});

test("accepts an empty 2xx when no id is needed", async () => {
  const server = fakeServer([{ status: 204, html: true }]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  outbox.enqueue({ method: "PUT", path: "/api/exercises/3/weight" });
  assert.equal(await outbox.flush(), true);
});

test("rejects the requests that depend on a rejected one", async () => {
  const server = fakeServer([{ status: 404, json: { error: { code: "not_found", message: "Session 7 not found" } } }, { status: 200, json: {} }]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  outbox.enqueue({ method: "POST", path: "/api/sessions", saveAs: "session:b" });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{session:b}/sets" });
  outbox.enqueue({ method: "PUT", path: "/api/exercises/3/weight" });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{session:b}/complete", saveAs: "complete:b" });

  assert.equal(await outbox.flush(), true);
  assert.deepEqual(server.calls.map((c) => c.path), ["/api/sessions", "/api/exercises/3/weight"]);
  assert.equal(outbox.pending(), 0);
  assert.deepEqual(outbox.rejected().map((r) => [r.entry.path, r.status, r.error]), [
    ["/api/sessions", 404, "Session 7 not found"],
    ["/api/sessions/{session:b}/sets", null, "Not sent: Session 7 not found"],
    ["/api/sessions/{session:b}/complete", null, "Not sent: Session 7 not found"],
  ]);
});

test("keeps rejected requests across reloads until dismissed", async () => {
  const storage = memoryStorage();
  const server = fakeServer([{ status: 400, json: { error: { code: "bad_request", message: "bad" } } }]);
  const outbox = createOutbox({ storage, fetch: server.fetch });

  outbox.enqueue({ method: "POST", path: "/a" });
  await outbox.flush();

  const reloaded = createOutbox({ storage, fetch: server.fetch });
  assert.equal(reloaded.rejected().length, 1);
  reloaded.dismissRejected();
  assert.equal(createOutbox({ storage, fetch: server.fetch }).rejected().length, 0);
});

test("reads a queue saved before rejected requests were kept", async () => {
  const storage = memoryStorage();
  storage.setItem("outbox", JSON.stringify({ queue: [{ method: "POST", path: "/a" }], ids: {} }));
  const outbox = createOutbox({ storage, fetch: fakeServer([]).fetch });

  assert.equal(outbox.pending(), 1);
  assert.deepEqual(outbox.rejected(), []);
});

test("uses a remembered id without a request", async () => {
  const server = fakeServer([{ status: 201, json: {} }]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  outbox.remember("session:c", 12);
  outbox.enqueue({ method: "POST", path: "/api/sessions/{session:c}/complete", body: { feedback: "right" } });
  await outbox.flush();

  assert.equal(server.calls[0].path, "/api/sessions/12/complete");
});

// Web Locks with one lock: callbacks run one after the other.
function fakeLocks() {
  let tail = Promise.resolve();
  return {
    request(name, callback) {
      const result = tail.then(() => callback());
      tail = result.catch(() => {});
      return result;
    },
  };
}

// A server that answers a tick later and counts requests in flight.
function slowServer() {
  const calls = [];
  let inFlight = 0;
  let maxInFlight = 0;
  const fetch = async (path, options) => {
    calls.push({ path, body: options.body && JSON.parse(options.body) });
    maxInFlight = Math.max(maxInFlight, ++inFlight);
    await new Promise((resolve) => setTimeout(resolve, 1));
    inFlight--;
    return { ok: true, status: 201, redirected: false, json: async () => ({ id: calls.length }) };
  };
  return { fetch, calls, maxInFlight: () => maxInFlight };
}

test("two tabs on the same storage keep each other's entries", () => {
  const storage = memoryStorage();
  const server = fakeServer([]);
  const first = createOutbox({ storage, fetch: server.fetch });
  const second = createOutbox({ storage, fetch: server.fetch });

  first.enqueue({ method: "POST", path: "/a" });
  second.enqueue({ method: "POST", path: "/b" });
  first.enqueue({ method: "POST", path: "/c" });
  second.remember("session:x", 4);

  assert.equal(first.pending(), 3);
  assert.equal(second.pending(), 3);
  assert.deepEqual(JSON.parse(storage.getItem("outbox")).queue.map((e) => e.path), ["/a", "/b", "/c"]);
  assert.deepEqual(JSON.parse(storage.getItem("outbox")).ids, { "session:x": 4 });
});

test("only one tab sends at a time, and each entry once", async () => {
  const storage = memoryStorage();
  const server = slowServer();
  const locks = fakeLocks();
  const first = createOutbox({ storage, fetch: server.fetch, locks });
  const second = createOutbox({ storage, fetch: server.fetch, locks });

  first.enqueue({ method: "POST", path: "/api/sessions", body: { client_ref: "session:a" }, saveAs: "session:a" });
  second.enqueue({ method: "POST", path: "/api/sessions/{session:a}/sets", body: { set_number: 1 } });
  first.enqueue({ method: "POST", path: "/api/sessions/{session:a}/complete", saveAs: "complete:a" });

  const done = await Promise.all([first.flush(), second.flush()]);

  assert.deepEqual(done, [true, true]);
  assert.equal(server.maxInFlight(), 1);
  assert.deepEqual(server.calls.map((c) => c.path), ["/api/sessions", "/api/sessions/1/sets", "/api/sessions/1/complete"]);
  assert.equal(first.pending(), 0);
  assert.equal(second.pending(), 0);
  // Whichever tab sent it, the response is there for the tab that asked.
  assert.deepEqual(first.result("complete:a"), { id: 3 });
});

test("without Web Locks overlapping flushes still take each entry off once", async () => {
  const storage = memoryStorage();
  const server = slowServer();
  const first = createOutbox({ storage, fetch: server.fetch });
  const second = createOutbox({ storage, fetch: server.fetch });

  first.enqueue({ method: "PUT", path: "/a" });
  first.enqueue({ method: "PUT", path: "/b" });
  const flushes = Promise.all([first.flush(), second.flush()]);
  second.enqueue({ method: "PUT", path: "/c" });
  await flushes;
  await first.flush();

  assert.equal(first.pending(), 0);
  assert.deepEqual([...new Set(server.calls.map((c) => c.path))], ["/a", "/b", "/c"]);
});

test("keeps only the latest saved responses", async () => {
  const storage = memoryStorage();
  const server = slowServer();
  const outbox = createOutbox({ storage, fetch: server.fetch });

  for (let i = 0; i < 12; i++) outbox.enqueue({ method: "POST", path: `/r${i}`, saveAs: `r${i}` });
  await outbox.flush();

  assert.equal(outbox.result("r0"), undefined);
  assert.equal(outbox.result("r1"), undefined);
  assert.deepEqual(outbox.result("r11"), { id: 12 });
  assert.equal(Object.keys(JSON.parse(storage.getItem("outbox")).results).length, 10);
});

test("keeps working on its own copy when storage will not save", async () => {
  const storage = { getItem: () => null, setItem: () => { throw new Error("QuotaExceededError"); } };
  const server = fakeServer([{ status: 201, json: {} }, { status: 201, json: {} }]);
  const outbox = createOutbox({ storage, fetch: server.fetch });

  outbox.enqueue({ method: "POST", path: "/a" });
  outbox.enqueue({ method: "POST", path: "/b" });
  assert.equal(outbox.pending(), 2);
  assert.equal(await outbox.flush(), true);
  assert.deepEqual(server.calls.map((c) => c.path), ["/a", "/b"]);
});

test("sends a change only while the user who made it is signed in", async () => {
  const storage = memoryStorage();
  const server = fakeServer([{ status: 200, json: {} }, { status: 200, json: {} }]);
  let signedIn = 1;
  const outbox = createOutbox({ storage, fetch: server.fetch, user: () => signedIn });

  outbox.enqueue({ method: "PATCH", path: "/api/settings", body: { unit: "kg" } });
  assert.equal(outbox.queued()[0].user, 1);
  signedIn = 2;
  outbox.enqueue({ method: "PATCH", path: "/api/settings", body: { unit: "lb" } });

  assert.equal(await outbox.flush(), true);
  assert.deepEqual(server.calls.map((c) => c.body), [{ unit: "lb" }]);
  assert.equal(outbox.pending(), 0);
  assert.deepEqual(outbox.rejected(), []);
});

test("drops someone else's change unseen, with the changes that build on it", async () => {
  const storage = memoryStorage();
  const server = fakeServer([{ status: 200, json: {} }]);
  let signedIn = 1;
  const outbox = createOutbox({ storage, fetch: server.fetch, user: () => signedIn });

  outbox.enqueue({ method: "POST", path: "/api/sessions", body: {}, saveAs: "session:a" });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{session:a}/sets", body: { set_number: 1 } });
  signedIn = 2;
  outbox.enqueue({ method: "PATCH", path: "/api/settings", body: { unit: "kg" } });

  assert.equal(await outbox.flush(), true);
  assert.deepEqual(server.calls.map((c) => c.path), ["/api/settings"]);
  assert.deepEqual(outbox.rejected(), []);
});

// Someone else signed in on this device, and account.js hasn't cleared the
// queue yet: the server sees the entry was for another user.
test("drops a change unseen when the server says someone else is signed in", async () => {
  const server = fakeServer([
    { status: 409, json: { error: { code: "user_mismatch", message: "This change is another user's" } } },
    { status: 200, json: {} },
  ]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, user: () => 1 });

  outbox.enqueue({ method: "POST", path: "/api/sessions", body: {}, saveAs: "session:a" });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{session:a}/sets", body: { set_number: 1 } });
  outbox.enqueue({ method: "PATCH", path: "/api/settings", body: { unit: "kg" } });

  assert.equal(await outbox.flush(), true);
  assert.deepEqual(server.calls.map((c) => [c.path, c.user]), [["/api/sessions", "1"], ["/api/settings", "1"]]);
  assert.deepEqual(outbox.rejected(), []);
  assert.equal(outbox.pending(), 0);
});

test("rejects a 403 the app answered, rather than waiting for a sign-in", async () => {
  const server = fakeServer([{ status: 403, json: { error: { code: "forbidden", message: "Refused: the request didn't come from this app" } } }]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  outbox.enqueue({ method: "PATCH", path: "/api/settings", body: { unit: "kg" } });

  assert.equal(await outbox.flush(), true);
  assert.equal(outbox.waiting(), null);
  assert.deepEqual(outbox.rejected().map((r) => r.error), ["Refused: the request didn't come from this app"]);
});

test("starts empty once another tab cleared the queue, instead of writing it back", async () => {
  const items = new Map();
  const storage = { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v), removeItem: (k) => items.delete(k) };
  const server = fakeServer([{ status: 200, json: {} }]);
  const outbox = createOutbox({ storage, fetch: server.fetch });

  outbox.enqueue({ method: "PUT", path: "/api/exercises/3/weight", body: { value: 45, unit: "lb" } });
  storage.removeItem("outbox"); // signed out in another tab
  outbox.enqueue({ method: "PATCH", path: "/api/settings", body: { unit: "kg" } });

  assert.deepEqual(outbox.queued().map((e) => e.path), ["/api/settings"]);
});

const failing = (n, status = 500) => Array.from({ length: n }, () => ({ status, json: { error: { code: "server_error", message: "Something went wrong" } } }));

test("a change that keeps failing is parked and the rest is sent", async () => {
  const storage = memoryStorage();
  const server = fakeServer([...failing(PARK_AFTER), { status: 200, json: {} }, { status: 200, json: {} }]);
  const outbox = createOutbox({ storage, fetch: server.fetch, now: () => "2026-11-15T10:00:00Z", id: () => "p1" });

  outbox.enqueue({ method: "PATCH", path: "/api/settings", body: { unit: "kg" } });
  outbox.enqueue({ method: "PATCH", path: "/api/exercises/3/weight", body: { value: 20 } });
  outbox.enqueue({ method: "POST", path: "/api/activities", body: {} });

  for (let i = 1; i < PARK_AFTER; i++) {
    assert.equal(await outbox.flush(), false);
    assert.equal(outbox.pending(), 3);
  }
  assert.equal(await outbox.flush(), true);
  assert.deepEqual(server.calls.map((c) => c.path), [
    ...Array(PARK_AFTER).fill("/api/settings"), "/api/exercises/3/weight", "/api/activities",
  ]);
  assert.equal(outbox.pending(), 0);
  assert.equal(outbox.waiting(), null);
  assert.deepEqual(outbox.parked(), [{
    id: "p1", entries: [{ method: "PATCH", path: "/api/settings", body: { unit: "kg" } }], names: [], dependants: 0,
    status: 500, error: "Something went wrong", at: "2026-11-15T10:00:00Z",
  }]);
  // A reload still has it.
  assert.equal(createOutbox({ storage, fetch: server.fetch }).parked().length, 1);
});

test("server errors during an outage do not count", async () => {
  const server = fakeServer(failing(PARK_AFTER + 2), { version: { status: 502 } });
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  outbox.enqueue({ method: "POST", path: "/a" });
  for (let i = 0; i < PARK_AFTER + 2; i++) assert.equal(await outbox.flush(), false);
  assert.equal(outbox.pending(), 1);
  assert.deepEqual(outbox.parked(), []);
  assert.equal(outbox.waiting(), "server");
});

test("a version check that cannot connect does not count either", async () => {
  const server = fakeServer(failing(PARK_AFTER), { version: "offline" });
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  outbox.enqueue({ method: "POST", path: "/a" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  assert.equal(outbox.pending(), 1);
  assert.deepEqual(outbox.parked(), []);
});

test("a success in between starts the count again", async () => {
  const server = fakeServer([...failing(PARK_AFTER - 1), { status: 200, json: {} }, ...failing(PARK_AFTER - 1)]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  outbox.enqueue({ method: "POST", path: "/a" });
  for (let i = 1; i < PARK_AFTER; i++) await outbox.flush();
  assert.equal(await outbox.flush(), true);
  outbox.enqueue({ method: "POST", path: "/a" });
  for (let i = 1; i < PARK_AFTER; i++) assert.equal(await outbox.flush(), false);
  assert.deepEqual(outbox.parked(), []);
  assert.equal(outbox.pending(), 1);
});

test("a parked change takes the changes that build on it along, even ones queued later", async () => {
  const server = fakeServer([...failing(PARK_AFTER), { status: 200, json: {} }]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, id: () => "p1" });

  outbox.enqueue({ method: "POST", path: "/api/sessions", saveAs: "run:a", body: { status: "in_progress" } });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/sets", body: { set_number: 1 } });
  outbox.enqueue({ method: "PATCH", path: "/api/exercises/3/weight", body: { value: 20 } });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  assert.deepEqual(outbox.parked()[0].entries.map((e) => e.path), ["/api/sessions", "/api/sessions/{run:a}/sets"]);

  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/complete", saveAs: "complete:a" });
  assert.equal(await outbox.flush(), true);
  assert.deepEqual(outbox.parked()[0].entries.map((e) => e.path), ["/api/sessions", "/api/sessions/{run:a}/sets", "/api/sessions/{run:a}/complete"]);
  assert.deepEqual(outbox.rejected(), []);
  assert.equal(outbox.pending(), 0);
});

test("retrying a parked change sends it, with what builds on it, first", async () => {
  const server = fakeServer([...failing(PARK_AFTER), { status: 201, json: { id: 7 } }, { status: 201, json: {} }, { status: 200, json: {} }]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, id: () => "p1" });

  outbox.enqueue({ method: "POST", path: "/api/sessions", saveAs: "run:a" });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/sets" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  outbox.enqueue({ method: "PATCH", path: "/api/settings" });

  assert.equal(await outbox.retryParked("p1"), true);
  assert.deepEqual(server.calls.slice(PARK_AFTER).map((c) => c.path), ["/api/sessions", "/api/sessions/7/sets", "/api/settings"]);
  assert.deepEqual(outbox.parked(), []);
});

test("a retry that fails again is parked again at once", async () => {
  const server = fakeServer(failing(PARK_AFTER + 1));
  let n = 0;
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, id: () => `p${++n}` });

  outbox.enqueue({ method: "POST", path: "/a" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  assert.equal(await outbox.retryParked("p1"), true);
  assert.deepEqual(outbox.parked().map((g) => g.id), ["p2"]);
  assert.equal(outbox.pending(), 0);
});

test("discarding a parked change forgets it", async () => {
  const storage = memoryStorage();
  const server = fakeServer(failing(PARK_AFTER));
  const outbox = createOutbox({ storage, fetch: server.fetch, id: () => "p1" });

  outbox.enqueue({ method: "POST", path: "/a" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  await outbox.discardParked("p1");
  assert.deepEqual(createOutbox({ storage, fetch: server.fetch }).parked(), []);
});

test("after a discard, the next change that keeps failing is parked in turn", async () => {
  // /b fails once while /a is parked, then three times more.
  const server = fakeServer(failing(2 * PARK_AFTER + 1));
  let n = 0;
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, id: () => `p${++n}` });

  outbox.enqueue({ method: "POST", path: "/a" });
  outbox.enqueue({ method: "POST", path: "/b" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  await outbox.discardParked("p1");
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  assert.deepEqual(outbox.parked().map((g) => g.entries[0].path), ["/b"]);
  assert.equal(outbox.pending(), 0);
});

test("discarding a parked change sends what only waited behind it", async () => {
  const server = fakeServer([...failing(PARK_AFTER), { status: 201, json: {} }, { status: 200, json: { id: 5 } }, { status: 200, json: {} }]);
  let n = 0;
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, id: () => `p${++n}` });

  // Starting a planned session (its id known) and logging a set for it,
  // and a new session whose set and finish need its id.
  outbox.remember("run:a", 7);
  outbox.enqueue({ method: "PATCH", path: "/api/sessions/{run:a}", body: { status: "in_progress" } });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/sets" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/complete", saveAs: "complete:a" });
  outbox.enqueue({ method: "PATCH", path: "/api/completions/{complete:a}" });
  await outbox.flush();
  assert.equal(outbox.parked()[0].dependants, 0);

  await outbox.discardParked("p1");
  assert.deepEqual(outbox.queued().map((e) => e.path), ["/api/sessions/{run:a}/sets", "/api/sessions/{run:a}/complete", "/api/completions/{complete:a}"]);
  assert.equal(await outbox.flush(), true);
  assert.deepEqual(server.calls.slice(PARK_AFTER).map((c) => c.path), ["/api/sessions/7/sets", "/api/sessions/7/complete", "/api/completions/5"]);
  assert.deepEqual(outbox.rejected(), []);
});

test("discarding a new change drops what needs its id with it", async () => {
  const server = fakeServer([...failing(PARK_AFTER), "offline"]);
  let n = 0;
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, id: () => `p${++n}` });

  outbox.enqueue({ method: "POST", path: "/api/sessions", saveAs: "run:a" });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/complete", saveAs: "complete:a" });
  outbox.enqueue({ method: "PATCH", path: "/api/completions/{complete:a}" });
  outbox.remember("run:b", 8);
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:b}/sets" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  assert.equal(outbox.parked()[0].dependants, 2);

  await outbox.discardParked("p1");
  assert.deepEqual(outbox.queued().map((e) => e.path), ["/api/sessions/{run:b}/sets"]);
});

test("a change taken into a parked group holds back what builds on it in turn", async () => {
  const server = fakeServer(failing(PARK_AFTER));
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, id: () => "p1" });

  outbox.enqueue({ method: "POST", path: "/api/sessions", saveAs: "run:a" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/notes", saveAs: "note:a" });
  await outbox.flush();
  outbox.enqueue({ method: "PATCH", path: "/api/notes/{note:a}" });
  assert.equal(await outbox.flush(), true);

  assert.deepEqual(outbox.parked()[0].entries.map((e) => e.path), ["/api/sessions", "/api/sessions/{run:a}/notes", "/api/notes/{note:a}"]);
  assert.deepEqual(outbox.rejected(), []);
});

test("a park that leaves nothing queued doesn't stop the next failing change from being parked", async () => {
  const server = fakeServer(failing(2 * PARK_AFTER));
  let n = 0;
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, id: () => `p${++n}` });

  outbox.enqueue({ method: "POST", path: "/a" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  outbox.enqueue({ method: "POST", path: "/b" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  assert.deepEqual(outbox.parked().map((g) => g.entries[0].path), ["/a", "/b"]);
});

test("a discard waits for a send under way, so nothing goes twice", async () => {
  const server = fakeServer([...failing(PARK_AFTER), { status: 200, json: {} }, { status: 200, json: {} }]);
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  const fetch = async (path, options) => {
    if (path === "/api/other") await held;
    return server.fetch(path, options);
  };
  const outbox = createOutbox({ storage: memoryStorage(), fetch, id: () => "p1" });

  outbox.remember("run:a", 7);
  outbox.enqueue({ method: "PATCH", path: "/api/sessions/{run:a}" });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/sets" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  outbox.enqueue({ method: "PATCH", path: "/api/other" });
  const flushed = outbox.flush();
  const discarded = outbox.discardParked("p1");
  release();
  await Promise.all([flushed, discarded]);
  await outbox.flush();

  assert.deepEqual(server.calls.slice(PARK_AFTER).map((c) => c.path), ["/api/other", "/api/sessions/7/sets"]);
  assert.equal(outbox.pending(), 0);
});

test("describes queued changes in a few words", () => {
  const cases = [
    [{ method: "POST", path: "/api/sessions/{run:a}/sets" }, "A logged set"],
    [{ method: "POST", path: "/api/sessions/7/complete" }, "Finishing a workout"],
    [{ method: "POST", path: "/api/sessions", body: { status: "in_progress" } }, "Starting a workout"],
    [{ method: "POST", path: "/api/sessions", body: { status: "skipped" } }, "Skipping a workout"],
    [{ method: "POST", path: "/api/sessions", body: { status: "planned" }, workout: { title: "Legs A" } }, "Planning Legs A"],
    [{ method: "PATCH", path: "/api/sessions/7", body: { date: "2026-11-16" } }, "Moving a workout"],
    [{ method: "DELETE", path: "/api/sessions/7?only=planned" }, "Removing a workout"],
    [{ method: "PATCH", path: "/api/exercises/3/weight", body: {} }, "An exercise's weight"],
    [{ method: "POST", path: "/api/activities" }, "Logging an activity"],
    [{ method: "DELETE", path: "/api/activities/4" }, "Removing an activity"],
    [{ method: "PATCH", path: "/api/settings" }, "A setting"],
    [{ method: "PUT", path: "/api/other" }, "PUT /api/other"],
  ];
  for (const [entry, words] of cases) assert.equal(describeChange(entry), words);
});

test("after parking one change, another failing waits as for an outage until something goes through", async () => {
  const server = fakeServer([...failing(PARK_AFTER + 4), { status: 200, json: {} }, ...failing(PARK_AFTER)]);
  let n = 0;
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, id: () => `p${++n}` });

  outbox.enqueue({ method: "POST", path: "/a" });
  outbox.enqueue({ method: "POST", path: "/b" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  // /a parked; /b fails on the same flush and every one after, but waits.
  for (let i = 0; i < 3; i++) assert.equal(await outbox.flush(), false);
  assert.deepEqual(outbox.parked().map((g) => g.entries[0].path), ["/a"]);
  assert.equal(outbox.pending(), 1);
  assert.equal(await outbox.flush(), true);

  outbox.enqueue({ method: "POST", path: "/c" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  assert.deepEqual(outbox.parked().map((g) => g.entries[0].path), ["/a", "/c"]);
});

test("a parked change to a named record holds back the later changes to it", async () => {
  const server = fakeServer([...failing(PARK_AFTER), { status: 200, json: {} }]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  outbox.remember("run:a", 7);
  outbox.enqueue({ method: "PATCH", path: "/api/sessions/{run:a}", body: { status: "in_progress" } });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/sets" });
  outbox.enqueue({ method: "PATCH", path: "/api/settings" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/complete", saveAs: "complete:a" });
  await outbox.flush();

  assert.deepEqual(outbox.parked()[0].entries.map((e) => e.path), ["/api/sessions/{run:a}", "/api/sessions/{run:a}/sets", "/api/sessions/{run:a}/complete"]);
  assert.equal(outbox.isParked("complete:a"), true);
  assert.deepEqual(server.calls.map((c) => c.path).slice(PARK_AFTER), ["/api/settings"]);
});

test("a parked set holds back nothing else of its session", async () => {
  const server = fakeServer([...failing(PARK_AFTER), { status: 200, json: {} }]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  outbox.remember("run:a", 7);
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/sets" });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/complete" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  assert.equal(outbox.parked()[0].entries.length, 1);
  assert.equal(outbox.pending(), 0);
});

test("a retry waits for a flush under way, so nothing in flight is sent twice", async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const server = fakeServer([...failing(PARK_AFTER), { status: 200, json: {} }, { status: 200, json: {} }]);
  const fetch = async (path, options) => {
    if (path === "/slow") { await gate; return server.fetch("/slow", options); }
    return server.fetch(path, options);
  };
  const outbox = createOutbox({ storage: memoryStorage(), fetch, id: () => "p1" });

  outbox.enqueue({ method: "POST", path: "/a" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  outbox.enqueue({ method: "DELETE", path: "/slow" });
  const flushing = outbox.flush();
  const retried = outbox.retryParked("p1");
  release();
  await flushing;
  assert.equal(await retried, true);
  assert.deepEqual(server.calls.slice(PARK_AFTER).map((c) => c.path), ["/slow", "/a"]);
});

test("a proxy's 502, 503 or 504 never counts, even with the app reachable", async () => {
  for (const status of [502, 503, 504]) {
    const server = fakeServer(Array.from({ length: PARK_AFTER + 1 }, () => ({ status, html: true })));
    const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

    outbox.enqueue({ method: "POST", path: "/a" });
    for (let i = 0; i <= PARK_AFTER; i++) assert.equal(await outbox.flush(), false);
    assert.deepEqual(outbox.parked(), [], `status ${status}`);
    assert.equal(outbox.waiting(), "server");
  }
});

test("only the app's own server_error counts: not its 503 for a locked database, nor a 500 page from elsewhere", async () => {
  const unavailable = { status: 503, json: { error: { code: "unavailable", message: "The database is busy" } } };
  const server = fakeServer([
    ...Array(PARK_AFTER).fill(unavailable), ...Array(PARK_AFTER).fill({ status: 500, html: true }),
  ]);
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  outbox.enqueue({ method: "POST", path: "/a" });
  for (let i = 0; i < 2 * PARK_AFTER; i++) assert.equal(await outbox.flush(), false);
  assert.deepEqual(outbox.parked(), []);
  assert.equal(outbox.pending(), 1);
});

test("strikes more than an hour apart start the count again", async () => {
  let clock = Date.parse("2026-11-15T10:00:00Z");
  const server = fakeServer(failing(2 * PARK_AFTER - 1));
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, now: () => new Date(clock).toISOString() });

  outbox.enqueue({ method: "POST", path: "/a" });
  for (let i = 1; i < PARK_AFTER; i++) await outbox.flush();
  clock += 61 * 60 * 1000;
  // The first strike of a new count, not the last of the old one.
  for (let i = 1; i < PARK_AFTER; i++) await outbox.flush();
  assert.deepEqual(outbox.parked(), []);
  // Within the hour of the last strike, the next one parks it.
  clock += 59 * 60 * 1000;
  await outbox.flush();
  assert.equal(outbox.parked().length, 1);
});

test("strikes each within the hour of the last park a change, however long they take in all", async () => {
  let clock = Date.parse("2026-11-15T10:00:00Z");
  const server = fakeServer(failing(PARK_AFTER));
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, now: () => new Date(clock).toISOString() });

  outbox.enqueue({ method: "POST", path: "/a" });
  for (let i = 0; i < PARK_AFTER; i++) {
    await outbox.flush();
    clock += 40 * 60 * 1000;
  }
  assert.equal(outbox.parked().length, 1);
});

test("a strike kept without a time, or from a clock set back, starts the count again", async () => {
  const storage = memoryStorage();
  const entry = { method: "POST", path: "/a" };
  let clock = Date.parse("2026-11-15T10:00:00Z");
  const now = () => new Date(clock).toISOString();
  storage.setItem("outbox", JSON.stringify({ queue: [entry], strikes: { entry, count: PARK_AFTER - 1 } }));
  const server = fakeServer(failing(PARK_AFTER));
  const outbox = createOutbox({ storage, fetch: server.fetch, now });

  await outbox.flush();
  assert.deepEqual(outbox.parked(), []);
  clock -= 10 * 60 * 1000;
  await outbox.flush();
  assert.deepEqual(outbox.parked(), []);
  assert.equal(JSON.parse(storage.getItem("outbox")).strikes.count, 1);
});

test("someone else's queued change is dropped, never taken into a parked group", async () => {
  const server = fakeServer(failing(PARK_AFTER));
  let signedIn = 1;
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch, user: () => signedIn, id: () => "p1" });

  outbox.enqueue({ method: "POST", path: "/api/sessions", saveAs: "run:a" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/sets" });
  signedIn = 2;
  assert.equal(await outbox.flush(), true);

  assert.deepEqual(outbox.parked()[0].entries.map((e) => e.path), ["/api/sessions"]);
  assert.equal(outbox.pending(), 0);
  assert.equal(server.calls.length, PARK_AFTER);
});

test("counts the parked changes with those that build on them", async () => {
  const server = fakeServer(failing(PARK_AFTER));
  const outbox = createOutbox({ storage: memoryStorage(), fetch: server.fetch });

  assert.equal(outbox.parkedCount(), 0);
  outbox.enqueue({ method: "POST", path: "/api/sessions", saveAs: "run:a" });
  outbox.enqueue({ method: "POST", path: "/api/sessions/{run:a}/sets" });
  for (let i = 0; i < PARK_AFTER; i++) await outbox.flush();
  assert.equal(outbox.parkedCount(), 2);
});
