require "test_helper"

describe "exercise history API" do
  include RequestHelpers

  let(:squat) { exercise("goblet-squat") }
  let(:squat_step) { step_for("cycle-1-workout-1", "goblet-squat") }

  def log(session, step, set_number, weight: nil, **attrs)
    SetLog.create(session:, step:, set_number:, weight_value: weight, weight_unit: weight && "lb", **attrs)
  end

  describe "GET /api/exercises/:id/history" do
    it "lists the sets of each session newest first, with the remembered weight" do
      first = session_on("2026-10-13")
      log(first, squat_step, 1, reps: 8, weight: 35)
      log(first, squat_step, 2, reps: 8, weight: 35)
      second = session_on("2026-10-16")
      log(second, squat_step, 2, reps: 6, weight: 40)
      log(second, squat_step, 1, reps: 8, weight: 40)
      ExerciseWeight.create(exercise: squat, value: 40, unit: "lb")

      get "/api/exercises/#{squat.id}/history"

      _(last_response.status).must_equal 200
      _(json["exercise"]).must_equal({ "id" => squat.id, "slug" => "goblet-squat", "name" => squat.name, "timed" => false, "unit" => "lb" })
      _(json["remembered"]["value"]).must_equal 40.0
      _(json["sessions"].map { it["date"] }).must_equal %w[2026-10-16 2026-10-13]
      _(json["sessions"].first["workout"]["title"]).must_equal "Workout 1"
      _(json["sessions"].first["sets"].map { [it["set_number"], it["reps"], it["weight"]["value"]] }).must_equal [[1, 8, 40.0], [2, 6, 40.0]]
    end

    it "gives every weight in the exercise's unit, whatever it was logged in" do
      log(session_on("2026-10-13"), squat_step, 1, reps: 8, weight_value: 20, weight_unit: "kg")
      ExerciseWeight.create(exercise: squat, value: 18, unit: "kg")

      get "/api/exercises/#{squat.id}/history"

      _(json["remembered"].slice("value", "unit")).must_equal({ "value" => 39.68, "unit" => "lb" })
      _(json["sessions"].first["sets"].first["weight"]).must_equal({ "value" => 44.09, "unit" => "lb" })
      _(json["sessions"].first["sets"].first["target"]["weight"]).must_equal({ "value" => 40.0, "unit" => "lb" })
    end

    it "leaves out skipped sets and sessions without a done set" do
      log(session_on("2026-10-13"), squat_step, 1, status: "skipped")
      log(session_on("2026-10-14", "in_progress"), squat_step, 1, reps: 5, status: "skipped")
      log(session_on("2026-10-15", "in_progress"), squat_step, 1, reps: 8)

      get "/api/exercises/#{squat.id}/history"

      _(json["sessions"].map { it["date"] }).must_equal %w[2026-10-15]
      _(json["sessions"].first["status"]).must_equal "in_progress"
      _(json["remembered"]).must_be_nil
    end

    it "counts a swapped set for the exercise done, not the one planned" do
      fly = exercise("reverse-fly")
      log(session_on("2026-10-15"), squat_step, 1, reps: 12, exercise: fly)

      get "/api/exercises/#{squat.id}/history"
      _(json["sessions"]).must_be_empty

      get "/api/exercises/#{fly.id}/history"
      _(json["sessions"].first["sets"].first).must_equal(
        {
          "set_number" => 1, "block_label" => "A", "side" => nil, "reps" => 12, "seconds" => nil, "weight" => nil,
          "target" => { "reps" => 8, "seconds" => nil, "weight" => { "value" => 40.0, "unit" => "lb" } }, "swapped" => true
        }
      )
    end

    it "keeps the original targets after the workout changes" do
      log(session_on("2026-10-15"), squat_step, 1, reps: 8, weight: 40)
      squat_step.update(reps: 12, weight_value: 30)

      get "/api/exercises/#{squat.id}/history"

      _(json["sessions"].first["sets"].first["target"]).must_equal({ "reps" => 8, "seconds" => nil, "weight" => { "value" => 40.0, "unit" => "lb" } })
    end

    it "keeps the sets of a step that left its workout" do
      log(session_on("2026-10-15"), squat_step, 1, reps: 8, weight: 40)
      squat_step.delete

      get "/api/exercises/#{squat.id}/history"

      _(json["sessions"].first["sets"].map { [it["block_label"], it["reps"]] }).must_equal [["A", 8]]
    end
  end

  describe "GET /api/history/exercises" do
    it "lists every logged exercise, most recently done first" do
      fly = exercise("reverse-fly")
      older = session_on("2026-10-13")
      log(older, squat_step, 1, reps: 8, weight: 35)
      log(older, squat_step, 2, reps: 8, weight: 35)
      newer = session_on("2026-10-16")
      log(newer, squat_step, 1, reps: 12, exercise: fly)
      log(newer, squat_step, 2, reps: 8, status: "skipped")

      get "/api/history/exercises"

      _(last_response.status).must_equal 200
      _(json.map { it["slug"] }).must_equal %w[reverse-fly goblet-squat]
    end

    it "lists exercises done on the same day by name" do
      session = session_on("2026-10-16")
      log(session, squat_step, 1, reps: 8)
      log(session, step_for("cycle-1-workout-1", "reverse-fly"), 1, reps: 12)

      get "/api/history/exercises"

      _(json.map { it["slug"] }).must_equal %w[goblet-squat reverse-fly]
    end

    it "describes each logged exercise" do
      older = session_on("2026-10-13")
      log(older, squat_step, 1, reps: 8, weight: 35)
      log(older, squat_step, 2, reps: 8, weight: 35)
      ExerciseWeight.create(exercise: squat, value: 35, unit: "lb")

      get "/api/history/exercises"

      _(json).must_equal [
        { "id" => squat.id, "slug" => "goblet-squat", "name" => squat.name, "last_date" => "2026-10-13",
          "sessions" => 1, "remembered" => { "value" => 35.0, "unit" => "lb" },
          "last_set" => { "reps" => 8, "seconds" => nil, "weight" => { "value" => 35.0, "unit" => "lb" } } }
      ]
    end

    it "gives the best set of the last day, heaviest first, then the most reps" do
      older = session_on("2026-10-13")
      log(older, squat_step, 1, reps: 8, weight: 45)
      newer = session_on("2026-10-16")
      log(newer, squat_step, 1, reps: 8, weight: 40)
      log(newer, squat_step, 2, reps: 10, weight: 40)
      log(newer, squat_step, 3, reps: 12, weight: 35)
      log(newer, squat_step, 4, reps: 15, weight: 50, status: "skipped")

      get "/api/history/exercises"

      _(json.first["last_set"]).must_equal({ "reps" => 10, "seconds" => nil, "weight" => { "value" => 40.0, "unit" => "lb" } })
    end

    it "is empty before anything is logged" do
      get "/api/history/exercises"

      _(json).must_equal []
    end
  end
end
