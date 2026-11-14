import { test } from "node:test";
import assert from "node:assert/strict";
import { createOutbox } from "../../public/js/outbox.js";

function memoryStorage() {
  const items = new Map();
  return { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v) };
}

function fakeServer(responses) {
  const calls = [];
  const fetch = async (path, options) => {
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
// queue yet: the server sees the entry was for another user (#205).
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
