require "test_helper"

describe "library API" do
  include RequestHelpers

  describe "GET /api/exercises" do
    it "lists exercises with their cues" do
      get "/api/exercises"

      _(last_response.status).must_equal 200
      _(json.size).must_equal 44
      _(json.find { it["slug"] == "plank" }["cues"]).must_include "Elbows under shoulders"
    end

    it "says where each exercise works" do
      get "/api/exercises"

      _(json.find { it["slug"] == "goblet-squat" }["areas"]).must_equal ["legs"]
      _(json.find { it["slug"] == "push-up" }["areas"]).must_equal %w[upper_body core]
      _(json.reject { it["areas"].any? }.map { it["slug"] }).must_be_empty
      _(json.flat_map { it["areas"] }.uniq.sort).must_equal Exercise::AREAS.sort
    end

    it "leaves out exercises kept only for their history" do
      exercise("plank").update(retired: true)

      get "/api/exercises"

      _(json.size).must_equal 43
      _(json.map { it["slug"] }).wont_include "plank"
    end
  end

  describe "GET /api/exercises/:id" do
    it "returns one exercise" do
      get "/api/exercises/#{exercise("goblet-squat").id}"

      _(json["name"]).must_equal "Goblet squat"
      _(json["equipment"]).must_equal ["weight"]
    end

    it "includes the animation and the how-to instructions" do
      get "/api/exercises/#{exercise("goblet-squat").id}"

      _(json["animation"]["anchor"]).must_equal "ankle_near"
      _(json["animation"]["keyframes"].size).must_be :>=, 2
      _(json["animation"]["props"]).must_equal [{ "type" => "dumbbell", "at" => "hand_near" }]
      _(json["instructions"].first).must_include "feet a little wider"
      _(json.keys).wont_include "image_path"
    end

    it "links to no videos elsewhere" do
      get "/api/exercises/#{exercise("goblet-squat").id}"

      _(json.keys & %w[videos video_url]).must_be_empty
    end

    it "has an animation and instructions for every exercise" do
      get "/api/exercises"

      _(json.reject { it["animation"] && it["instructions"].any? }.map { it["slug"] }).must_be_empty
    end

    it "returns 404 for an unknown id" do
      get "/api/exercises/0"

      _(last_response.status).must_equal 404
      _(json["error"]).must_equal({ "code" => "not_found", "message" => "Exercise 0 not found", "resource" => "exercise", "id" => "0" })
    end
  end

  describe "GET /api/exercises/:id/alternatives" do
    def alternatives(slug)
      get "/api/exercises/#{exercise(slug).id}/alternatives"
      json
    end

    it "offers exercises of the same category that train the same movement first" do
      list = alternatives("goblet-squat")

      _(last_response.status).must_equal 200
      _(list.first["slug"]).must_equal "wall-sit"
      _(list.map { it["match"] }.chunk_while { |a, b| a == b }.map(&:first)).must_equal %w[same similar other]
      _(list.select { it["match"] == "similar" }.map { it["slug"] }).must_include "rear-foot-elevated-split-squat"
      _(list.map { it["category"] }.uniq).must_equal ["strength"]
      _(list.map { it["slug"] }).wont_include "goblet-squat"
      _(list.find { it["slug"] == "push-up" }["match"]).must_equal "other"
    end

    it "says why each one is offered" do
      list = alternatives("goblet-squat").index_by { it["slug"] }

      _(list["curtsy-lunge"]["reason"]).must_equal "Similar movement, same weight, one side at a time"
      _(list["straight-leg-deadlift"]["reason"]).must_equal "Works the same area, dumbbells"
      _(list["push-up"]["reason"]).must_equal "Same kind of exercise, no equipment"
    end

    it "offers two-sided exercises for a per-side one too, same movement first" do
      list = alternatives("single-leg-deadlift")

      _(list.first(3).map { it["pattern"] }.uniq).must_equal ["hinge"]
      _(list.map { it["unilateral"] }.uniq.size).must_equal 2
      _(list.find { it["slug"] == "straight-leg-deadlift" }["reason"]).must_equal "Same movement, dumbbells, both sides at once"
    end

    it "says when an alternative alternates sides, or stops alternating" do
      _(alternatives("w-raise-hinge").find { it["slug"] == "glute-bridge-single-leg-lift" }["reason"]).must_include "alternating sides"
      _(alternatives("dead-bug").find { it["slug"] == "t-raise-hinge" }["reason"]).must_include "both sides at once"
    end

    it "leaves out exercises that need equipment you don't own" do
      inventory("stability_ball").update(owned: false)

      _(alternatives("goblet-squat").map { it["slug"] }).wont_include "swiss-ball-hamstring-curl"
    end

    it "says which take a weight, even with none to start at" do
      list = alternatives("goblet-squat").index_by { it["slug"] }

      _(list["push-up"].values_at("weight_unit", "allowed_weights")).must_equal [nil, nil]
      _(list["straight-leg-deadlift"]["weight_unit"]).must_equal "lb"
      _(list["straight-leg-deadlift"]["allowed_weights"]).wont_be_nil
    end

    it "gives each the weight to start at, remembered before planned" do
      deadlift = exercise("straight-leg-deadlift")
      planned = alternatives("goblet-squat").find { it["slug"] == "straight-leg-deadlift" }["weight"]
      _(planned).must_equal Step.where(exercise: deadlift).exclude(weight_value: nil).first.weight.transform_keys(&:to_s)

      ExerciseWeight.create(exercise: deadlift, value: 55, unit: "lb")
      _(alternatives("goblet-squat").find { it["slug"] == "straight-leg-deadlift" }["weight"]).must_equal({ "value" => 55.0, "unit" => "lb" })
      _(alternatives("goblet-squat").find { it["slug"] == "plank" }["weight"]).must_be_nil
    end

    it "gives weighted ones the owned weights to step through" do
      list = alternatives("goblet-squat")

      _(list.find { it["slug"] == "straight-leg-deadlift" }["allowed_weights"]).must_equal [10.0, 20.0]
      _(list.find { it["slug"] == "plank" }["allowed_weights"]).must_be_nil
    end
  end

  describe "GET /api/programs" do
    it "lists programs with workout summaries" do
      get "/api/programs"

      _(json.first["name"]).must_equal "Cycle 1"
      _(json.first["workouts"].map { it["title"] }).must_equal ["Warm-up", "Workout 1", "Workout 2", "Cool-down"]
    end
  end

  describe "GET /api/workouts" do
    it "leaves out a program whose workouts were all archived" do
      Program.first!(example_slug: "cycle-1").workouts.each(&:archive!)
      get "/api/workouts"

      _(json.map { it["name"] }).must_equal ["Home strength", "No-gear strength"]
    end

    it "lists every workout by program with its exercises and equipment" do
      get "/api/workouts"

      _(last_response.status).must_equal 200
      _(json.first["name"]).must_equal "Cycle 1"
      workouts = json.first["workouts"]
      _(workouts.map { it["kind"] }).must_equal %w[warmup workout workout cooldown]
      first = workouts.find { it["example_slug"] == "cycle-1-workout-1" }
      _(first["exercises"]).must_include "Goblet squat"
      _(first["exercises"]).must_equal first["exercises"].uniq
      _(first["equipment"]).must_include "dumbbell"
      _(first["exercise_ids"]).must_include exercise("goblet-squat").id
      _(first["exercise_ids"].size).must_equal first["exercises"].size
      _(first["estimated_minutes"]).must_be :>, 0
      frame = workouts.reject { it["kind"] == "workout" }.sum { it["estimated_minutes"] }
      _(first["framed_minutes"]).must_equal first["estimated_minutes"] + frame
      _(workouts.first["framed_minutes"]).must_equal workouts.first["estimated_minutes"]
    end

    it "marks the main workout that is up next and when each was last done" do
      session_on("2026-10-20", "done")
      session_on("2026-10-22", "skipped")

      get "/api/workouts"
      workouts = json.first["workouts"].index_by { it["example_slug"] }

      _(workouts.values.select { it["up_next"] }.map { it["example_slug"] }).must_equal ["cycle-1-workout-2"]
      _(workouts["cycle-1-workout-1"]["last_done"]).must_equal "2026-10-20"
      _(workouts["cycle-1-workout-2"]["last_done"]).must_be_nil
    end
  end

  describe "GET /api/workouts/:id" do
    def step_json(slug) = json["blocks"].flat_map { it["steps"] }.find { it["exercise"]["slug"] == slug }

    it "expands blocks and steps" do
      get "/api/workouts/#{workout("cycle-1-workout-2").id}"

      _(json["blocks"].map { it["label"] }).must_equal %w[A B C]
      split_squat = json["blocks"][1]["steps"][0]
      _(split_squat["exercise"]["slug"]).must_equal "rear-foot-elevated-split-squat"
      _(split_squat["weight"]).must_equal({ "value" => 10.0, "unit" => "lb" })
      _(split_squat["allowed_weights"]).must_equal [10.0, 20.0]
      _(split_squat["per_side"]).must_equal true
      _(json["plan"]["items"]).wont_be_empty
    end

    it "says the player which exercises alternate sides" do
      get "/api/workouts/#{workout("cycle-1-workout-1").id}"

      bug = json["plan"]["items"].find { it["type"] == "exercise" && it["exercise"]["slug"] == "dead-bug" }
      _(bug["exercise"]["alternating"]).must_equal true
      _(json["plan"]["items"].find { it["type"] == "exercise" && it["exercise"]["slug"] != "dead-bug" }["exercise"]["alternating"]).must_equal false
    end

    it "gives each step its target, with a remembered weight winning over the seed" do
      squat = exercise("goblet-squat")
      ExerciseWeight.create(exercise: squat, value: 45, unit: "lb")

      get "/api/workouts/#{workout("cycle-1-workout-1").id}"
      goblet = step_json("goblet-squat")

      _(goblet["target"]).must_equal({ "reps" => goblet["reps"], "seconds" => nil, "weight" => { "value" => 45.0, "unit" => "lb" } })
      _(goblet["weight"]).must_equal({ "value" => 40.0, "unit" => "lb" })
      _(step_json("straight-leg-deadlift")["target"]["weight"]).must_equal({ "value" => 40.0, "unit" => "lb" })
      _(step_json("dead-bug")["target"]["weight"]).must_be_nil
    end

    it "gives a remembered weight in the exercise's unit, snapped to an owned one, and the owned weights to step through" do
      fly = exercise("reverse-fly")
      ExerciseWeight.create(exercise: fly, value: 9, unit: "kg")
      inventory("dumbbell").update(weights: [20, 10, 15])

      get "/api/workouts/#{workout("cycle-1-workout-1").id}"
      step = step_json("reverse-fly")

      _(step["target"]["weight"]).must_equal({ "value" => 20.0, "unit" => "lb" })
      _(step["allowed_weights"]).must_equal [10.0, 15.0, 20.0]
    end

    it "includes pending suggestions and the weight increments" do
      WeightSuggestion.create(exercise: exercise("goblet-squat"), session: session_on(Date.today), direction: "up", value: 45, unit: "lb", reason: "Felt too easy at 40 lb")

      get "/api/workouts/#{workout("cycle-1-workout-1").id}"

      _(step_json("goblet-squat")["suggestion"]["value"]).must_equal 45.0
      _(step_json("straight-leg-deadlift")["suggestion"]).must_be_nil
      _(json["weight_steps"]).must_equal Coach.weight_steps
    end
  end
end
