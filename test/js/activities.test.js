import { test } from "node:test";
import assert from "node:assert/strict";
import {
  normalSport, sportFamily, sportIcon, sportLabel, activityTitle, activityChipLabel, KNOWN_SPORTS,
  formatDistance, formatClimb, formatDuration, activityFacts, distanceInMetres, climbInMetres, durationInSeconds,
  activityPath, logRequest, changeRequest, deleteRequest, withQueuedActivities, inOrder, byDay,
  rpeToAsk, readAsked, rememberAsked,
  preferredDistanceUnit, setPreferredDistanceUnit, distanceUnitRequest, adoptServerDistanceUnit, activityOrigin, sourceLabel,
} from "../../public/js/activities.js";

function memoryStorage(initial = {}) {
  const items = new Map(Object.entries(initial));
  return { getItem: (k) => items.get(k) ?? null, setItem: (k, v) => items.set(k, v) };
}

const imported = (fields = {}) => ({
  id: 1, date: "2026-11-01", started_at: "2026-11-01T07:00:00Z", sport: "run", title: null, moving_seconds: 1800, elapsed_seconds: 1900,
  distance_m: 5000, climb_m: 40, avg_hr: 150, max_hr: 170, rpe: null, note: null, source: "garmin", external_id: "1",
  client_ref: null, created_by: "manual", created_at: "2026-11-01T09:00:00Z", updated_at: "2026-11-01T09:00:00Z", ...fields,
});

test("gives each known sport its icon, whatever words the source used", () => {
  assert.equal(sportFamily("run"), "run");
  assert.equal(sportFamily("Trail Running"), "run");
  assert.equal(sportFamily("trail_running"), "run");
  assert.equal(sportFamily("TrailRun"), "run");
  assert.equal(sportFamily("MOUNTAIN BIKE"), "ride");
  assert.equal(sportFamily("e-bike"), "ride");
  assert.equal(sportFamily("bouldering"), "climb");
  assert.equal(sportFamily("snowboard"), "ski");
  assert.equal(sportFamily("kayak"), "activity");
  assert.equal(sportFamily(null), "activity");
  assert.equal(sportIcon("swim"), "sport-swim");
  assert.deepEqual(KNOWN_SPORTS, ["run", "ride", "hike", "walk", "ski", "swim", "climb", "yoga", "strength"]);
});

test("names an activity by its title, else its sport", () => {
  assert.equal(normalSport("  Trail   Run "), "trail run");
  assert.equal(normalSport("TrailRun"), "trail run");
  assert.equal(normalSport("mountain_bike"), "mountain bike");
  assert.equal(sportLabel("trail run"), "Trail run");
  assert.equal(sportLabel("trail_running"), "Trail running");
  assert.equal(sportLabel(""), "Activity");
  assert.equal(activityTitle(imported()), "Run");
  assert.equal(activityTitle(imported({ title: "Lunch loop" })), "Lunch loop");
});

test("labels a month chip with the sport in a word and what was done", () => {
  assert.equal(activityChipLabel(imported({ title: "Lunch loop", distance_m: 9400 }), "km"), "Run 9.4 km");
  assert.equal(activityChipLabel(imported({ sport: "trail running", distance_m: 1609.344 }), "mi"), "Run 1.0 mi");
  assert.equal(activityChipLabel(imported({ sport: "hiking", distance_m: null, moving_seconds: 11400 }), "km"), "Hike 3 h 10");
  assert.equal(activityChipLabel(imported({ sport: "pilates", distance_m: null, moving_seconds: 3000 }), "km"), "Pilates 50 min");
  assert.equal(activityChipLabel(imported({ sport: "pickleball", distance_m: null, moving_seconds: null, elapsed_seconds: 3600 }), "km"), "Pickleball 1 h 00");
  assert.equal(activityChipLabel(imported({ sport: "pickleball", distance_m: null, moving_seconds: null, elapsed_seconds: null }), "km"), "Pickleball");
});

