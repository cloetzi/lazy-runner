# frozen_string_literal: true

require "test_helper"

describe "sessions API" do
  include RequestHelpers

  let(:workout1) { workout("cycle-1-workout-1") }
  let(:squat) { step_for("cycle-1-workout-1", "goblet-squat") }

  # Sessions are planned from today on, and these plan from October 1st.
  before { travel_to Time.utc(2026, 10, 1, 12) }
  after { travel_back }

  def create_session(**body)
    post_json "/api/sessions", { workout_id: workout1.id, date: "2026-10-19", **body }
    Session.find!(json["id"])
  end

  describe "POST /api/sessions" do
    it "plans a session and returns its player plan" do
      post_json "/api/sessions", workout_id: workout1.id, date: "2026-10-19"

      _(last_response.status).must_equal 201
      _(json["status"]).must_equal "planned"
      _(json["created_by"]).must_equal "manual"
      _(json["date"]).must_equal "2026-10-19"
      _(json["workout"]["title"]).must_equal "Workout 1"
      _(json["plan"]["items"].first["exercise"]["slug"]).must_equal "half-kneel-quad-stretch"
    end

    it "can start the session right away" do
      post_json "/api/sessions", workout_id: workout1.id, status: "in_progress"

      _(json["status"]).must_equal "in_progress"
      _(json["started_at"]).wont_be_nil
      _(json["date"]).must_equal Date.today.iso8601
    end

    it "keeps which parts the session runs, and only takes sets from them" do
      session = create_session(parts: %w[workout])
      warm_up_step = workout1.framed.first.blocks.first.steps.first

      _(json["parts"]).must_equal %w[workout]
      _(session.parts.map(&:kind)).must_equal %w[workout]

      post_json "/api/sessions/#{session.id}/sets", step_id: warm_up_step.id, set_number: 1
      _(last_response.status).must_equal 400

      patch_json "/api/sessions/#{session.id}", status: "in_progress", parts: %w[warmup workout]
      _(session.refresh.parts.map(&:kind)).must_equal %w[warmup workout]
    end

    it "changes nothing when the parts are wrong" do
      session = create_session(status: "planned")

      patch_json "/api/sessions/#{session.id}", status: "in_progress", parts: %w[nap]

      _(last_response.status).must_equal 400
      _(session.refresh.status).must_equal "planned"
    end

    it "returns the same session when a create with the same client_ref is retried" do
      post_json "/api/sessions", workout_id: workout1.id, date: "2026-10-19", status: "in_progress", client_ref: "run-1"
      _(last_response.status).must_equal 201
      first = json

      post_json "/api/sessions", workout_id: workout1.id, date: "2026-10-19", status: "in_progress", client_ref: "run-1"

      _(last_response.status).must_equal 200
      _(json["id"]).must_equal first["id"]
      _(json["client_ref"]).must_equal "run-1"
      _(json["plan"]["items"]).wont_be_empty
      _(Session.where(client_ref: "run-1").count).must_equal 1
    end

    it "finds the session a concurrent create with the same client_ref inserted" do
      existing = session_on("2026-10-19", "planned", client_ref: "run-2")
      # The lookup misses the row once, as it does when two creates overlap.
      Session.define_singleton_method(:first) do |*|
        singleton_class.remove_method(:first)
        nil
      end

      post_json "/api/sessions", workout_id: workout1.id, date: "2026-10-19", client_ref: "run-2"

      _(last_response.status).must_equal 200
      _(json["id"]).must_equal existing.id
      _(Session.count).must_equal 1
      _(Session.singleton_methods(false)).wont_include :first
    ensure
      Session.singleton_class.remove_method(:first) if Session.singleton_methods(false).include?(:first)
    end

    it "creates a session per client_ref and without one" do
      post_json "/api/sessions", workout_id: workout1.id, client_ref: "run-3"
      post_json "/api/sessions", workout_id: workout1.id, client_ref: "run-4"
      post_json "/api/sessions", workout_id: workout1.id
      post_json "/api/sessions", workout_id: workout1.id

      _(Session.count).must_equal 4
    end

    it "plans at a position on its day, with the planner's note" do
      first = create_session(date: "2026-10-05")
      post_json "/api/sessions", workout_id: workout1.id, date: "2026-10-05", position: 1, note: "Mobility first", created_by: "llm"

      _(last_response.status).must_equal 201
      _(json["position"]).must_equal 1
      _(json["note"]).must_equal "Mobility first"
      _(json["created_by"]).must_equal "llm"
      _(first.refresh.position).must_equal 2
    end

    it "plans from today on, but logs a session started on an earlier day" do
      post_json "/api/sessions", workout_id: workout1.id, date: "2026-09-30"

      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal({ "date" => ["must be today or later"] })
      _(Session.count).must_equal 0

      post_json "/api/sessions", workout_id: workout1.id, date: "2026-09-30", status: "in_progress"
      _(last_response.status).must_equal 201
    end

    it "plans from the device's today when it is a day behind the server's" do
      post_json "/api/sessions", workout_id: workout1.id, date: "2026-09-30", today: "2026-09-30"

      _(last_response.status).must_equal 201
      _(json["status"]).must_equal "planned"
    end

    it "plans on the device's today when no date is sent" do
      post_json "/api/sessions", workout_id: workout1.id, today: "2026-10-02"

      _(last_response.status).must_equal 201
      _(json["date"]).must_equal "2026-10-02"
    end

    it "starts a session at the time the device sent, never later than now" do
      post_json "/api/sessions", workout_id: workout1.id, status: "in_progress", started_at: "2026-10-01T07:15:00Z"
      _(Time.iso8601(json["started_at"])).must_equal Time.utc(2026, 10, 1, 7, 15)

      post_json "/api/sessions", workout_id: workout1.id, status: "in_progress", started_at: "2026-10-03T07:15:00Z"
      _(Time.iso8601(json["started_at"])).must_equal Time.utc(2026, 10, 1, 12)

      post_json "/api/sessions", workout_id: workout1.id, status: "in_progress", started_at: "early"
      _(last_response.status).must_equal 400
      _(json["error"]["fields"].keys).must_equal ["started_at"]
    end

    it "goes by the server's today when the device's is further off" do
      post_json "/api/sessions", workout_id: workout1.id, date: "2026-09-28", today: "2026-09-28"

      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal({ "date" => ["must be today or later"] })
    end

    it "rejects a position that is not a whole number from 1" do
      [0, -1, "2.5", "first"].each do |position|
        post_json "/api/sessions", workout_id: workout1.id, date: "2026-10-05", position: position

        _(last_response.status).must_equal 400
        _(json["error"]["fields"].keys).must_equal ["position"]
      end
    end

    it "rejects an unknown workout and a bad status" do
      post_json "/api/sessions", workout_id: 0
      _(last_response.status).must_equal 404

      post_json "/api/sessions", workout_id: workout1.id, status: "done"
      _(last_response.status).must_equal 400
    end
  end

  describe "GET /api/sessions" do
    it "lists sessions in a date range" do
      create_session(date: "2026-10-01")
      create_session(date: "2026-10-10")
      create_session(date: "2026-10-20")

      get "/api/sessions?from=2026-10-05&to=2026-10-19"

      _(last_response.status).must_equal 200
      _(json.map { it["date"] }).must_equal ["2026-10-10"]
    end

    it "says who planned each: the agent by its token's name, and when" do
      Current.set(agent_name: "Coach Claude") do
        Session.plan_all!([{ workout: workout("cycle-1-workout-1"), date: "2026-11-05" }], created_by: "llm")
      end
      create_session(date: "2026-11-06")

      get "/api/sessions?from=2026-11-05&to=2026-11-06"

      _(json.map { it.values_at("created_by", "agent_name") }).must_equal [["llm", "Coach Claude"], ["manual", nil]]
      _(json.map { it["created_at"] }).must_be :all?
    end

    it "rejects a malformed date" do
      get "/api/sessions?from=yesterday"

      _(last_response.status).must_equal 400
      _(json["error"]["fields"].keys).must_equal ["from"]
    end

    it "keeps to the statuses asked for, future dates included" do
      create_session(date: "2026-11-02")
      create_session(date: "2026-11-03", status: "skipped")
      create_session(date: "2026-11-04", status: "in_progress")

      get "/api/sessions?status=planned,in_progress&from=2026-11-01&to=2026-11-07"

      _(json.map { [it["date"], it["status"]] }).must_equal [%w[2026-11-02 planned], %w[2026-11-04 in_progress]]
    end

    it "looks 28 days back by default, and ahead for what is planned" do
      travel_to Time.utc(2026, 10, 24, 12) do
        %w[2026-09-26 2026-09-27 2026-10-24 2026-11-20 2026-11-21].each { session_on(it, "planned") }

        get "/api/sessions"
        _(json.map { it["date"] }).must_equal %w[2026-09-27 2026-10-24]

        get "/api/sessions?status=planned"
        _(json.map { it["date"] }).must_equal %w[2026-10-24 2026-11-20]

        get "/api/sessions?from=2026-10-25"
        _(json.map { it["date"] }).must_equal %w[2026-11-20 2026-11-21]
      end
    end

    it "orders each day, and reads a planned day gone by as missed" do
      second = create_session(date: "2026-10-03")
      first = create_session(date: "2026-10-03", position: 1)
      later = create_session(date: "2026-10-06")

      travel_to Time.utc(2026, 10, 5, 12) do
        get "/api/sessions?from=2026-10-01&to=2026-10-07"
        _(json.map { [it["id"], it["position"], it["status"]] })
          .must_equal [[first.id, 1, "missed"], [second.id, 2, "missed"], [later.id, 1, "planned"]]

        get "/api/sessions?from=2026-10-01&to=2026-10-07&status=missed"
        _(json.map { it["id"] }).must_equal [first.id, second.id]

        get "/api/sessions?from=2026-10-01&to=2026-10-07&status=planned"
        _(json.map { it["id"] }).must_equal [later.id]
      end
    end

    it "keeps nothing for an empty status list" do
      create_session(date: "2026-10-03")

      get "/api/sessions?from=2026-10-01&to=2026-10-07&status=,"

      _(json).must_equal []
    end

    it "rejects an unknown status and a backwards or overlong range" do
      get "/api/sessions?status=done,someday"
      _(last_response.status).must_equal 400
      _(json["error"]["message"]).must_equal "unknown status: someday"

      get "/api/sessions?from=2026-10-10&to=2026-10-01"
      _(last_response.status).must_equal 400

      get "/api/sessions?from=2026-01-01&to=2027-01-02"
      _(last_response.status).must_equal 400
    end
  end

  describe "PATCH /api/sessions/:id" do
    it "changes the status" do
      session = create_session

      patch_json "/api/sessions/#{session.id}", status: "skipped"

      _(last_response.status).must_equal 200
      _(json["status"]).must_equal "skipped"
      _(session.refresh.status).must_equal "skipped"
    end

    it "refuses an object or a list for a text field" do
      session = create_session

      patch_json "/api/sessions/#{session.id}", note: { status: "x" }

      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal({ "note" => ["is invalid"] })
      _(session.refresh.note).must_be_nil
    end

    it "only finishes a session through /complete" do
      patch_json "/api/sessions/#{create_session.id}", status: "done"

      _(last_response.status).must_equal 400
    end

    it "moves a planned session to another day and place" do
      staying, moving = Array.new(2) { create_session(date: "2026-10-03") }
      there = create_session(date: "2026-10-04")

      patch_json "/api/sessions/#{moving.id}", date: "2026-10-04", position: 1

      _(last_response.status).must_equal 200
      _(json.slice("date", "position", "status")).must_equal({ "date" => "2026-10-04", "position" => 1, "status" => "planned" })
      _(there.refresh.position).must_equal 2
      _(staying.refresh.position).must_equal 1
    end

    it "moves a missed session to today, planning it again" do
      missed = session_on("2026-09-28", "planned")

      patch_json "/api/sessions/#{missed.id}", date: "2026-10-01"

      _(json["status"]).must_equal "planned"
      _(json["date"]).must_equal "2026-10-01"
    end

    it "refuses to move a session that is no longer planned" do
      %w[in_progress done skipped].each do |status|
        session = session_on("2026-10-02", status)

        patch_json "/api/sessions/#{session.id}", date: "2026-10-03"

        _(last_response.status).must_equal 409
        _(json["error"]["message"]).must_include "only a planned session can be moved"
        _(session.refresh.date).must_equal Date.new(2026, 10, 2)
      end
    end

    it "moves only to today or later, changing nothing else when it can't" do
      session = create_session(date: "2026-10-03", note: "Easy legs")

      patch_json "/api/sessions/#{session.id}", date: "2026-09-30", note: "Moved"

      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal({ "date" => ["must be today or later"] })
      _(session.refresh.note).must_equal "Easy legs"
    end

    it "plans a skipped session again and moves it in one go" do
      session = session_on("2026-10-02", "skipped")

      patch_json "/api/sessions/#{session.id}", status: "planned", date: "2026-10-04"

      _(last_response.status).must_equal 200
      _(json.slice("status", "date")).must_equal({ "status" => "planned", "date" => "2026-10-04" })
    end

    it "changes the note alone, and clears it when blank" do
      session = create_session(note: "Easy legs")

      patch_json "/api/sessions/#{session.id}", note: "Long run tomorrow"
      _(json["note"]).must_equal "Long run tomorrow"
      _(json["status"]).must_equal "planned"

      patch_json "/api/sessions/#{session.id}", note: ""
      _(session.refresh.note).must_be_nil
    end

    it "takes a done session's own date sent back as no move" do
      session = session_on("2026-09-20", "done")

      patch_json "/api/sessions/#{session.id}", date: "2026-09-20", position: session.position, note: "Felt strong"

      _(last_response.status).must_equal 200
      _(session.refresh.note).must_equal "Felt strong"

      patch_json "/api/sessions/#{session.id}", date: "2026-09-21"
      _(last_response.status).must_equal 409
    end

    it "makes a session planned again only on a day from today on" do
      skipped = session_on("2026-09-24", "skipped")

      patch_json "/api/sessions/#{skipped.id}", status: "planned"

      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal({ "date" => ["must be today or later"] })
      _(skipped.refresh.status).must_equal "skipped"

      coming = session_on("2026-10-02", "skipped")
      patch_json "/api/sessions/#{coming.id}", status: "planned"
      _(last_response.status).must_equal 200
    end

    it "makes a past session planned again and moves it in one go" do
      skipped = session_on("2026-09-24", "skipped")

      patch_json "/api/sessions/#{skipped.id}", status: "planned", date: "2026-10-02"

      _(last_response.status).must_equal 200
      _(json["status"]).must_equal "planned"
      _(skipped.refresh.date).must_equal Date.new(2026, 10, 2)
    end

    it "refuses a start time that is no time, even for a session already started" do
      session = create_session(status: "in_progress")

      patch_json "/api/sessions/#{session.id}", status: "in_progress", started_at: "garbage"

      _(last_response.status).must_equal 400
    end

    it "forgets the start of a session planned again" do
      session = create_session(status: "in_progress")

      patch_json "/api/sessions/#{session.id}", status: "planned"

      _(json["started_at"]).must_be_nil
    end

    it "moves a missed session to the device's today, a day behind the server's" do
      missed = session_on("2026-09-28", "planned")

      patch_json "/api/sessions/#{missed.id}", date: "2026-09-30", today: "2026-09-30"

      _(last_response.status).must_equal 200
      _(json["status"]).must_equal "planned"
      _(missed.refresh.date).must_equal Date.new(2026, 9, 30)
    end

    it "keeps a done session done" do
      session = session_on("2026-10-01", "done")

      %w[planned in_progress skipped].each do |status|
        patch_json "/api/sessions/#{session.id}", status: status

        _(last_response.status).must_equal 422
        _(json["error"]["fields"]).must_equal({ "status" => ["can't change once the session is done"] })
      end
      patch_json "/api/sessions/#{session.id}", parts: %w[workout]
      _(last_response.status).must_equal 422

      _(session.refresh.status).must_equal "done"
      _(session.part_kinds).must_be_nil
    end

    it "picks up a session ended early, taking back its finish" do
      session = create_session
      log_all(session, "goblet-squat")
      post_json "/api/sessions/#{session.id}/complete", feedback: "too_easy", ended_early: true

      patch_json "/api/sessions/#{session.id}", status: "in_progress", parts: %w[workout cooldown]

      _(last_response.status).must_equal 200
      _(json["status"]).must_equal "in_progress"
      _(json["completion"]).must_be_nil
      _(session.refresh.parts.map(&:kind)).must_equal %w[workout cooldown]
      _(session.set_logs_dataset.count).wont_equal 0

      post_json "/api/sessions/#{session.id}/complete", feedback: "too_easy"
      _(json["session"]["status"]).must_equal "done"
      _(json["completion"]["ended_early"]).must_equal false
    end
  end

  describe "POST /api/sessions/:id/sets" do
    it "logs a set and starts a planned session" do
      session = create_session

      post_json "/api/sessions/#{session.id}/sets",
                step_id: squat.id, set_number: 1, reps: 8, weight: { value: 45, unit: "lb" }

      _(last_response.status).must_equal 201
      _(json["weight"]).must_equal({ "value" => 45.0, "unit" => "lb" })
      _(json["status"]).must_equal "done"
      _(session.refresh.status).must_equal "in_progress"
    end

    it "keeps a weight logged in the other unit in the exercise's unit" do
      session = create_session

      post_json "/api/sessions/#{session.id}/sets",
                step_id: squat.id, set_number: 1, reps: 8, weight: { value: 18, unit: "kg" }

      _(json["weight"]).must_equal({ "value" => 40.0, "unit" => "lb" })
      _(SetLog.find!(json["id"]).weight).must_equal({ value: 40.0, unit: "lb" })
    end

    it "keeps a set in the unit of the gear its step is done with, and shows it so" do
      inventory("kettlebell").update(unit: "kg", weights: [16, 24])
      deadlift = step_for("cycle-1-workout-1", "straight-leg-deadlift")
      deadlift.update(weight_value: 16, weight_unit: "kg")
      session = create_session

      post_json "/api/sessions/#{session.id}/sets", step_id: deadlift.id, set_number: 1, reps: 8, weight: { value: 16, unit: "kg" }

      _(json["weight"]).must_equal({ "value" => 16.0, "unit" => "kg" })
      _(json["target"]["weight"]).must_equal({ "value" => 16.0, "unit" => "kg" })
      get "/api/sessions/#{session.id}"
      sets = json["exercises"].find { it["exercise"]["slug"] == "straight-leg-deadlift" }["sets"]
      _(sets.first["weight"]).must_equal({ "value" => 16.0, "unit" => "kg" })
    end

    it "updates the same set when it is logged again" do
      session = create_session
      statuses = Array.new(2) do |i|
        post_json "/api/sessions/#{session.id}/sets", step_id: squat.id, set_number: 1, reps: 6 + i
        last_response.status
      end

      _(statuses).must_equal [201, 200]
      _(session.set_logs_dataset.count).must_equal 1
      _(session.set_logs.first.reps).must_equal 7
    end

    it "updates a set another request inserted between its lookup and its insert" do
      session = create_session
      SetLog.create(session:, step: squat, set_number: 1, reps: 6)
      # The lookup misses the row once, as it does when two posts of the same
      # set overlap.
      SetLog.define_singleton_method(:find_or_new) do |values|
        singleton_class.remove_method(:find_or_new)
        new(values)
      end

      post_json "/api/sessions/#{session.id}/sets", step_id: squat.id, set_number: 1, reps: 8

      _(last_response.status).must_equal 200
      _(session.set_logs_dataset.count).must_equal 1
      _(session.set_logs.first.reps).must_equal 8
    ensure
      SetLog.singleton_class.remove_method(:find_or_new) if SetLog.singleton_methods(false).include?(:find_or_new)
    end

    it "keeps the sides of a per-side step apart" do
      session = create_session
      step = step_for("cycle-1-workout-1", "single-leg-deadlift")
      %w[left right].each { post_json "/api/sessions/#{session.id}/sets", step_id: step.id, set_number: 1, side: it, reps: 10 }

      _(session.set_logs_dataset.select_map(:side).sort).must_equal %w[left right]
    end

    it "logs warm-up steps against the session" do
      session = create_session
      post_json "/api/sessions/#{session.id}/sets", step_id: step_for("cycle-1-warmup", "side-plank").id, set_number: 1, side: "left",
                                                    status: "skipped"

      _(last_response.status).must_equal 201
      _(json["status"]).must_equal "skipped"
      _(json["part"]).must_equal "warmup"
    end

    it "keeps the part each set was in: the session's own workout is the main one" do
      session = create_session
      post_json "/api/sessions/#{session.id}/sets", step_id: squat.id, set_number: 1, reps: 8
      _(json["part"]).must_equal "workout"

      stretch = Workout.first!(example_slug: "cycle-1-cooldown")
      on_its_own = Session.add!(workout: stretch, date: Date.today, status: "in_progress", started_at: Time.now)
      post_json "/api/sessions/#{on_its_own.id}/sets", step_id: stretch.blocks.first.steps.first.id, set_number: 1, seconds: 30
      _(json["part"]).must_equal "workout"
    end

    it "logs a swapped set against the exercise done" do
      session = create_session
      fly = exercise("reverse-fly")

      post_json "/api/sessions/#{session.id}/sets", step_id: squat.id, set_number: 1, reps: 12, exercise_id: fly.id

      _(last_response.status).must_equal 201
      _(json["exercise_id"]).must_equal fly.id
      _(json["planned_exercise_id"]).must_equal squat.exercise_id
      _(json["step_id"]).must_equal squat.id
    end

    it "keeps the target shown when the set was first logged" do
      session = create_session
      squat.update(reps: 6)
      ExerciseWeight.create(exercise: squat.exercise, value: 45, unit: "lb")

      post_json "/api/sessions/#{session.id}/sets", step_id: squat.id, set_number: 1, reps: 6, weight: { value: 45, unit: "lb" }

      _(json["block_label"]).must_equal "A"
      _(json["exercise_id"]).must_equal squat.exercise_id
      _(json["target"]).must_equal({ "reps" => 6, "seconds" => nil, "weight" => { "value" => 45.0, "unit" => "lb" } })

      squat.update(reps: 8)
      ExerciseWeight.first!(exercise: squat.exercise).update(value: 50)
      post_json "/api/sessions/#{session.id}/sets", step_id: squat.id, set_number: 1, reps: 7, weight: { value: 45, unit: "lb" }

      _(json["reps"]).must_equal 7
      _(json["target"]["reps"]).must_equal 6
      _(json["target"]["weight"]["value"]).must_equal 45.0
    end

    it "goes back to the step's exercise when the set is logged again without a swap" do
      session = create_session
      post_json "/api/sessions/#{session.id}/sets", step_id: squat.id, set_number: 1, exercise_id: exercise("reverse-fly").id
      post_json "/api/sessions/#{session.id}/sets", step_id: squat.id, set_number: 1, exercise_id: squat.exercise_id

      _(json["exercise_id"]).must_equal squat.exercise_id
      _(session.set_logs.first.swapped?).must_equal false
      _(session.set_logs_dataset.count).must_equal 1
    end

    it "rejects a swap to an unknown exercise" do
      post_json "/api/sessions/#{create_session.id}/sets", step_id: squat.id, set_number: 1, exercise_id: 0

      _(last_response.status).must_equal 404
    end

    describe "for a step the session no longer runs" do
      let(:own) do
        steps = [{ exercise: "goblet-squat", reps: 8 }, { exercise: "plank", duration_seconds: 30 }]
        Workout.create_with!({ kind: "workout", title: "Legs", blocks: [{ label: "Strength", rounds: 2, steps: }] })
      end
      let(:session) { Session.add!(workout: own, date: Date.today, status: "in_progress", started_at: Time.now) }
      let(:gone) { own.blocks.first.steps.first }
      let(:shown) do
        { planned_exercise_id: gone.exercise_id, block_label: "Strength", target: { reps: 8, weight: { value: 40, unit: "lb" } } }
      end

      it "keeps a set whose step was deleted, from what the player showed" do
        step_id = gone.id
        Step.remove!([step_id])

        post_json "/api/sessions/#{session.id}/sets", step_id:, set_number: 1, reps: 8, weight: { value: 40, unit: "lb" }, **shown

        _(last_response.status).must_equal 201
        _(json["step_id"]).must_be_nil
        _(json["step_ref"]).must_equal step_id
        _(json["planned_exercise_id"]).must_equal exercise("goblet-squat").id
        _(json["block_label"]).must_equal "Strength"
        _(json["part"]).must_be_nil
        _(json["target"]).must_equal({ "reps" => 8, "seconds" => nil, "weight" => { "value" => 40.0, "unit" => "lb" } })

        post_json "/api/sessions/#{session.id}/sets", step_id:, set_number: 1, reps: 7, **shown
        _(last_response.status).must_equal 200
        _(session.set_logs_dataset.select_map(:reps)).must_equal [7]
      end

      it "keeps a set logged before its step was deleted when it is logged again" do
        post_json "/api/sessions/#{session.id}/sets", step_id: gone.id, set_number: 1, reps: 8, **shown
        Step.remove!([gone.id])

        post_json "/api/sessions/#{session.id}/sets", step_id: gone.id, set_number: 1, reps: 6, **shown

        _(last_response.status).must_equal 200
        _(session.set_logs_dataset.select_map(%i[reps step_id])).must_equal [[6, nil]]
      end

      it "keeps a swapped set, naming the exercise done and the one planned" do
        Step.remove!([gone.id])

        post_json "/api/sessions/#{session.id}/sets", step_id: gone.id, set_number: 1, reps: 10, exercise_id: exercise("reverse-fly").id,
                                                      **shown

        _(json["exercise_id"]).must_equal exercise("reverse-fly").id
        _(json["planned_exercise_id"]).must_equal gone.exercise_id
      end

      it "keeps a set of a part the session has left out since, without the link" do
        warm_up = workout1.framed.first.blocks.first.steps.first
        planned = create_session(parts: %w[workout])

        post_json "/api/sessions/#{planned.id}/sets", step_id: warm_up.id, set_number: 1, seconds: 30, target: { seconds: 30 },
                                                      planned_exercise_id: warm_up.exercise_id, block_label: warm_up.block.label

        _(last_response.status).must_equal 201
        _(json["step_id"]).must_be_nil
        _(json["step_ref"]).must_equal warm_up.id
        _(json["block_label"]).must_equal warm_up.block.label
        _(json["part"]).must_equal "warmup"
      end

      it "takes the part the player sent for a step that has gone, and refuses an unknown one" do
        Step.remove!([gone.id])

        post_json "/api/sessions/#{session.id}/sets", step_id: gone.id, set_number: 1, reps: 8, part: "cooldown", **shown
        _(json["part"]).must_equal "cooldown"

        post_json "/api/sessions/#{session.id}/sets", step_id: gone.id, set_number: 2, reps: 8, part: "stretch", **shown
        _(last_response.status).must_equal 422
        _(json["error"]["fields"].keys).must_equal ["part"]
      end

      it "keeps a set whose target weight has no known unit, without the weight" do
        Step.remove!([gone.id])

        [{ value: 20 }, { value: 20, unit: "lbs" }, 20].each.with_index(1) do |weight, set_number|
          post_json "/api/sessions/#{session.id}/sets", step_id: gone.id, set_number:, reps: 8, **shown, target: { reps: 8, weight: }

          _(last_response.status).must_equal 201
          _(json["target"]).must_equal({ "reps" => 8, "seconds" => nil, "weight" => nil })
        end
      end

      it "refuses a set for a deleted step that doesn't say what was planned" do
        Step.remove!([gone.id])

        post_json "/api/sessions/#{session.id}/sets", step_id: gone.id, set_number: 1, reps: 8

        _(last_response.status).must_equal 404
        _(session.set_logs_dataset.count).must_equal 0
      end
    end

    it "rejects a step from another workout, even with what the player showed" do
      session = create_session
      push_up = step_for("cycle-1-workout-2", "push-up")
      post_json "/api/sessions/#{session.id}/sets", step_id: push_up.id, set_number: 1

      _(last_response.status).must_equal 400

      post_json "/api/sessions/#{session.id}/sets", step_id: push_up.id, set_number: 1, planned_exercise_id: push_up.exercise_id,
                                                    block_label: "A"
      _(last_response.status).must_equal 400
    end

    it "rejects an invalid set" do
      post_json "/api/sessions/#{create_session.id}/sets", step_id: squat.id, set_number: 0

      _(last_response.status).must_equal 422
      _(json["error"]["message"]).must_include "Set number"
    end
  end

  describe "POST /api/sessions/:id/complete" do
    it "keeps the finish time the device sent, the first one on a retry" do
      session = create_session

      post_json "/api/sessions/#{session.id}/complete", finished_at: "2026-10-01T09:00:00Z"
      _(Time.iso8601(json["completion"]["finished_at"])).must_equal Time.utc(2026, 10, 1, 9)

      post_json "/api/sessions/#{session.id}/complete", finished_at: "2026-10-01T10:00:00Z"
      _(Time.iso8601(json["completion"]["finished_at"])).must_equal Time.utc(2026, 10, 1, 9)

      post_json "/api/sessions/#{create_session.id}/complete", finished_at: "soon"
      _(last_response.status).must_equal 400
    end

    it "never puts the finish before the start" do
      session = create_session(status: "in_progress")

      post_json "/api/sessions/#{session.id}/complete", finished_at: "2026-10-01T06:00:00Z"

      _(Time.iso8601(json["completion"]["finished_at"])).must_equal session.started_at
    end

    it "finishes the session with feedback" do
      session = create_session

      post_json "/api/sessions/#{session.id}/complete", rpe: 7, feedback: "right", note: "Felt good"

      _(last_response.status).must_equal 200
      _(json["session"]["status"]).must_equal "done"
      _(json["completion"]["rpe"]).must_equal 7
      _(json["completion"]["feedback"]).must_equal "right"
      _(json["completion"]["finished_at"]).wont_be_nil
      _(json["completion"]["ended_early"]).must_equal false
      _(json.keys).wont_include "suggestions"
    end

    it "keeps a session ended early, marked as such" do
      session = create_session

      post_json "/api/sessions/#{session.id}/complete", feedback: "right", ended_early: true

      _(json["session"]["status"]).must_equal "done"
      _(json["completion"]["ended_early"]).must_equal true
      _(session.refresh.completion.ended_early).must_equal true
    end

    it "reads ended_early sent as text" do
      session = create_session

      post_json "/api/sessions/#{session.id}/complete", feedback: "right", ended_early: "off"

      _(json["completion"]["ended_early"]).must_equal false
    end

    it "changes no weight, whatever the feedback: that is the user's and the coach's" do
      inventory("kettlebell").update(weights: [40, 53])
      ExerciseWeight.create(exercise: exercise("goblet-squat"), value: 40, unit: "lb")
      session = create_session
      log_all(session, "goblet-squat")

      post_json "/api/sessions/#{session.id}/complete", feedback: "too_easy"

      _(json["completion"]["feedback"]).must_equal "too_easy"
      _(ExerciseWeight.first!(exercise_id: squat.exercise_id).value).must_equal 40

      get "/api/workouts/#{workout1.id}"
      step = json["blocks"].flat_map { it["steps"] }.find { it["id"] == squat.id }
      _(step["target"]["weight"]).must_equal({ "value" => 40.0, "unit" => "lb" })
      _(step.keys).wont_include "suggestion"
    end

    it "steps and targets in kg for gear listed in kg" do
      patch_json "/api/equipment/#{equipment("dumbbell").id}", unit: "kg", weights: [4, 8]
      patch_json "/api/equipment/#{equipment("kettlebell").id}", unit: "kg", weights: [16, 24]

      get "/api/workouts/#{workout1.id}"
      step = json["blocks"].flat_map { it["steps"] }.find { it["id"] == squat.id }
      _(step["allowed_weights"]).must_equal [4.0, 8.0, 16.0, 24.0]
      _(step["target"]["weight"]["unit"]).must_equal "kg"
    end

    it "leaves the session unfinished when it cannot be marked done" do
      session = create_session
      # Session has no update of its own, so removing the stub restores Sequel's.
      _(Session.instance_methods(false)).wont_include :update
      original = Session.instance_method(:update)
      Session.define_method(:update) { |values| id == session.id && values[:status] == "done" ? raise(Sequel::ConstraintViolation, "boom") : original.bind_call(self, values) }
      begin
        post_json "/api/sessions/#{session.id}/complete", feedback: "right"
      rescue Sequel::ConstraintViolation
        nil
      ensure
        Session.remove_method(:update)
      end

      _(session.refresh.status).wont_equal "done"
      _(Completion.where(session:)).must_be_empty
    end

    it "keeps what a second call leaves out" do
      session = create_session
      post_json "/api/sessions/#{session.id}/complete", rpe: 7, feedback: "right", ended_early: true
      finished_at = json["completion"]["finished_at"]

      post_json "/api/sessions/#{session.id}/complete", note: "Knee felt fine"

      _(last_response.status).must_equal 200
      _(json["completion"].slice("rpe", "feedback", "note", "ended_early", "finished_at")).must_equal(
        { "rpe" => 7, "feedback" => "right", "note" => "Knee felt fine", "ended_early" => true, "finished_at" => finished_at }
      )
    end

    it "clears a field sent as null" do
      session = create_session
      post_json "/api/sessions/#{session.id}/complete", rpe: 7, feedback: "right"

      post_json "/api/sessions/#{session.id}/complete", rpe: nil

      _(session.refresh.completion.values.slice(:rpe, :feedback)).must_equal({ rpe: nil, feedback: "right" })
    end

    it "rejects feedback it does not know" do
      post_json "/api/sessions/#{create_session.id}/complete", feedback: "meh", rpe: 11

      _(last_response.status).must_equal 422
    end
  end

  describe "PATCH /api/sessions/:id/completion" do
    it "adds a note later and keeps the rest" do
      session = create_session
      post_json "/api/sessions/#{session.id}/complete", rpe: 7, feedback: "too_easy"

      patch_json "/api/sessions/#{session.id}/completion", note: "Slept badly"

      _(last_response.status).must_equal 200
      _(json.slice("rpe", "feedback", "note")).must_equal({ "rpe" => 7, "feedback" => "too_easy", "note" => "Slept badly" })
      _(session.refresh.status).must_equal "done"
    end

    it "leaves the feedback to /complete" do
      session = create_session
      post_json "/api/sessions/#{session.id}/complete", feedback: "right"

      patch_json "/api/sessions/#{session.id}/completion", feedback: "too_hard"

      _(last_response.status).must_equal 400
      _(json["error"]["fields"].keys).must_equal ["feedback"]
      _(session.refresh.completion.feedback).must_equal "right"
    end

    it "is a 404 until the session is finished" do
      patch_json "/api/sessions/#{create_session.id}/completion", note: "Too soon"

      _(last_response.status).must_equal 404
      _(json["error"]["resource"]).must_equal "completion"
      _(json["error"]["message"]).must_include "is not finished yet"
    end
  end

  describe "GET /api/sessions/:id" do
    it "lists what was logged per exercise in the order it was done, with the duration" do
      session = create_session(status: "in_progress")
      session.update(started_at: Time.utc(2026, 10, 19, 7, 0))
      press = step_for("cycle-1-workout-1", "dead-bug")
      SetLog.create(session:, step: squat, set_number: 2, reps: 7, weight_value: 40, weight_unit: "lb")
      SetLog.create(session:, step: squat, set_number: 1, reps: 8, weight_value: 40, weight_unit: "lb")
      SetLog.create(session:, step: press, set_number: 1, status: "skipped")
      Completion.create(session:, finished_at: Time.utc(2026, 10, 19, 7, 26), rpe: 6, feedback: "right")
      session.update(status: "done")

      get "/api/sessions/#{session.id}"

      _(last_response.status).must_equal 200
      _(json["id"]).must_equal session.id
      _(json["workout"]["title"]).must_equal "Workout 1"
      _(json["minutes"]).must_equal 26
      _(json["completion"]["rpe"]).must_equal 6
      _(json["exercises"].map { it["exercise"]["slug"] }).must_equal %w[goblet-squat dead-bug]
      squat_sets = json["exercises"].first
      _(squat_sets["instead_of"]).must_be_nil
      _(squat_sets["block_label"]).must_equal squat.block.label
      _(squat_sets["sets"].map { [it["set_number"], it["reps"], it["weight"]["value"]] }).must_equal [[1, 8, 40.0], [2, 7, 40.0]]
      _(json["exercises"].last["sets"].map { it["status"] }).must_equal %w[skipped]
    end

    it "says which part each exercise was in, an older set whose step has gone reading as the main workout" do
      session = create_session(status: "in_progress")
      SetLog.create(session:, step: step_for("cycle-1-warmup", "side-plank"), set_number: 1, side: "left", status: "skipped")
      SetLog.create(session:, step: squat, set_number: 1, reps: 8)
      SetLog.create(session:, step_ref: 0, exercise: exercise("plank"), planned_exercise: exercise("plank"), block_label: "Old",
                    set_number: 1, seconds: 30)

      get "/api/sessions/#{session.id}"

      _(json["exercises"].map { [it["exercise"]["slug"], it["part"]] })
        .must_equal [%w[side-plank warmup], %w[goblet-squat workout], %w[plank workout]]
    end

    it "groups a swap under the exercise done and names the one planned" do
      session = create_session
      fly = exercise("reverse-fly")
      SetLog.create(session:, step: squat, set_number: 1, reps: 8, weight_value: 40, weight_unit: "lb")
      SetLog.create(session:, step: squat, set_number: 2, reps: 12, exercise: fly)

      get "/api/sessions/#{session.id}"

      _(json["minutes"]).must_be_nil
      _(json["exercises"].map { it["exercise"]["slug"] }).must_equal %w[goblet-squat reverse-fly]
      _(json["exercises"].last["instead_of"]["slug"]).must_equal "goblet-squat"
      _(json["exercises"].last["sets"].map { it["set_number"] }).must_equal [2]
    end

    it "keeps two steps of the same exercise in a block apart, each with its target" do
      steps = [{ exercise: "goblet-squat", reps: 8 }, { exercise: "goblet-squat", reps: 15 }]
      own = Workout.create_with!({ kind: "workout", title: "Squats", blocks: [{ label: "A", rounds: 2, steps: }] })
      session = Session.add!(workout: own, date: Date.today, status: "in_progress", started_at: Time.now)
      heavy, light = own.blocks.first.steps
      [1, 2].each do |round|
        post_json "/api/sessions/#{session.id}/sets", step_id: heavy.id, set_number: round, reps: 8
        post_json "/api/sessions/#{session.id}/sets", step_id: light.id, set_number: round, reps: 15
      end
      Step.remove!([light.id])

      get "/api/sessions/#{session.id}"

      _(json["exercises"].size).must_equal 2
      _(json["exercises"].map { it["sets"].map { |set| [set["set_number"], set["reps"], set["target"]["reps"]] } })
        .must_equal [[[1, 8, 8], [2, 8, 8]], [[1, 15, 15], [2, 15, 15]]]
    end

    it "gives weights in the unit of its step's gear, whatever they were logged in" do
      session = create_session
      SetLog.create(session:, step: squat, set_number: 1, reps: 8, weight_value: 20, weight_unit: "kg")

      get "/api/sessions/#{session.id}"

      _(json["exercises"].first["sets"].first["weight"]).must_equal({ "value" => 44.09, "unit" => "lb" })
    end
  end

  describe "DELETE /api/sessions/:id" do
    def squat_session(date, value)
      create_session(date:).tap { log_all(it, "goblet-squat", weight_value: value) }
    end

    def remember_squat(value) = ExerciseWeight.create(exercise: squat.exercise, value:, unit: "lb")

    it "renumbers the day it leaves" do
      first, second, third = Array.new(3) { create_session(date: "2026-10-03") }

      delete "/api/sessions/#{second.id}"

      _([first, third].map { it.refresh.position }).must_equal [1, 2]
    end

    it "deletes the session with its sets and completion" do
      session = squat_session("2026-10-19", 40)
      finish(session, "too_easy")

      delete "/api/sessions/#{session.id}"

      _(last_response.status).must_equal 204
      _(Session.where(id: session.id).empty?).must_equal true
      _(SetLog.where(session_id: session.id).count).must_equal 0
      _(Completion.where(session_id: session.id).count).must_equal 0

      get "/api/history?date=2026-10-19"
      _(json["sessions"]).must_equal []
    end

    it "puts a remembered weight back to the last one logged before" do
      squat_session("2026-10-12", 45)
      session = squat_session("2026-10-19", 50)
      remember_squat(50)

      delete "/api/sessions/#{session.id}"

      _(ExerciseWeight.first(exercise: squat.exercise).weight).must_equal({ value: 45.0, unit: "lb" })
    end

    it "falls back to the seed weight when nothing else is logged" do
      session = squat_session("2026-10-19", 50)
      remember_squat(50)

      delete "/api/sessions/#{session.id}"

      _(ExerciseWeight.first(exercise: squat.exercise).weight).must_equal squat.weight
    end

    it "keeps a remembered weight the session did not set" do
      squat_session("2026-10-12", 45)
      session = squat_session("2026-10-19", 50)
      remember_squat(55)

      delete "/api/sessions/#{session.id}"

      _(ExerciseWeight.first(exercise: squat.exercise).value).must_equal 55
    end

    it "goes by when sessions on a day finished, not by where they were planned" do
      first = squat_session("2026-10-19", 45)
      first.update(status: "in_progress", started_at: Time.now)
      finish(first, "right")
      travel 1.hour
      # Planned at the top of the day after the first was done.
      post_json "/api/sessions", workout_id: workout1.id, date: "2026-10-19", position: 1
      second = Session.find!(json["id"])
      log_all(second, "goblet-squat", weight_value: 50)
      second.update(status: "in_progress", started_at: Time.now)
      finish(second, "right")
      remember_squat(50)
      _(first.refresh.position).must_equal 2

      delete "/api/sessions/#{second.id}"

      _(ExerciseWeight.first(exercise_id: squat.exercise_id).weight).must_equal({ value: 45.0, unit: "lb" })
    end

    it "falls back to the weight of the session finished last on the day" do
      early = squat_session("2026-10-19", 45)
      Completion.create(session_id: early.id, finished_at: Time.utc(2026, 10, 19, 7))
      late = squat_session("2026-10-19", 40)
      Completion.create(session_id: late.id, finished_at: Time.utc(2026, 10, 19, 6))
      gone = squat_session("2026-10-20", 50)
      remember_squat(50)

      delete "/api/sessions/#{gone.id}"

      _(ExerciseWeight.first(exercise_id: squat.exercise_id).value).must_equal 45
    end

    it "keeps a remembered weight when a later session logged the exercise" do
      older = squat_session("2026-10-12", 50)
      squat_session("2026-10-19", 50)
      remember_squat(50)

      delete "/api/sessions/#{older.id}"

      _(ExerciseWeight.first(exercise: squat.exercise).value).must_equal 50
    end

    it "puts back a remembered weight that a swapped set set" do
      session = create_session(date: "2026-10-19")
      log_all(session, "straight-leg-deadlift", exercise: squat.exercise, weight_value: 50)
      remember_squat(50)

      delete "/api/sessions/#{session.id}"

      _(ExerciseWeight.first(exercise: squat.exercise).weight).must_equal squat.weight
    end

    it "forgets a remembered weight with nothing to go back to" do
      bug = exercise("dead-bug")
      session = create_session(date: "2026-10-19")
      log_all(session, "dead-bug", weight_value: 10, weight_unit: "lb")
      ExerciseWeight.create(exercise: bug, value: 10, unit: "lb")

      delete "/api/sessions/#{session.id}"

      _(ExerciseWeight.where(exercise: bug).empty?).must_equal true
    end

    it "deletes only a planned session when the calendar asks so" do
      planned = create_session(date: "2026-10-03")
      started = create_session(date: "2026-10-03", status: "in_progress")

      delete "/api/sessions/#{started.id}?only=planned"
      _(last_response.status).must_equal 409
      _(Session[started.id]).wont_be_nil

      delete "/api/sessions/#{planned.id}?only=planned"
      _(last_response.status).must_equal 204
      _(Session[planned.id]).must_be_nil

      delete "/api/sessions/#{started.id}?only=done"
      _(last_response.status).must_equal 400
    end

    it "returns 404 for an unknown session" do
      delete "/api/sessions/0"

      _(last_response.status).must_equal 404
    end
  end
end
