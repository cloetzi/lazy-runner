# frozen_string_literal: true

require "test_helper"

describe Example do
  # A user with nothing of their own, signed in for the block.
  def as_new_user(&)
    Current.set(user: create_user("someone", bare: true), &)
  end

  def own(slug, weights)
    UserEquipment.create(equipment: equipment(slug), owned: true, weights:)
  end

  def step(workout_slug, exercise_slug) = step_for(workout_slug, exercise_slug)

  it "lists the examples with their workouts, minutes and gear" do
    _(Example.all.map(&:slug)).must_equal %w[cycle-1 home-strength no-gear]

    cycle = Example.find!("cycle-1").as_json
    _(cycle[:name]).must_equal "Cycle 1"
    _(cycle[:workouts].map { it[:kind] }).must_equal %w[warmup workout workout cooldown]
    _(cycle[:workouts].find { it[:slug] == "cycle-1-workout-1" }[:estimated_minutes])
      .must_equal workout("cycle-1-workout-1").estimated_minutes
    _(cycle[:equipment]).must_include "kettlebell"
    _(cycle[:imported]).must_equal true
    as_new_user { _(Example.find!("cycle-1").as_json[:imported]).must_equal false }
  end

  it "says which example it doesn't know" do
    error = _ { Example.find!("marathon") }.must_raise Record::NotFound
    _(error.message).must_equal "no example program marathon"
  end

  it "imports each one as the user's own program, framed by its warm-up and cool-down" do
    as_new_user do
      program = Example.find!("cycle-1").import!

      _(program.values.slice(:example_slug, :name, :source)).must_equal({ example_slug: "cycle-1", name: "Cycle 1", source: "user" })
      _(program.workouts.map(&:example_slug)).must_equal %w[cycle-1-warmup cycle-1-workout-1 cycle-1-workout-2 cycle-1-cooldown]
      main = workout("cycle-1-workout-1")
      _(main.framed.map(&:example_slug)).must_equal %w[cycle-1-warmup cycle-1-workout-1 cycle-1-cooldown]
      _(main.read_only_reason).must_be_nil
      _(Example.find!("home-strength").import!.workouts.map(&:kind)).must_equal %w[workout workout cooldown]
    end
  end

  it "has one that needs no gear, so it imports for someone who owns nothing as written" do
    _(Example.find!("no-gear").as_json[:equipment]).must_be_empty
    as_new_user do
      program = Example.find!("no-gear").import!

      _(program.workouts.map(&:kind)).must_equal %w[workout workout cooldown]
      steps = program.workouts.flat_map { it.blocks.flat_map(&:steps) }
      _(steps.flat_map { it.exercise.equipment_slugs }).must_be_empty
      _(steps.size).must_equal 29
      _(step("no-gear-a", "split-squat").values.slice(:reps, :tempo, :per_side)).must_equal({ reps: 8, tempo: "3111", per_side: true })
    end
  end

  it "gives every step a target" do
    _(Step.where(reps: nil, duration_seconds: nil, note: nil).count).must_equal 0
  end

  it "keeps every weight the user owns as it is" do
    _(step("cycle-1-workout-1", "goblet-squat").weight).must_equal({ value: 40.0, unit: "lb" })
    _(step("cycle-1-workout-1", "reverse-fly").weight).must_equal({ value: 10.0, unit: "lb" })
  end

  it "snaps each weight to the nearest one owned of its gear" do
    as_new_user do
      own("kettlebell", [35, 53])
      own("dumbbell", [8, 12])
      Example.find!("cycle-1").import!

      _(step("cycle-1-workout-1", "goblet-squat").weight).must_equal({ value: 35.0, unit: "lb" })
      # 10 lb is as near 8 as 12: the lighter one.
      _(step("cycle-1-workout-1", "reverse-fly").weight).must_equal({ value: 8.0, unit: "lb" })
    end
  end

  it "leaves the weight out, and keeps the step, when none of its gear is owned" do
    as_new_user do
      own("dumbbell", [10])
      Example.find!("cycle-1").import!

      deadlift = step("cycle-1-workout-1", "straight-leg-deadlift")
      _(deadlift.weight).must_be_nil
      _(deadlift.equipment_needed).must_equal ["kettlebell"]
      _(step("cycle-1-workout-1", "reverse-fly").weight).must_equal({ value: 10.0, unit: "lb" })
      # Any weight does for a goblet squat: the dumbbell's.
      _(step("cycle-1-workout-1", "goblet-squat").weight).must_equal({ value: 10.0, unit: "lb" })
    end
  end

  it "imports every example for someone who owns nothing, with no weights at all" do
    as_new_user do
      Example.all.each(&:import!)

      _(Step.exclude(weight_value: nil).count).must_equal 0
      _(Step.count).must_be :>, 0
    end
  end

  it "refuses a second import unless asked for a copy" do
    error = _ { Example.find!("cycle-1").import! }.must_raise Example::AlreadyImported
    _(error.message).must_equal "Cycle 1 is already imported; import it again with copy to add another"

    copies = Array.new(2) { Example.find!("cycle-1").import!(copy: true).name }
    _(copies).must_equal ["Cycle 1 (copy)", "Cycle 1 (copy 2)"]
    _(Program.where(example_slug: "cycle-1").count).must_equal 3
  end

  it "counts a copy whose workouts were all archived as not imported" do
    Program.first!(example_slug: "cycle-1").workouts.each(&:archive!)

    _(Example.find!("cycle-1").as_json[:imported]).must_equal false
    _(Example.find!("cycle-1").import!.name).must_equal "Cycle 1"
  end

  it "checks every example on boot by importing it for a stand-in account, leaving nothing" do
    counts = -> { [User.count, Program.everyone.count, Workout.everyone.count] }
    before = counts.call
    Example.check_all!

    _(counts.call).must_equal before
  end

  describe "when broken" do
    def import(step, block = {})
      Example.new("broken", "name" => "Broken", "workouts" => [
                    { "slug" => "broken-1", "kind" => "workout", "title" => "Broken",
                      "blocks" => [{ "label" => "A", "steps" => [step] }.merge(block)] }
                  ]).import!
    end

    def refused(...) = _ { import(...) }.must_raise(Example::Error).message

    it "names an unknown exercise, step key or piece of equipment" do
      _(refused("exercise" => "moonwalk", "reps" => 5)).must_include "unknown exercise 'moonwalk'"
      _(refused("exercise" => "plank", "secs" => 5)).must_include "unknown step keys secs"
      _(refused("exercise" => "plank", "seconds" => 30, "equipment" => ["sled"])).must_include "unknown equipment 'sled'"
      _(refused("exercise" => "plank", "seconds" => 30, "unit" => "kg")).must_include "a unit needs a weight"
    end

    it "names the step or block a validation fails on" do
      _(refused("exercise" => "plank", "reps" => 5, "seconds" => 30))
        .must_equal "broken: broken-1 A step 1 (plank): needs reps or seconds, not both"
      _(refused("exercise" => "curtsy-lunge", "reps" => 8, "per_side" => false))
        .must_include "broken-1 A step 1 (curtsy-lunge): Per side must be set"
      _(refused({ "exercise" => "plank", "seconds" => 30 }, { "rounds" => 0 }))
        .must_equal "broken: broken-1 A: Rounds must be greater than or equal to 1"
    end

    it "does per side what its exercise does per side, unless told" do
      import("exercise" => "curtsy-lunge", "reps" => 8)
      _(Workout.first!(example_slug: "broken-1").blocks.first.steps.first.per_side).must_equal true
    end

    it "leaves nothing behind" do
      _ { import("exercise" => "moonwalk", "reps" => 5) }.must_raise Example::Error
      _(Program.where(example_slug: "broken").empty?).must_equal true
      _(Workout.where(example_slug: "broken-1").empty?).must_equal true
    end
  end
end