test("shows distances in km or mi, and climb in m or ft with them", () => {
  assert.equal(formatDistance(5234, "km"), "5.2 km");
  assert.equal(formatDistance(5234, "mi"), "3.3 mi");
  assert.equal(formatDistance(200000, "mi"), "124 mi");
  assert.equal(formatDistance(null, "km"), "");
  assert.equal(formatClimb(40, "km"), "40 m");
  assert.equal(formatClimb(40, "mi"), "131 ft");
});

test("shows times in minutes, hours and minutes, or seconds", () => {
  assert.equal(formatDuration(45), "45 s");
  assert.equal(formatDuration(1800), "30 min");
  assert.equal(formatDuration(3900), "1 h 05");
  assert.equal(formatDuration(null), "");
});

test("sums an activity up as distance, time and climb, leaving out what wasn't sent", () => {
  assert.deepEqual(activityFacts(imported(), "km"), ["5.0 km", "30 min", "40 m climb"]);
  assert.deepEqual(activityFacts(imported({ distance_m: null, moving_seconds: null, climb_m: 0 }), "km"), ["32 min"]);
});

test("reads what is typed in the shown units as metres and seconds", () => {
  assert.equal(distanceInMetres("5.2", "km"), 5200);
  assert.equal(distanceInMetres("3,1", "mi"), 4989);
  assert.equal(distanceInMetres("", "km"), null);
  assert.ok(Number.isNaN(distanceInMetres("far", "km")));
  assert.equal(climbInMetres("131", "mi"), 40);
  assert.equal(climbInMetres("40", "km"), 40);
  assert.equal(durationInSeconds("45"), 2700);
  assert.equal(durationInSeconds("25:13"), 1513);
  assert.equal(durationInSeconds("1:05:30"), 3930);
  assert.equal(durationInSeconds(" "), null);
  assert.ok(Number.isNaN(durationInSeconds("1:75")));
  assert.ok(Number.isNaN(durationInSeconds("an hour")));
});

test("logs an activity under a name later changes can use, leaving blanks out", () => {
  const request = logRequest({ id: "u1", today: "2026-11-02", date: "2026-11-01", sport: " Run ", title: "", distance_m: 5000, rpe: null });

  assert.deepEqual(request, {
    method: "POST", path: "/api/activities", saveAs: "activity:u1",
    body: { client_ref: "activity:u1", today: "2026-11-02", date: "2026-11-01", sport: "Run", distance_m: 5000 },
  });
  const pending = { id: null, client_ref: "activity:u1" };
  assert.equal(activityPath(pending), "/api/activities/{activity:u1}");
  assert.deepEqual(changeRequest(pending, { rpe: 5 }, "2026-11-02"), { method: "PATCH", path: "/api/activities/{activity:u1}", body: { rpe: 5, today: "2026-11-02" } });
  assert.deepEqual(deleteRequest(imported()), { method: "DELETE", path: "/api/activities/1" });
});

test("shows queued logs, changes and deletions on top of the server's activities", () => {
  const server = [imported(), imported({ id: 2, date: "2026-10-31", sport: "ride" })];
  const log = logRequest({ id: "u1", today: "2026-11-02", date: "2026-11-01", sport: "Walk", moving_seconds: 600 });
  const queue = [
    log,
    changeRequest({ client_ref: "activity:u1" }, { rpe: 3 }, "2026-11-02"),
    changeRequest(server[0], { rpe: 6, note: "windy" }, "2026-11-02"),
    deleteRequest(server[1]),
    { method: "PATCH", path: "/api/sessions/4", body: { date: "2026-11-01" } },
  ];

  const shown = withQueuedActivities(server, queue);

  assert.deepEqual(shown.map((a) => [a.id, a.sport, a.rpe, a.pending ?? false]), [[1, "run", 6, true], [null, "walk", 3, true]]);
  assert.equal(shown[0].note, "windy");
  assert.equal(shown[1].moving_seconds, 600);
  assert.equal(server[0].rpe, null, "the server's copy is left alone");
});

test("shows a queued log once the server has it only once", () => {
  const log = logRequest({ id: "u1", today: "2026-11-02", date: "2026-11-01", sport: "walk" });
  const saved = imported({ id: 9, client_ref: "activity:u1", source: null });

  assert.deepEqual(withQueuedActivities([saved], [log]).map((a) => a.id), [9]);
});

