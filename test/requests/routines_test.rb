require "test_helper"

describe "routines API" do
  include RequestHelpers

  # A Wednesday.
  before { travel_to Time.utc(2026, 11, 11, 12) }
  after { travel_back }

  let(:strength) { workout("cycle-1-workout-1") }

  def plan(**body)
    post_json "/api/routines", { sport: "run", weekdays: [3, 6], **body }
    _(last_response.status).must_equal 201
    json
  end

  def calendar(from = "2026-11-09", to = "2026-11-15", today: "2026-11-11")
    get "/api/calendar", { from:, to:, today: }
    _(last_response.status).must_equal 200
    json
  end

  def days(...) = calendar(...)["routine_days"].map { it.values_at("routine_id", "on", "state") }

  describe "POST /api/routines" do
    it "plans a weekly routine from today, its days tentative on the calendar" do
      run = plan(title: "Easy run", minutes: 40, effort: "easy")

      _(run.slice("title", "sport", "weekdays", "one_off", "starts_on", "ends_on", "minutes", "effort", "created_by"))
        .must_equal("title" => "Easy run", "sport" => "run", "weekdays" => [3, 6], "one_off" => false, "starts_on" => "2026-11-11",
          "ends_on" => nil, "minutes" => 40, "effort" => "easy", "created_by" => "manual")
      _(days).must_equal [[run["id"], "2026-11-11", "tentative"], [run["id"], "2026-11-14", "tentative"]]
      _(calendar["routines"].map { it["id"] }).must_equal [run["id"]]
    end

    it "plans a one-off as Maybe, or as Planned with confirmed" do
      maybe = plan(sport: "hike", weekdays: [], starts_on: "2026-11-14")
      planned = plan(sport: "ride", weekdays: [], starts_on: "2026-11-15", confirmed: true)

      _(maybe.values_at("one_off", "ends_on")).must_equal [true, "2026-11-14"]
      _(days).must_equal [[maybe["id"], "2026-11-14", "tentative"], [planned["id"], "2026-11-15", "confirmed"]]
    end

    it "plans a confirmed workout one-off as a session of the workout" do
      plan(sport: nil, workout_id: strength.id, weekdays: [], starts_on: "2026-11-12", confirmed: true)

      session = calendar["sessions"].first
      _(session.values_at("date", "status", "routine_date")).must_equal ["2026-11-12", "planned", "2026-11-12"]
      _(calendar["routine_days"].first.values_at("state", "session_id")).must_equal ["confirmed", session["id"]]
    end

    it "refuses a start before the sender's today, a routine of nothing, and confirming a weekly one" do
      post_json "/api/routines", sport: "run", weekdays: [3], starts_on: "2026-11-10"
      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal("starts_on" => ["must be today or later"])

      post_json "/api/routines", weekdays: [3]
      _(json["error"]["fields"]).must_equal("sport" => ["can't be blank without a workout"])

      post_json "/api/routines", sport: "run", weekdays: [3], confirmed: true
      _(last_response.status).must_equal 409
      _(Routine.count).must_equal 0
    end

    it "counts from the device's today" do
      post_json "/api/routines", sport: "run", weekdays: [3], starts_on: "2026-11-10", today: "2026-11-10"

      _(last_response.status).must_equal 201
    end

    it "refuses another user's workout as not found" do
      other = create_user("other")
      theirs = Current.set(user: other) { Workout.first!(example_slug: "cycle-1-workout-1") }
      post_json "/api/routines", workout_id: theirs.id, weekdays: [3]

      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal("workout_id" => ["is not found"])
    end
  end

  describe "the days" do
    it "are done by a run logged on them, and missed once gone by with none" do
      run = Current.set(user:) { Routine.plan!({ sport: "run", weekdays: [1, 3] }, today: Date.new(2026, 11, 9)) }
      post_json "/api/activities", date: "2026-11-11", sport: "Trail Run"
      activity = json["id"]

      _(days).must_equal [[run.id, "2026-11-09", "missed"], [run.id, "2026-11-11", "done"]]
      _(calendar["routine_days"].last["activity_id"]).must_equal activity
    end

    it "read against the device's today, within a day of the server's" do
      run = plan(weekdays: [3])

      _(days(today: "2026-11-12")).must_equal [[run["id"], "2026-11-11", "missed"]]
      _(days(today: "2026-11-20")).must_equal [[run["id"], "2026-11-11", "tentative"]]
    end

    it "are confirmed, skipped, moved and made tentative again" do
      run = plan
      path = "/api/routines/#{run["id"]}/days/2026-11-14"

      put_json path, status: "confirmed"
      _(json.values_at("on", "state", "confirmed")).must_equal ["2026-11-14", "confirmed", true]
      put_json path, status: "moved", moved_to: "2026-11-15"
      _(json.values_at("on", "state", "moved")).must_equal ["2026-11-15", "confirmed", true]
      put_json path, status: "skipped"
      _(json.values_at("on", "state")).must_equal ["2026-11-15", "skipped"]
      delete path
      _(last_response.status).must_equal 200
      _(json.values_at("on", "state")).must_equal ["2026-11-15", "tentative"]
      put_json path, status: "moved", moved_to: "2026-11-14"
      _(json.values_at("on", "state", "moved")).must_equal ["2026-11-14", "tentative", false]
    end

    it "shows a day moved into the range from outside it, and not where it left" do
      run = plan(weekdays: [1])
      put_json "/api/routines/#{run["id"]}/days/2026-11-16", status: "moved", moved_to: "2026-11-15"

      _(days).must_equal [[run["id"], "2026-11-15", "tentative"]]
      _(days("2026-11-16", "2026-11-22")).must_equal []
    end

    it "refuses a day that isn't the routine's, a move to a day gone by, and changing a done day" do
      run = plan(weekdays: [3])
      put_json "/api/routines/#{run["id"]}/days/2026-11-12", status: "confirmed"
      _(last_response.status).must_equal 404

      put_json "/api/routines/#{run["id"]}/days/2026-11-11", status: "moved", moved_to: "2026-11-10"
      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal("moved_to" => ["must be today or later"])

      put_json "/api/routines/#{run["id"]}/days/2026-11-11", status: "moved"
      _(last_response.status).must_equal 400

      put_json "/api/routines/#{run["id"]}/days/2026-11-11", status: "maybe"
      _(last_response.status).must_equal 400

      post_json "/api/activities", date: "2026-11-11", sport: "run"
      put_json "/api/routines/#{run["id"]}/days/2026-11-11", status: "skipped"
      _(last_response.status).must_equal 409
    end

    it "plan a workout routine's confirmed day as a session, which the calendar's Remove makes tentative again" do
      lift = plan(sport: nil, workout_id: strength.id, weekdays: [5])
      put_json "/api/routines/#{lift["id"]}/days/2026-11-13", status: "confirmed"
      session = json["session_id"]
      _(Session.with_pk(session).values.values_at(:status, :date)).must_equal ["planned", Date.new(2026, 11, 13)]

      delete "/api/sessions/#{session}?only=planned"
      _(days).must_equal [[lift["id"], "2026-11-13", "tentative"]]
    end

    it "take an activity linked by hand from a later day, but not from an earlier one" do
      run = plan(weekdays: [3])
      post_json "/api/activities", date: "2026-11-10", sport: "run", today: "2026-11-11", routine_id: run["id"], routine_date: "2026-11-11"
      _(last_response.status).must_equal 422
      _(json.dig("error", "fields", "routine_date").join).must_include "after the activity"
      post_json "/api/activities", date: "2026-11-12", sport: "run", today: "2026-11-12", routine_id: run["id"], routine_date: "2026-11-11"
      _(last_response.status).must_equal 201

      _(days).must_equal [[run["id"], "2026-11-11", "done"]]
      _(calendar["routine_days"].first["linked"]).must_equal true
    end

    it "refuse a hand link to another user's routine, a workout routine, or a day not the routine's" do
      other = create_user("other")
      theirs = Current.set(user: other) { Routine.plan!({ sport: "run", weekdays: [3] }) }
      lift = plan(sport: nil, workout_id: strength.id, weekdays: [3])

      post_json "/api/activities", date: "2026-11-11", sport: "run", routine_id: theirs.id, routine_date: "2026-11-11"
      _(json["error"]["fields"]).must_equal("routine_id" => ["is not found"])
      post_json "/api/activities", date: "2026-11-11", sport: "run", routine_id: lift["id"], routine_date: "2026-11-11"
      _(json["error"]["fields"]).must_equal("routine_id" => ["is a workout routine; its session fulfils it"])
      run = plan(weekdays: [3])
      post_json "/api/activities", date: "2026-11-11", sport: "run", routine_id: run["id"], routine_date: "2026-11-12"
      _(json["error"]["fields"]).must_equal("routine_date" => ["is not a day of the routine"])
    end

    it "are listed on Today for its date" do
      run = plan(weekdays: [3])
      get "/api/today", date: "2026-11-11"

      _(json["routine_days"].map { it.values_at("routine_id", "state") }).must_equal [[run["id"], "tentative"]]
      _(json["routines"].map { it["id"] }).must_equal [run["id"]]
    end
  end

  describe "PATCH /api/routines/:id" do
    it "changes a routine without days gone by in place" do
      run = plan
      patch_json "/api/routines/#{run["id"]}", weekdays: [4], title: "Tempo"

      _(json.values_at("id", "weekdays", "title")).must_equal [run["id"], [4], "Tempo"]
    end

    it "starts a new routine today when the schedule of one with days gone by changes" do
      run = Current.set(user:) { Routine.plan!({ sport: "run", weekdays: [1, 3] }, today: Date.new(2026, 11, 2)) }
      patch_json "/api/routines/#{run.id}", weekdays: [3]
      revised = json

      _(last_response.status).must_equal 200
      _(revised["id"]).wont_equal run.id
      _(revised["starts_on"]).must_equal "2026-11-11"
      _(run.refresh.ends_on).must_equal Date.new(2026, 11, 10)
      _(days).must_equal [[run.id, "2026-11-09", "missed"], [revised["id"], "2026-11-11", "tentative"]]
    end

    it "answers 404 for another user's routine" do
      other = create_user("other")
      theirs = Current.set(user: other) { Routine.plan!({ sport: "run", weekdays: [3] }) }

      patch_json "/api/routines/#{theirs.id}", title: "Mine"
      _(last_response.status).must_equal 404
      put_json "/api/routines/#{theirs.id}/days/2026-11-11", status: "confirmed"
      _(last_response.status).must_equal 404
      delete "/api/routines/#{theirs.id}"
      _(last_response.status).must_equal 404
    end
  end

  describe "DELETE /api/routines/:id" do
    it "deletes a routine without days gone by, ends one with them, and erases one ended" do
      fresh = plan
      delete "/api/routines/#{fresh["id"]}"
      _(last_response.status).must_equal 204

      old = Current.set(user:) { Routine.plan!({ sport: "run", weekdays: [1] }, today: Date.new(2026, 11, 2)) }
      delete "/api/routines/#{old.id}"
      _(last_response.status).must_equal 200
      _(json["ends_on"]).must_equal "2026-11-10"

      get "/api/routines"
      _(json["routines"]).must_equal []
      get "/api/routines", ended: true
      _(json["routines"].map { it["id"] }).must_equal [old.id]

      delete "/api/routines/#{old.id}"
      _(last_response.status).must_equal 204
      _(Routine.count).must_equal 0
    end

    it "keeps the sessions and activities that fulfilled a deleted routine, unlinked" do
      old = Current.set(user:) { Routine.plan!({ sport: "run", weekdays: [1] }, today: Date.new(2026, 11, 2)) }
      post_json "/api/activities", date: "2026-11-09", sport: "run", routine_id: old.id, routine_date: "2026-11-09"
      activity = json["id"]
      delete "/api/routines/#{old.id}"
      delete "/api/routines/#{old.id}"

      _(Activity.with_pk(activity).routine_id).must_be_nil
    end
  end
end
