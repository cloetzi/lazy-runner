# frozen_string_literal: true

require "test_helper"

describe "GET /api/today" do
  include RequestHelpers

  describe "without a date" do
    it "takes today in the server's time zone" do
      travel_to Time.utc(2026, 10, 25, 3) do
        get "/api/today"
        _(json["date"]).must_equal "2026-10-25"

        with_time_zone("America/Vancouver") { get "/api/today" }
        _(json["date"]).must_equal "2026-10-24"
      end
    end

    it "finds the session planned for that day" do
      planned = session_on("2026-10-24", "planned", workout: "cycle-1-workout-2")

      travel_to(Time.utc(2026, 10, 25, 3)) { with_time_zone("America/Vancouver") { get "/api/today" } }

      _(json["session"]["id"]).must_equal planned.id
    end
  end

  describe "with nothing logged" do
    before { get "/api/today" }

    it "defaults to the first workout with its warm-up and cool-down" do
      _(last_response.status).must_equal 200
      _(json["source"]).must_equal "default"
      _(json["session"]).must_be_nil
      _(json["title"]).must_equal "Workout 1"
      _(json["workouts"].map { it["kind"] }).must_equal %w[warmup workout cooldown]
    end

    it "estimates the duration" do
      _(json["estimated_minutes"]).must_be :>, 20
      _(json["estimated_minutes"]).must_equal(json["workouts"].sum { it["estimated_minutes"] })
    end

    it "includes the full player plan, its equipment and the weight targets" do
      items = json["plan"]["items"]

      _(items.first["exercise"]["slug"]).must_equal "half-kneel-quad-stretch"
      _(items.last["exercise"]["slug"]).must_equal "overhead-triceps-stretch"
      _(json["plan"]["equipment"]).must_include "kettlebell"
      _(json["plan"]["targets"].map { it["exercise"]["name"] }).must_include "Goblet squat"
    end

    it "includes the stepper increments" do
      _(json["weight_steps"]["dumbbell"]["lb"].last).must_equal({ "step" => 5 })
    end
  end

  it "moves on to the next workout once one is done" do
    get "/api/today"
    _(json["trained"]).must_equal false

    session_on(Date.today - 2)
    get "/api/today"
    _(json["title"]).must_equal "Workout 2"
    _(json["trained"]).must_equal true

    session_on(Date.today - 1, workout: "cycle-1-workout-2")
    get "/api/today"
    _(json["title"]).must_equal "Workout 1"
  end

  it "moves on from the workout finished last on a day, whatever was planned first" do
    travel_to Time.utc(2026, 10, 20, 18)
    two = session_on("2026-10-19", workout: "cycle-1-workout-2")
    Completion.create(session_id: two.id, finished_at: Time.utc(2026, 10, 19, 8))
    one = session_on("2026-10-19")
    Completion.create(session_id: one.id, finished_at: Time.utc(2026, 10, 19, 7))

    get "/api/today?date=2026-10-20"

    _(json["title"]).must_equal "Workout 1"
  ensure
    travel_back
  end

  it "returns the session already on the day" do
    session = session_on("2026-10-19", "in_progress", workout: "cycle-1-workout-2")

    get "/api/today?date=2026-10-19"

    _(json["source"]).must_equal "session"
    _(json["title"]).must_equal "Workout 2"
    _(json["session"]["id"]).must_equal session.id
  end

  describe "a day with several sessions" do
    let(:date) { "2026-10-19" }

    def on_day(status, workout, position: nil) = session_on(date, status, workout:, position:)

    it "lists them in order and takes the first planned" do
      done = on_day("done", "cycle-1-workout-1")
      later = on_day("planned", "cycle-1-workout-2")
      sooner = on_day("planned", "cycle-1-workout-1", position: 2)
      later.update_columns(position: 3)

      get "/api/today?date=#{date}"

      _(json["day"].map { [it["id"], it["position"], it["status"]] })
        .must_equal [[done.id, 1, "done"], [sooner.id, 2, "planned"], [later.id, 3, "planned"]]
      _(json["source"]).must_equal "session"
      _(json["session"]["id"]).must_equal sooner.id
    end

    it "takes the first under way over a planned one" do
      on_day("planned", "cycle-1-workout-1")
      running = on_day("in_progress", "cycle-1-workout-2")

      get "/api/today?date=#{date}"

      _(json["session"]["id"]).must_equal running.id
      _(json["title"]).must_equal "Workout 2"
    end

    it "runs the session asked for" do
      on_day("planned", "cycle-1-workout-1")
      second = on_day("planned", "cycle-1-workout-2")

      get "/api/today?date=#{date}&session_id=#{second.id}"

      _(json["source"]).must_equal "session"
      _(json["session"]["id"]).must_equal second.id
      _(json["title"]).must_equal "Workout 2"
    end

    it "rejects an unknown session, or one on another day" do
      get "/api/today?date=#{date}&session_id=0"
      _(last_response.status).must_equal 404

      get "/api/today?date=#{date}&session_id=#{session_on("2026-10-20", "planned").id}"
      _(last_response.status).must_equal 404
    end
  end

  describe "a rest day" do
    it "is empty, and points at the next planned session" do
      session_on("2026-10-18", "planned")
      session_on("2026-10-21", "skipped")
      next_one = session_on("2026-10-22", "planned", workout: "cycle-1-workout-2")
      session_on("2026-10-23", "planned")

      get "/api/today?date=2026-10-19"

      _(json["day"]).must_equal []
      _(json["source"]).must_equal "default"
      _(json["next_planned"]["id"]).must_equal next_one.id
      _(json["next_planned"]["status"]).must_equal "planned"
    end

    it "has nothing next when nothing is planned" do
      get "/api/today?date=2026-10-19"

      _(json["next_planned"]).must_be_nil
    end
  end

  it "reads a session planned on the day as planned, whatever the server's today" do
    session_on("2026-10-19", "planned")

    get "/api/today?date=2026-10-19"

    _(json["session"]["status"]).must_equal "planned"
    _(json["day"].first["status"]).must_equal "planned"
  end

  it "lists the sets already logged in the day's session" do
    session = session_on("2026-10-19", "in_progress")
    squat = step_for("cycle-1-workout-1", "goblet-squat")
    SetLog.create(session:, step: squat, set_number: 1, reps: 8)
    SetLog.create(session:, step: squat, set_number: 2, status: "skipped")

    get "/api/today?date=2026-10-19"

    _(json["logged"]).must_equal [
      { "step_id" => squat.id, "set_number" => 1, "side" => nil, "status" => "done" },
      { "step_id" => squat.id, "set_number" => 2, "side" => nil, "status" => "skipped" }
    ]
  end

  describe "choosing the parts" do
    it "leaves out the warm-up and cool-down not asked for" do
      get "/api/today?parts=workout"

      _(json["workouts"].map { [it["kind"], it["included"]] }).must_equal [["warmup", false], ["workout", true], ["cooldown", false]]
      _(json["estimated_minutes"]).must_equal json["workouts"][1]["estimated_minutes"]
      _(json["plan"]["items"].map { it["workout"]["kind"] }.uniq).must_equal ["workout"]
    end

    it "keeps the warm-up alone when asked" do
      get "/api/today?parts=warmup,workout"

      _(json["plan"]["items"].map { it["workout"]["kind"] }.uniq).must_equal %w[warmup workout]
    end

    it "includes everything by default" do
      get "/api/today"

      _(json["workouts"].map { it["included"] }).must_equal [true, true, true]
    end

    it "keeps the parts of a session already under way" do
      session_on("2026-10-19", "in_progress", part_kinds: %w[workout cooldown])

      get "/api/today?date=2026-10-19&parts=workout"

      _(json["workouts"].map { it["included"] }).must_equal [false, true, true]
      _(json["session"]["parts"]).must_equal %w[workout cooldown]
    end

    it "rejects a part it does not know" do
      get "/api/today?parts=stretching"

      _(last_response.status).must_equal 400
    end
  end

  it "does not take a warm-up done on its own as the day's session" do
    session_on("2026-10-19", "done", workout: "cycle-1-warmup")

    get "/api/today?date=2026-10-19"

    _(json["session"]).must_be_nil
    _(json["title"]).must_equal "Workout 1"
  end

  it "names a set kept after its step left by the step it was logged against" do
    session = session_on("2026-10-19", "in_progress")
    step = session.parts.last.blocks.first.steps.first
    SetLog.create(session:, step:, set_number: 1).update_columns(step_id: nil)

    get "/api/today?date=2026-10-19"

    _(json["logged"]).must_equal [{ "step_id" => step.id, "set_number" => 1, "side" => nil, "status" => "done" }]
  end

  it "puts a cool-down planned on its own on the card when the day has nothing else" do
    planned = session_on("2026-10-19", "planned", workout: "cycle-1-cooldown")

    get "/api/today?date=2026-10-19"

    _(json["source"]).must_equal "session"
    _(json["session"]["id"]).must_equal planned.id
    _(json["title"]).must_equal planned.workout.title
    _(json["workouts"].map { it["kind"] }).must_equal %w[cooldown]
    _(json["plan"]["items"]).wont_be_empty
  end

  it "keeps a day's main workout on the card over a cool-down planned on its own" do
    session_on("2026-10-19", "planned", workout: "cycle-1-cooldown")
    main = session_on("2026-10-19", "skipped")

    get "/api/today?date=2026-10-19"

    _(json["session"]["id"]).must_equal main.id
  end

  it "says how many weights each weighted exercise holds" do
    workout2 = workout("cycle-1-workout-2")
    get "/api/today?date=2026-10-19&workout_id=#{workout2.id}"
    items = json["plan"]["items"].select { it["type"] == "exercise" }.index_by { it["exercise"]["slug"] }

    _(items["two-arm-row"]["weights_held"]).must_equal 2
    _(items["curtsy-lunge"]["weights_held"]).must_equal 1
    # Done with a kettlebell, the deadlift holds one weight, not the pair it takes with dumbbells.
    _(items["straight-leg-deadlift"]["weights_held"]).must_equal 1
    _(items["push-up"]["weights_held"]).must_be_nil
    row = json["plan"]["targets"].find { it["exercise"]["name"] == "Two-arm row" }
    _(row["weights_held"]).must_equal 2
    _(row["weight_equipment"]).must_equal "dumbbell"
    _(items["straight-leg-deadlift"]["weight_equipment"]).must_equal "kettlebell"
  end

  it "names the gear that carries each weight of a step done with any weight" do
    get "/api/today?date=2026-10-19&workout_id=#{workout("cycle-1-workout-1").id}"
    squat = json["plan"]["items"].find { it["exercise"] && it["exercise"]["slug"] == "goblet-squat" }
    dumbbells = json["plan"]["items"].find { it["weight_unit"] && it["equipment"] == ["dumbbell"] }
    target = json["plan"]["targets"].find { it["exercise"]["name"] == "Goblet squat" }

    _(squat["any_weight"]["slug"]).must_equal "weight"
    _(squat["any_weight"]["carriers"].to_h { [it["value"], it["equipment"]] })
      .must_equal({ 10.0 => "dumbbell", 20.0 => "dumbbell", 40.0 => "kettlebell" })
    _(target["any_weight"]).must_equal squat["any_weight"]
    _(dumbbells["weight_equipment"]).must_equal "dumbbell"
    _(dumbbells["any_weight"]).must_be_nil
  end

  it "lists nothing logged without a session" do
    get "/api/today?date=2026-10-19"

    _(json["logged"]).must_equal []
  end

  it "builds the plan for a picked workout" do
    get "/api/today?workout_id=#{workout("cycle-1-workout-2").id}"

    _(json["source"]).must_equal "picked"
    _(json["title"]).must_equal "Workout 2"
    _(json["workouts"].size).must_equal 3
  end

  it "builds a picked workout without any program" do
    own = workout("cycle-1-workout-2").duplicate!
    # As if the user had only workouts of their own.
    Workout.dataset.update(program_id: nil, example_slug: nil)
    Program.dataset.delete

    get "/api/today?workout_id=#{own.id}"

    _(last_response.status).must_equal 200
    _(json["title"]).must_equal own.title
  end

  it "says there is nothing to train yet to a user with no workouts" do
    sign_in(create_user("someone", bare: true))
    get "/api/today"

    _(last_response.status).must_equal 404
    _(json["error"]["code"]).must_equal "no_workouts"
    _(json["error"]["message"]).must_include "import an example program"
  end

  it "suggests from the next program when the first has no main workout left" do
    Program.first!(example_slug: "cycle-1").workouts_dataset.update(archived_at: Time.now)

    get "/api/today"

    _(json["source"]).must_equal "default"
    _(json["workout_id"]).must_equal workout("home-strength-a").id
  end

  it "suggests the user's own workout when there is no program" do
    own = workout("cycle-1-workout-2").duplicate!
    Workout.exclude(id: [own.id, own.warmup_id, own.cooldown_id].compact).update(archived_at: Time.now)
    Workout.dataset.update(program_id: nil, example_slug: nil)
    Program.dataset.delete

    get "/api/today"

    _(json["source"]).must_equal "default"
    _(json["workout_id"]).must_equal own.id

    second = own.duplicate!
    Session.create(workout: own, date: Date.new(2026, 10, 18), status: "done", created_by: "manual")
    get "/api/today?date=2026-10-19"
    _(json["workout_id"]).must_equal second.id

    get "/api/workouts"
    _(json.last["workouts"].to_h { [it["id"], it["up_next"]] }.slice(own.id, second.id)).must_equal({ own.id => false, second.id => true })
  end

  it "starts afresh when a workout done today is picked again" do
    session_on("2026-10-19")

    get "/api/today?date=2026-10-19"
    _(json["session"]["status"]).must_equal "done"

    get "/api/today?date=2026-10-19&workout_id=#{workout("cycle-1-workout-1").id}"
    _(json["session"]).must_be_nil
  end

  it "keeps the weight after a session that felt too easy: the app suggests none" do
    inventory("kettlebell").update(weights: [40, 45])
    session = session_on(Date.today - 1, "in_progress")
    log_all(session, "goblet-squat")
    finish(session, "too_easy")

    get "/api/today?workout_id=#{workout("cycle-1-workout-1").id}"
    squat = json["plan"]["items"].find { it["exercise"]["slug"] == "goblet-squat" }

    _(squat.keys).wont_include "suggestion"
    _(squat["weight"]["value"]).must_equal 40.0
  end

  it "gives weighted items the owned weights to step through" do
    get "/api/today?workout_id=#{workout("cycle-1-workout-1").id}"
    fly = json["plan"]["items"].find { it["exercise"] && it["exercise"]["slug"] == "reverse-fly" }

    _(fly["allowed_weights"]).must_equal [10.0, 20.0]
    _(json["plan"]["targets"].find { it["exercise"]["name"] == "Reverse fly" }["allowed_weights"]).must_equal [10.0, 20.0]
  end

  it "offers a weight for a step done with dumbbells that has none yet, in the plan and the workout view" do
    workout = workout("cycle-1-workout-1")
    fly = Exercise.first!(slug: "reverse-fly")
    Step.where(block_id: workout.blocks_dataset.select(:id), exercise_id: fly.id).update(weight_value: nil, weight_unit: nil)
    ExerciseWeight.where(exercise_id: fly.id).delete

    get "/api/today?workout_id=#{workout.id}"
    item = json["plan"]["items"].find { it["exercise"] && it["exercise"]["slug"] == "reverse-fly" }
    target = json["plan"]["targets"].find { it["exercise"]["name"] == "Reverse fly" }

    _(item["weight"]).must_be_nil
    _(item["weight_unit"]).must_equal "lb"
    _(target["weight"]).must_be_nil
    _(target["allowed_weights"]).must_equal [10.0, 20.0]

    get "/api/workouts/#{workout.id}"
    steps = json["blocks"].flat_map { it["steps"] }
    _(steps.find { it["exercise"]["slug"] == "reverse-fly" }.values_at("weight_unit", "allowed_weights")).must_equal ["lb", [10.0, 20.0]]
    _(steps.select { it["equipment_needed"].empty? }.map { it["weight_unit"] }.uniq).must_equal [nil]
  end
end