test("orders a day by start, as the server does", () => {
  const late = imported({ id: 1, started_at: "2026-11-01T18:00:00Z" });
  const early = imported({ id: 2, started_at: null, created_at: "2026-11-01T06:00:00Z" });
  const yesterday = imported({ id: 3, date: "2026-10-31" });
  const pending = imported({ id: null, started_at: null, created_at: undefined });

  assert.deepEqual(inOrder([pending, late, early, yesterday]).map((a) => a.id), [3, 2, 1, null]);
  assert.deepEqual(Object.keys(byDay([late, yesterday])), ["2026-10-31", "2026-11-01"]);
});

test("asks once how hard an activity from elsewhere was, and only while asking is on", () => {
  const storage = memoryStorage();
  const day = [imported({ id: 1, rpe: 5 }), imported({ id: 2 }), imported({ id: 3, source: null }), imported({ id: 4 })];

  assert.equal(rpeToAsk(day, { asked: readAsked(storage) }).id, 2);
  rememberAsked(storage, 2);
  assert.equal(rpeToAsk(day, { asked: readAsked(storage) }).id, 4);
  rememberAsked(storage, 4);
  assert.equal(rpeToAsk(day, { asked: readAsked(storage) }), null);
  assert.equal(rpeToAsk([imported({ id: 8 })], { enabled: false }), null);
  assert.equal(rpeToAsk([imported({ id: 9, source: null, created_by: "llm" })]).id, 9);
  assert.equal(rpeToAsk([imported({ id: null, pending: true })]), null);
});

test("remembers at most 50 activities asked about, and survives broken storage", () => {
  const storage = memoryStorage();
  for (let id = 1; id <= 60; id += 1) rememberAsked(storage, id);

  assert.equal(readAsked(storage).length, 50);
  assert.equal(readAsked(storage)[0], 11);
  assert.deepEqual(readAsked(memoryStorage({ rpeAsked: "{nope" })), []);
  assert.deepEqual(readAsked({ getItem: () => { throw new Error("SecurityError"); } }), []);
});

test("keeps the distance unit apart from the weight unit, and takes the server's", () => {
  const storage = memoryStorage({ unit: "lb" });
  assert.equal(preferredDistanceUnit(storage), "km");

  setPreferredDistanceUnit(storage, "mi");
  assert.equal(preferredDistanceUnit(storage), "mi");
  assert.equal(storage.getItem("unit"), "lb");
  assert.throws(() => setPreferredDistanceUnit(storage, "furlong"));
  assert.deepEqual(distanceUnitRequest("km"), { method: "PATCH", path: "/api/settings", body: { distance_unit: "km" } });

  assert.equal(adoptServerDistanceUnit(storage, "km", { queued: [distanceUnitRequest("mi")] }), "mi");
  assert.equal(adoptServerDistanceUnit(storage, "km", { stale: true }), "mi");
  assert.equal(adoptServerDistanceUnit(storage, "km", { queued: [{ method: "PATCH", path: "/api/settings", body: { unit: "kg" } }] }), "km");
  assert.equal(preferredDistanceUnit(storage), "km");
});

test("says where an activity came from and who copied it", () => {
  const today = "2026-11-14";
  const at = `${today}T08:00:00`;
  assert.equal(activityOrigin({ created_by: "llm", agent_name: "Claude", source: "garmin", created_at: at }, today), "From Garmin · copied by Claude, today");
  assert.equal(activityOrigin({ created_by: "llm", agent_name: null, source: null, created_at: "2026-11-02T08:00:00" }, today), "Logged by Coach agent, Nov 2");
  assert.equal(activityOrigin({ created_by: "manual", source: "strava", created_at: at }, today), "From Strava");
  assert.equal(activityOrigin({ created_by: "manual", source: null, created_at: at }, today), "Logged by you");
  assert.equal(sourceLabel("apple_health"), "Apple Health");
  assert.equal(sourceLabel("garmin connect"), "Garmin Connect");
  assert.equal(sourceLabel("iPhone"), "iPhone");
  assert.equal(sourceLabel("intervals.icu"), "Intervals.icu");
});
