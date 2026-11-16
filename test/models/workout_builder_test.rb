# frozen_string_literal: true

require "test_helper"

# Writing a workout's whole structure from a description, as the builder API
# and the MCP tools do: all or nothing, keeping what it names.
describe "workout builder" do
  let(:squat) { exercise("goblet-squat") }
  let(:plank) { exercise("plank") }

  def build(source: "user", **attrs)
    Workout.create_with!(
      { kind: "workout", title: "Built", blocks: [{ label: "A", steps: [{ exercise_id: squat.id, reps: 8 }] }] }.merge(attrs), source:
    )
  end

  it "marks who built it" do
    _(build.source).must_equal "user"
    _(build(source: "llm").source).must_equal "llm"
  end

  it "comes after the user's other workouts and is ready to run" do
    first = build
    second = build

    _(second.position).must_equal first.position + 1
    _(second.valid?(validation_context: :publish)).must_equal true
    _(second.blocks.first.steps.map(&:exercise)).must_equal [squat]
  end

  it "takes string keys as well as symbols" do
    steps = [{ "exercise_id" => plank.id.to_s, "duration_seconds" => "30" }]
    workout = Workout.create_with!({ "kind" => "cooldown", "title" => "Wind down", "blocks" => [{ "label" => "A", "steps" => steps }] })

    _(workout.kind).must_equal "cooldown"
    _(workout.blocks.first.steps.first.duration_seconds).must_equal 30
  end

  it "names a step's exercise by its slug too, as the MCP tools do" do
    steps = [{ exercise: "goblet-squat", reps: 8 }, { exercise: plank.id, duration_seconds: 30 }]
    workout = Workout.create_with!({ kind: "workout", title: "Slugs", blocks: [{ label: "A", steps: }] })

    _(workout.blocks.first.steps.map(&:exercise)).must_equal [squat, plank]
  end

  it "takes a retired exercise by slug only for a step that already has it" do
    built = build
    step = built.blocks.first.steps.first
    squat.update(retired: true)

    _(built.revise!(blocks: [{ label: "A", steps: [{ id: step.id, exercise: "goblet-squat", reps: 10 }] }]).blocks.first.steps.first.reps)
      .must_equal 10
    _ { built.revise!(blocks: [{ label: "A", steps: [{ exercise: "goblet-squat", reps: 10 }] }]) }.must_raise WorkoutStructure::Invalid
  end

  it "names the field of an exercise it can't find" do
    error = _ do
      build(blocks: [{ label: "A", steps: [{ exercise: "burpee", reps: 8 }, { exercise_id: 0, reps: 8 }, { reps: 8 }] }])
    end.must_raise WorkoutStructure::Invalid

    _(error.fields.keys).must_equal %w[blocks[0].steps[0].exercise blocks[0].steps[1].exercise_id blocks[0].steps[2].exercise_id]
    _(error.message).must_include "Block 1 (A), step 1: Exercise burpee is not in the library"
    _(error.message).must_include "Block 1 (A), step 3: Exercise is required: its exercise_id, or its slug as exercise"
  end

  it "keeps only the equipment a step is done with instead of its exercise's" do
    workout = build(blocks: [{ label: "A", steps: [
                      { exercise: "goblet-squat", reps: 8, equipment: ["weight"] },
                      { exercise: "goblet-squat", reps: 8, equipment: ["kettlebell"], weights_held: 1 }
                    ] }])

    _(workout.blocks.first.steps.map { it.equipment.map(&:slug) }).must_equal [[], ["kettlebell"]]
  end

  it "leaves nothing behind when the structure is wrong" do
    count = Workout.count

    error = _ { build(blocks: [{ label: "A", rounds: 0, steps: [{ exercise_id: squat.id, reps: 8, duration_seconds: 30 }] }]) }.must_raise WorkoutStructure::Invalid

    _(error.fields).must_equal({ "blocks[0].rounds" => ["must be greater than or equal to 1"],
                                 "blocks[0].steps[0]" => ["needs reps or seconds, not both"] })
    _(Workout.count).must_equal count
  end

  it "refuses archived workouts" do
    archived = workout("cycle-1-workout-1").tap { it.update(archived_at: Time.now) }
    _ { archived.revise!(title: "Again") }.must_raise Workout::ReadOnly
  end

  it "refuses to restructure a workout while a session runs it, but renames it" do
    travel_to Time.zone.local(2026, 10, 25, 12)
    built = build
    Session.create(workout: built, date: Time.zone.today, status: "in_progress")

    _ { built.revise!(blocks: [{ label: "B", steps: [{ exercise_id: plank.id, duration_seconds: 30 }] }]) }.must_raise Workout::Running
    _(built.refresh.blocks.map(&:label)).must_equal ["A"]
    _(built.revise!(title: "Renamed").refresh.title).must_equal "Renamed"
  end

  it "knows a warm-up a running session left out is free to change" do
    travel_to Time.zone.local(2026, 10, 25, 12)
    warmup = build(kind: "warmup")
    main = build(warmup: warmup.id)
    session = Session.create(workout: main, date: Time.zone.today, status: "in_progress", part_kinds: ["workout"])

    _(warmup.running_session).must_be_nil
    session.update(part_kinds: nil)
    _(warmup.running_session.id).must_equal session.id
  end

  describe "a run left under way" do
    before { travel_to Time.zone.local(2026, 10, 25, 12) }
    after { travel_back }

    it "holds the workout on its day and the next, then lets it go" do
      built = build
      run = travel_to(Time.zone.local(2026, 10, 24, 8)) do
        Session.create(workout: built, date: Date.new(2026, 10, 24), status: "in_progress")
      end

      _(built.running_session.id).must_equal run.id
      travel_to Time.zone.local(2026, 10, 26, 12)
      _(built.running_session).must_be_nil
      _(built.revise!(blocks: [{ label: "B", steps: [{ exercise_id: plank.id, duration_seconds: 30 }] }]).refresh.blocks.map(&:label))
        .must_equal ["B"]
    end

    it "holds it later on while it is picked up again or logs a set" do
      built = build
      run = travel_to(Time.zone.local(2026, 10, 20, 8)) do
        Session.create(workout: built, date: Date.new(2026, 10, 20), status: "in_progress")
      end
      _(built.running_session).must_be_nil

      run.update(note: "back at it")
      _(built.running_session.id).must_equal run.id

      travel_to Time.zone.local(2026, 10, 28, 12)
      _(built.running_session).must_be_nil
      SetLog.create(session: run, step: built.blocks.first.steps.first, set_number: 1, reps: 8)
      _(built.running_session.id).must_equal run.id
    end

    it "isn't woken by an edit that unlinks its sets" do
      built = build
      run = travel_to(Time.zone.local(2026, 10, 20, 8)) do
        Session.create(workout: built, date: Date.new(2026, 10, 20), status: "in_progress").tap do |session|
          SetLog.create(session:, step: built.blocks.first.steps.first, set_number: 1, reps: 8)
        end
      end

      built.revise!(blocks: [{ label: "B", steps: [{ exercise_id: plank.id, duration_seconds: 30 }] }])

      _(run.set_logs_dataset.first.step_id).must_be_nil
      _(built.running_session).must_be_nil
    end
  end
end
