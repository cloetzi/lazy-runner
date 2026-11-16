# frozen_string_literal: true

require "test_helper"

describe "workouts API" do
  include RequestHelpers

  let(:seeded) { workout("cycle-1-workout-1") }

  def duplicate(workout = seeded, **body)
    post_json "/api/workouts/#{workout.id}/duplicate", body
    Workout.find!(json["id"])
  end

  describe "a workout imported from an example" do
    it "is the user's to change and archive" do
      patch_json "/api/workouts/#{seeded.id}", title: "Mine now"

      _(last_response.status).must_equal 200
      _(seeded.refresh.title).must_equal "Mine now"
      _(seeded.program_id).wont_be_nil

      delete "/api/workouts/#{seeded.id}"

      _(last_response.status).must_equal 204
      _(seeded.refresh.archived?).must_equal true
    end

    it "says where it came from" do
      get "/api/workouts/#{seeded.id}"

      _(json.slice("source", "editable", "warmup", "cooldown", "example_slug")).must_equal(
        { "source" => "user", "editable" => true, "warmup" => nil, "cooldown" => nil, "example_slug" => "cycle-1-workout-1" }
      )
      _(json["framed"].map { it["example_slug"] }).must_equal %w[cycle-1-warmup cycle-1-workout-1 cycle-1-cooldown]
    end
  end

  describe "POST /api/workouts/:id/duplicate" do
    it "gives an editable copy with the same steps and framing" do
      post_json "/api/workouts/#{seeded.id}/duplicate", title: "My legs"

      _(last_response.status).must_equal 201
      _(json.slice("title", "source", "editable", "program_id"))
        .must_equal({ "title" => "My legs", "source" => "user", "editable" => true, "program_id" => nil })
      _(json["blocks"].flat_map { it["steps"] }.map { it["exercise"]["slug"] })
        .must_equal(seeded.blocks.flat_map(&:steps).map { it.exercise.slug })
      _(json["framed"].map { it["title"] }).must_equal [workout("cycle-1-warmup").title, "My legs", workout("cycle-1-cooldown").title]
    end

    it "cuts a long title short to fit its \"(copy)\"" do
      seeded.update(title: "A" * Workout::MAX_LENGTHS[:title])
      post_json "/api/workouts/#{seeded.id}/duplicate"

      _(last_response.status).must_equal 201, last_response.body
      _(json["title"]).must_equal "#{"A" * (Workout::MAX_LENGTHS[:title] - 7)} (copy)"
    end

    it "lists the copy under My workouts" do
      copy = duplicate

      get "/api/workouts"

      _(json.last["name"]).must_equal "My workouts"
      _(json.last["id"]).must_be_nil
      _(json.last["workouts"].map { it["id"] }).must_equal [copy.id]
      _(json.last["workouts"].first["framed_minutes"]).must_equal copy.framed.sum(&:estimated_minutes)
    end
  end

  describe "PATCH /api/workouts/:id" do
    it "renames the user's own workout" do
      copy = duplicate

      patch_json "/api/workouts/#{copy.id}", title: "Legs, quick", subtitle: "When short on time"

      _(last_response.status).must_equal 200
      _(json.slice("title", "subtitle")).must_equal({ "title" => "Legs, quick", "subtitle" => "When short on time" })
    end

    it "looks the workout up before what the request carries" do
      patch_json "/api/workouts/0", blocks: []
      _(last_response.status).must_equal 404

      patch_json "/api/workouts/#{duplicate.id}", kind: "cooldown"
      _(last_response.status).must_equal 400
    end

    it "picks a warm-up and cool-down, or none" do
      copy = duplicate

      patch_json "/api/workouts/#{copy.id}", warmup: "none", cooldown: workout("home-strength-cooldown").id

      _(json.slice("warmup", "cooldown")).must_equal({ "warmup" => "none", "cooldown" => workout("home-strength-cooldown").id })
      _(json["framed"].map { it["kind"] }).must_equal %w[workout cooldown]
      _(copy.refresh.framed.map(&:id)).must_equal [copy.id, workout("home-strength-cooldown").id]
    end

    it "runs alone with neither, as it has no program to fall back to" do
      copy = duplicate

      patch_json "/api/workouts/#{copy.id}", warmup: nil, cooldown: nil

      _(json.slice("warmup", "cooldown")).must_equal({ "warmup" => nil, "cooldown" => nil })
      _(json["framed"].map { it["id"] }).must_equal [copy.id]
    end

    it "rejects a cool-down as the warm-up, and an unknown one" do
      copy = duplicate

      patch_json "/api/workouts/#{copy.id}", warmup: workout("cycle-1-cooldown").id
      _(last_response.status).must_equal 422
      _(json["error"]["message"]).must_equal "Warmup must be a warm-up"

      patch_json "/api/workouts/#{copy.id}", warmup: 0
      _(last_response.status).must_equal 422
    end
  end

  describe "POST /api/workouts" do
    def new_workout(**overrides)
      {
        kind: "workout", title: "Knees of steel", subtitle: "Ski season",
        blocks: [
          { label: "A", rounds: 3, rest_seconds: 45, steps: [
            { exercise_id: exercise("goblet-squat").id, reps: 8, tempo: "3110", weight: { value: 20, unit: "lb" } },
            { exercise_id: exercise("curtsy-lunge").id, reps: 10, weight: { value: 10 } }
          ] },
          { label: "Core", steps: [{ exercise_id: exercise("plank").id, duration_seconds: 40 }] }
        ]
      }.merge(overrides)
    end

    it "builds a workout of the user's own, standing alone" do
      post_json "/api/workouts", new_workout

      _(last_response.status).must_equal 201
      _(json.slice("kind", "title", "subtitle", "source", "editable", "program_id")).must_equal(
        { "kind" => "workout", "title" => "Knees of steel", "subtitle" => "Ski season", "source" => "user", "editable" => true,
          "program_id" => nil }
      )
      _(json["blocks"].map { it.slice("label", "position", "rounds", "rest_seconds") }).must_equal [
        { "label" => "A", "position" => 1, "rounds" => 3, "rest_seconds" => 45 },
        { "label" => "Core", "position" => 2, "rounds" => 1, "rest_seconds" => 0 }
      ]
      squat, lunge = json["blocks"].first["steps"]
      _(squat.slice("position", "reps", "tempo", "weight", "per_side"))
        .must_equal({ "position" => 1, "reps" => 8, "tempo" => "3110", "weight" => { "value" => 20.0, "unit" => "lb" },
                      "per_side" => false })
      _(lunge.slice("per_side", "weight")).must_equal({ "per_side" => true, "weight" => { "value" => 10.0, "unit" => "lb" } })
      _(json["framed"].map { it["id"] }).must_equal [json["id"]]
      _(json["plan"]["items"]).wont_be_empty

      get "/api/workouts"
      _(json.last["workouts"].map { it["title"] }).must_equal ["Knees of steel"]
    end

    it "writes nothing when a step is wrong, and says which" do
      count = Workout.count
      body = new_workout
      body[:blocks][1][:steps] << { exercise_id: exercise("goblet-squat").id, reps: 0 }
      body[:blocks][0][:steps][1] = { exercise_id: 0, reps: 10 }

      post_json "/api/workouts", body

      _(last_response.status).must_equal 422
      _(json["error"]["message"]).must_equal "Block 1 (A), step 2: Exercise 0 is not in the library; " \
                                             "Block 2 (Core), step 2 (goblet-squat): Reps must be greater than 0"
      _(json["error"]["fields"]).must_equal({ "blocks[0].steps[1].exercise_id" => ["names no exercise in the library"],
                                              "blocks[1].steps[1].reps" => ["must be greater than 0"] })
      _(Workout.count).must_equal count
    end

    it "needs a title, a known kind and its blocks, and lists every problem at once" do
      body = new_workout(title: "", kind: "stretch")
      body[:blocks][1][:steps][0][:duration_seconds] = 0
      post_json "/api/workouts", body
      _(last_response.status).must_equal 422
      _(json["error"]["fields"].keys).must_equal %w[blocks[1].steps[0].duration_seconds title kind]
      _(json["error"]["message"]).must_include "Title can't be blank"

      post_json "/api/workouts", new_workout.except(:blocks)
      _(last_response.status).must_equal 400
      _(json["error"]["fields"]).must_equal({ "blocks" => ["is required"] })
    end

    # The player walks every round of every step, in the one worker every
    # user shares: a workout can't ask for unbounded work.
    it "keeps a workout to a size a person does in one go" do
      count = Workout.count
      body = new_workout(title: "x" * 101)
      body[:blocks][0].merge!(rounds: 10**12, rest_seconds: 601)
      body[:blocks][0][:steps][0][:reps] = 1001
      body[:blocks][1][:steps][0].merge!(duration_seconds: 3601, note: "n" * 501)
      post_json "/api/workouts", body

      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal(
        { "blocks[0].rounds" => ["must be less than or equal to 20"],
          "blocks[0].rest_seconds" => ["must be less than or equal to 600"],
          "blocks[0].steps[0].reps" => ["must be less than or equal to 1000"],
          "blocks[1].steps[0].duration_seconds" => ["must be less than or equal to 3600"],
          "blocks[1].steps[0].note" => ["is longer than 500 characters"],
          "title" => ["is longer than 100 characters"] }
      )
      _(Workout.count).must_equal count
    end

    it "counts rounds across steps and blocks" do
      step = { exercise_id: exercise("plank").id, duration_seconds: 30 }
      post_json "/api/workouts", new_workout(blocks: Array.new(13) { { label: "B#{it}", steps: [step] } })
      _(json["error"]["fields"]).must_equal({ "blocks" => ["can be at most 12 blocks"] })

      post_json "/api/workouts", new_workout(blocks: [{ label: "A", steps: Array.new(31) { step } }])
      _(json["error"]["fields"]).must_equal({ "blocks[0].steps" => ["can be at most 30 steps"] })

      blocks = Array.new(2) { { label: "B#{it}", rounds: 20, steps: Array.new(8) { step } } }
      post_json "/api/workouts", new_workout(blocks:)
      _(last_response.status).must_equal 422
      _(json["error"]["fields"])
        .must_equal({ "blocks" => ["add up to 320 steps across their rounds and sides; a workout can have at most 300"] })

      blocks[1][:rounds] = 15
      post_json "/api/workouts", new_workout(blocks:)
      _(last_response.status).must_equal 201, last_response.body

      # One side at a time is a screen a side.
      sided = { exercise_id: exercise("half-kneel-quad-stretch").id, duration_seconds: 30 }
      post_json "/api/workouts", new_workout(blocks: [{ label: "A", rounds: 20, steps: Array.new(8) { sided } }])
      _(json["error"]["fields"])
        .must_equal({ "blocks" => ["add up to 320 steps across their rounds and sides; a workout can have at most 300"] })
    end

    it "picks a warm-up and cool-down" do
      post_json "/api/workouts", new_workout(warmup: workout("cycle-1-warmup").id, cooldown: "none")

      _(json.slice("warmup", "cooldown")).must_equal({ "warmup" => workout("cycle-1-warmup").id, "cooldown" => "none" })
      _(json["framed"].map { it["kind"] }).must_equal %w[warmup workout]
    end
  end

  describe "PUT /api/workouts/:id" do
    let(:copy) { duplicate(title: "Mine") }

    # The workout's structure as PUT takes it, ids included.
    def structure(workout = copy)
      workout.refresh.blocks.map do |block|
        { id: block.id, label: block.label, rounds: block.rounds, rest_seconds: block.rest_seconds,
          steps: block.steps.map do |step|
            { id: step.id, exercise_id: step.exercise_id, reps: step.reps, duration_seconds: step.duration_seconds, note: step.note }
          end }
      end
    end

    it "refuses a step's suggestion, which the app no longer gives" do
      blocks = structure
      blocks.first[:steps].first[:suggestion] = { direction: "up", value: 45, unit: "lb", reason: "Felt too easy" }

      put_json "/api/workouts/#{copy.id}", blocks: blocks

      _(last_response.status).must_equal 422
    end

    it "replaces the blocks and steps, keeping the ids it names" do
      blocks = structure
      first, *rest = blocks.first[:steps]
      blocks.first[:steps] = [*rest, first.merge(reps: 15, tempo: "2111")]
      blocks.first[:rounds] = 4
      blocks << { label: "Finisher", steps: [{ exercise_id: exercise("plank").id, duration_seconds: 30, note: "Hold it" }] }

      put_json "/api/workouts/#{copy.id}", blocks:, title: "Mine, longer"

      _(last_response.status).must_equal 200
      _(json["title"]).must_equal "Mine, longer"
      block = json["blocks"].first
      _(block.slice("id", "rounds")).must_equal({ "id" => blocks.first[:id], "rounds" => 4 })
      _(block["steps"].map { it["id"] }).must_equal [*rest.map { it[:id] }, first[:id]]
      _(block["steps"].map { it["position"] }).must_equal (1..block["steps"].size).to_a
      _(block["steps"].last.slice("reps", "tempo")).must_equal({ "reps" => 15, "tempo" => "2111" })
      _(json["blocks"].last.slice("label", "position")).must_equal({ "label" => "Finisher", "position" => blocks.size })
      _(json["blocks"].last["steps"].first.slice("duration_seconds", "note")).must_equal({ "duration_seconds" => 30, "note" => "Hold it" })
    end

    it "swaps block labels and moves a step to another block" do
      blocks = structure
      a, b = blocks
      moved = a[:steps].pop
      b[:steps] << moved
      a[:label], b[:label] = b[:label], a[:label]

      put_json "/api/workouts/#{copy.id}", blocks: [a, b, *blocks.drop(2)]

      _(last_response.status).must_equal 200
      _(json["blocks"].first(2).map { it.slice("id", "label") })
        .must_equal [{ "id" => a[:id], "label" => a[:label] }, { "id" => b[:id], "label" => b[:label] }]
      _(json["blocks"][1]["steps"].last["id"]).must_equal moved[:id]
    end

    it "deletes what it leaves out, keeping the sets logged against it" do
      session = Session.create(workout: copy, date: Date.iso8601("2026-10-20"), status: "done")
      step = copy.blocks.first.steps.first
      log = SetLog.create(session:, step:, set_number: 1, side: ("left" if step.per_side), reps: 5)
      blocks = structure
      blocks.first[:steps].shift

      put_json "/api/workouts/#{copy.id}", blocks: [blocks.first]

      _(last_response.status).must_equal 200
      _(json["blocks"].size).must_equal 1
      _(Step.where(id: step.id).empty?).must_equal true
      _(log.refresh.step_id).must_be_nil
      _(log.planned_exercise).must_equal step.exercise

      get "/api/history"
      _(last_response.status).must_equal 200
    end

    it "gives a step a new id when its exercise changes" do
      blocks = structure
      old = blocks.first[:steps].first
      blocks.first[:steps][0] = old.merge(exercise_id: exercise("plank").id, reps: nil, duration_seconds: 30)

      put_json "/api/workouts/#{copy.id}", blocks: blocks

      _(last_response.status).must_equal 200
      step = json["blocks"].first["steps"].first
      _(step["exercise"]["slug"]).must_equal "plank"
      _(step["id"]).wont_equal old[:id]
      _(Step.where(id: old[:id]).empty?).must_equal true
    end

    it "takes gear other than the exercise names, and a weight in its unit" do
      blocks = [{ label: "A",
                  steps: [{ exercise_id: exercise("goblet-squat").id, reps: 8, equipment: ["kettlebell"], weights_held: 1,
                            weight: { value: 40 } }] }]

      put_json "/api/workouts/#{copy.id}", blocks: blocks

      step = json["blocks"].first["steps"].first
      _(step.slice("equipment", "weight")).must_equal({ "equipment" => ["kettlebell"], "weight" => { "value" => 40.0, "unit" => "lb" } })
      _(step["allowed_weights"]).must_equal [40.0]
    end

    it "keeps a step's weight in the unit of the gear it is done with when gear comes in mixed units" do
      inventory("kettlebell").update(unit: "kg", weights: [16, 24])
      blocks = [{ label: "A",
                  steps: [{ exercise_id: exercise("reverse-fly").id, reps: 8, equipment: ["kettlebell"], weights_held: 1,
                            weight: { value: 16, unit: "kg" } }] }]

      put_json "/api/workouts/#{copy.id}", blocks: blocks

      step = json["blocks"].first["steps"].first
      _(step["weight"]).must_equal({ "value" => 16.0, "unit" => "kg" })
      _(step["weight_unit"]).must_equal "kg"
      _(step["allowed_weights"]).must_equal [16.0, 24.0]
    end

    it "changes nothing when any part is invalid" do
      before = structure
      blocks = structure
      blocks.first[:steps].first[:reps] = nil
      blocks.first[:steps].first[:duration_seconds] = nil
      blocks.first[:steps].first[:note] = nil
      blocks << { label: blocks.first[:label], steps: [{ exercise_id: exercise("plank").id, duration_seconds: 20, speed: "fast" }] }

      put_json "/api/workouts/#{copy.id}", blocks:, title: "Renamed"

      _(last_response.status).must_equal 422
      fields = json["error"]["fields"]
      _(fields["blocks[0].steps[0]"]).must_equal ["needs reps, seconds or a note"]
      _(fields["blocks[#{blocks.size - 1}].label"].first).must_include "already the label of block 1"
      _(fields["blocks[#{blocks.size - 1}].steps[0].speed"].first).must_include "is not a field here"
      _(json["error"]["message"]).must_include "Block 1 (#{before.first[:label]}), step 1"
      _(structure).must_equal before
      _(copy.refresh.title).must_equal "Mine"
    end

    it "keeps to the workout's own blocks and steps" do
      other = step_for("cycle-1-workout-1", seeded.blocks.first.steps.first.exercise.slug)
      blocks = structure
      blocks.first[:steps].first[:id] = other.id
      blocks.first[:id] = other.block_id

      put_json "/api/workouts/#{copy.id}", blocks: blocks

      _(last_response.status).must_equal 422
      _(json["error"]["fields"].keys).must_equal %w[blocks[0].id blocks[0].steps[0].id]
      _(other.refresh.block.workout).must_equal seeded
    end

    it "needs blocks with steps" do
      put_json "/api/workouts/#{copy.id}", blocks: [{ label: "A", steps: [] }]
      _(last_response.status).must_equal 422
      _(json["error"]["message"]).must_equal "Block 1 (A): needs at least one step"

      put_json "/api/workouts/#{copy.id}", blocks: []
      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal({ "blocks" => ["needs at least one block"] })

      put_json "/api/workouts/#{copy.id}", title: "No blocks"
      _(last_response.status).must_equal 400

      put_json "/api/workouts/#{copy.id}", kind: "cooldown", blocks: structure
      _(last_response.status).must_equal 400
      _(json["error"]["fields"].keys).must_equal ["kind"]
    end

    it "takes back a workout as GET gives it" do
      get "/api/workouts/#{copy.id}"
      blocks = json["blocks"]
      blocks.first["steps"].first["reps"] = 12

      put_json "/api/workouts/#{copy.id}", blocks: blocks

      _(last_response.status).must_equal 200
      _(json["blocks"].first["steps"].first["reps"]).must_equal 12
      _(json["blocks"].flat_map { it["steps"] }.map { it["id"] }).must_equal(blocks.flat_map { it["steps"] }.map { it["id"] })
    end

    it "keeps a step's own gear and weights held when GET's blocks come back" do
      get "/api/workouts/#{copy.id}"
      deadlift = json["blocks"].flat_map { it["steps"] }.find { it["exercise"]["slug"] == "straight-leg-deadlift" }
      _(deadlift.slice("weights_held", "equipment")).must_equal({ "weights_held" => 1, "equipment" => ["kettlebell"] })

      put_json "/api/workouts/#{copy.id}", blocks: json["blocks"]

      _(last_response.status).must_equal 200
      _(Step.find!(deadlift["id"]).values.slice(:weights_held, :exercise_id))
        .must_equal({ weights_held: 1, exercise_id: deadlift["exercise"]["id"] })
      _(Step.find!(deadlift["id"]).equipment.map(&:slug)).must_equal ["kettlebell"]
      # Gear GET only echoes from the exercise stays the exercise's.
      _(DB[:step_equipment].where(step_id: copy.blocks.flat_map(&:steps).map(&:id)).count)
        .must_equal DB[:step_equipment].where(step_id: seeded.blocks.flat_map(&:steps).map(&:id)).count
    end

    it "waits for an old run that is picked up again" do
      run = travel_to(Time.zone.local(2026, 10, 20, 8)) do
        Session.create(workout: copy, date: Date.iso8601("2026-10-20"), status: "in_progress", started_at: Time.now)
      end
      travel_to Time.zone.local(2026, 10, 25, 12)

      patch_json "/api/sessions/#{run.id}", status: "in_progress"
      put_json "/api/workouts/#{copy.id}", blocks: structure

      _(last_response.status).must_equal 409
    end

    it "gives blocks that fit its own input schema" do
      get "/api/workouts/#{copy.id}"

      _(RequestHelpers::SCHEMA.errors({ "blocks" => json["blocks"] }, { "$ref" => "#/components/schemas/WorkoutStructure" })).must_be_empty
    end

    it "names only a step's own gear, so another exercise brings its own" do
      get "/api/workouts/#{copy.id}"
      blocks = json["blocks"]
      bridge = blocks.flat_map { it["steps"] }.find { it["exercise"]["slug"] == "hamstring-bridge-bench" }
      _(bridge.slice("equipment", "equipment_needed")).must_equal({ "equipment" => nil, "equipment_needed" => ["bench"] })

      bridge["exercise_id"] = exercise("push-up").id
      put_json "/api/workouts/#{copy.id}", blocks: blocks

      _(last_response.status).must_equal 200
      push_up = json["blocks"].flat_map { it["steps"] }.find { it["exercise"]["slug"] == "push-up" }
      _(push_up.slice("equipment", "equipment_needed")).must_equal({ "equipment" => nil, "equipment_needed" => [] })
    end

    it "keeps a step whose exercise was retired, but adds none" do
      get "/api/workouts/#{copy.id}"
      blocks = json["blocks"]
      retired = exercise("goblet-squat")
      retired.update(retired: true)

      put_json "/api/workouts/#{copy.id}", blocks:, title: "Still mine"

      _(last_response.status).must_equal 200
      _(json["title"]).must_equal "Still mine"

      blocks.first["steps"] << { exercise_id: retired.id, reps: 5 }
      put_json "/api/workouts/#{copy.id}", blocks: blocks

      _(last_response.status).must_equal 422
      _(json["error"]["fields"].keys).must_equal ["blocks[0].steps[#{blocks.first["steps"].size - 1}].exercise_id"]
    end

    it "keeps a weight in the exercise's unit, snapped to what is owned" do
      blocks = [{ label: "A", steps: [{ exercise_id: exercise("goblet-squat").id, reps: 8, weight: { value: 9, unit: "kg" } }] }]

      put_json "/api/workouts/#{copy.id}", blocks: blocks
      _(json["blocks"].first["steps"].first["weight"]).must_equal({ "value" => 20.0, "unit" => "lb" })

      blocks.first[:steps].first[:weight] = { value: 9, units: "kg" }
      put_json "/api/workouts/#{copy.id}", blocks: blocks
      _(last_response.status).must_equal 422
      _(json["error"]["fields"].keys).must_equal ["blocks[0].steps[0].weight.units"]
    end

    it "takes a weight as its value alone, and names a weight without a value" do
      blocks = [{ label: "A", steps: [{ exercise_id: exercise("goblet-squat").id, reps: 8, weight: 20 }] }]

      put_json "/api/workouts/#{copy.id}", blocks: blocks
      _(json["blocks"].first["steps"].first["weight"]).must_equal({ "value" => 20.0, "unit" => "lb" })

      blocks.first[:steps].first[:weight] = { unit: "lb" }
      put_json "/api/workouts/#{copy.id}", blocks: blocks
      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal({ "blocks[0].steps[0].weight.value" => ["is required"] })
      _(json["error"]["message"]).must_include %(Weight {"unit":"lb"} has no value)

      blocks.first[:steps].first[:weight] = { value: nil }
      put_json "/api/workouts/#{copy.id}", blocks: blocks
      _(json["blocks"].first["steps"].first["weight"]).must_be_nil
    end

    it "points PATCH to PUT for blocks" do
      patch_json "/api/workouts/#{copy.id}", blocks: structure
      _(last_response.status).must_equal 400
      _(json["error"]["fields"].keys).must_equal ["blocks"]
    end

    it "takes a cleared tempo or note as none" do
      blocks = structure
      blocks.first[:steps].first.merge!(tempo: "", note: " ")

      put_json "/api/workouts/#{copy.id}", blocks: blocks

      _(last_response.status).must_equal 200
      _(json["blocks"].first["steps"].first.slice("tempo", "note")).must_equal({ "tempo" => nil, "note" => nil })
    end

    it "leaves archived workouts alone" do
      copy.update(archived_at: Time.now)
      put_json "/api/workouts/#{copy.id}", blocks: structure
      _(last_response.status).must_equal 403
    end

    it "waits while a session runs it, as the workout or its warm-up" do
      travel_to Time.zone.local(2026, 10, 25, 12)
      running = Session.create(workout: copy, date: Time.zone.today, status: "in_progress")

      put_json "/api/workouts/#{copy.id}", blocks: structure

      _(last_response.status).must_equal 409
      _(json["error"]["message"]).must_include "Mine is being trained right now (session #{running.id})"

      running.update(status: "skipped")
      warmup = duplicate(workout("cycle-1-warmup"))
      patch_json "/api/workouts/#{copy.id}", warmup: warmup.id
      Session.create(workout: copy, date: Time.zone.today, status: "in_progress")

      put_json "/api/workouts/#{warmup.id}", blocks: structure(warmup)
      _(last_response.status).must_equal 409

      put_json "/api/workouts/#{copy.id}", title: "Renamed meanwhile", blocks: structure
      _(last_response.status).must_equal 409
      _(copy.refresh.title).must_equal "Mine"

      patch_json "/api/workouts/#{copy.id}", warmup: "none"
      _(last_response.status).must_equal 409

      patch_json "/api/workouts/#{copy.id}", title: "Renamed meanwhile", warmup: warmup.id
      _(last_response.status).must_equal 200
    end
  end

  describe "DELETE /api/workouts/:id" do
    before { travel_to Time.utc(2026, 10, 25, 12) }
    after { travel_back }

    it "archives the user's own workout, keeping its sessions" do
      copy = duplicate
      done = Session.create(workout: copy, date: Date.iso8601("2026-10-20"), status: "done")
      missed = session_on("2026-10-22", "planned", workout: copy)

      delete "/api/workouts/#{copy.id}"

      _(last_response.status).must_equal 204
      _(copy.refresh.archived?).must_equal true
      _(done.refresh.workout).must_equal copy

      get "/api/workouts"
      _(json.flat_map { it["workouts"] }.map { it["id"] }).wont_include copy.id

      get "/api/sessions/#{missed.id}"
      _(json["status"]).must_equal "missed"
      _(json["workout"]["archived"]).must_equal true

      patch_json "/api/workouts/#{copy.id}", title: "Back"
      _(last_response.status).must_equal 403
    end

    it "takes an archived warm-up out of the workouts that pick it" do
      warmup = duplicate(workout("cycle-1-warmup"))
      main = duplicate
      patch_json "/api/workouts/#{main.id}", warmup: warmup.id
      planned = Session.plan!(workout: main, date: Date.iso8601("2026-10-26"))

      delete "/api/workouts/#{warmup.id}"

      _(last_response.status).must_equal 204
      get "/api/workouts/#{main.id}"
      _(json["warmup"]).must_equal "none"
      _(json["framed"].map { it["id"] }).must_equal [main.id, main.cooldown_id]
      _(planned.refresh.workout.framed_ids).wont_include warmup.id
    end

    it "leaves archived workouts that picked it as they were" do
      warmup = duplicate(workout("cycle-1-warmup"))
      old = duplicate
      patch_json "/api/workouts/#{old.id}", warmup: warmup.id
      old.update(archived_at: Time.current)

      delete "/api/workouts/#{warmup.id}"

      _(old.refresh.warmup_id).must_equal warmup.id
    end

    it "keeps a warm-up a session is running" do
      warmup = duplicate(workout("cycle-1-warmup"))
      main = duplicate
      patch_json "/api/workouts/#{main.id}", warmup: warmup.id
      Session.create(workout: main, date: Date.iso8601("2026-10-25"), status: "in_progress")

      delete "/api/workouts/#{warmup.id}"

      _(last_response.status).must_equal 409
      _(json["error"]["message"]).must_include "it can be archived once that session is finished or skipped"
      _(warmup.refresh.archived?).must_equal false
      _(main.refresh.warmup_id).must_equal warmup.id
    end

    it "keeps a warm-up while a workout that picks it runs, even without it" do
      warmup = duplicate(workout("cycle-1-warmup"))
      main = duplicate
      patch_json "/api/workouts/#{main.id}", warmup: warmup.id
      Session.create(workout: main, date: Date.iso8601("2026-10-25"), status: "in_progress", part_kinds: ["workout"])

      delete "/api/workouts/#{warmup.id}"

      _(last_response.status).must_equal 409
      _(main.refresh.warmup_id).must_equal warmup.id
    end

    it "takes the workout off the calendar from today on" do
      copy = duplicate
      today, later = %w[2026-10-25 2026-10-30].map do |date|
        post_json("/api/sessions", workout_id: copy.id, date:)
        Session.find!(json["id"])
      end
      skipped = Session.create(workout: copy, date: Date.iso8601("2026-10-26"), status: "skipped")
      other = Session.plan!(workout: seeded, date: Date.iso8601("2026-10-30"))

      delete "/api/workouts/#{copy.id}"

      _(Session.where(id: today.id).empty?).must_equal true
      _(Session.where(id: later.id).empty?).must_equal true
      _(skipped.refresh.status).must_equal "skipped"
      # The day it leaves is renumbered.
      _(other.refresh.position).must_equal 1
    end
  end

  it "plans and runs a session of the user's own workout" do
    travel_to Time.utc(2026, 10, 25, 12)
    copy = duplicate(title: "Mine")

    post_json "/api/sessions", workout_id: copy.id, date: "2026-10-25"
    _(last_response.status).must_equal 201

    get "/api/today?date=2026-10-25&workout_id=#{copy.id}"

    _(last_response.status).must_equal 200
    _(json["title"]).must_equal "Mine"
    _(json["program"]).must_be_nil
    _(json["session"]["status"]).must_equal "planned"
    _(json["workouts"].map { it["kind"] }).must_equal %w[warmup workout cooldown]
  ensure
    travel_back
  end
end
