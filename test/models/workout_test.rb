require "test_helper"

describe Workout do
  describe "#framed" do
    it "puts a workout between the warm-up and the cool-down" do
      _(workout("cycle-1-workout-1").framed.map(&:example_slug)).must_equal %w[cycle-1-warmup cycle-1-workout-1 cycle-1-cooldown]
    end

    it "leaves out the parts not asked for, never the workout" do
      _(workout("cycle-1-workout-1").framed(%w[cooldown]).map(&:example_slug)).must_equal %w[cycle-1-workout-1 cycle-1-cooldown]
      _(workout("cycle-1-workout-1").framed([]).map(&:example_slug)).must_equal %w[cycle-1-workout-1]
    end

    it "runs a warm-up on its own" do
      _(workout("cycle-1-warmup").framed.map(&:example_slug)).must_equal %w[cycle-1-warmup]
      _(workout("cycle-1-cooldown").framed(%w[warmup]).map(&:example_slug)).must_equal %w[cycle-1-cooldown]
    end

    it "runs the warm-up and cool-down a workout picked, from any program" do
      main = workout("cycle-1-workout-1")
      main.update(cooldown: workout("home-strength-cooldown"))

      _(main.framed.map(&:example_slug)).must_equal %w[cycle-1-warmup cycle-1-workout-1 home-strength-cooldown]
    end

    it "runs alone when it picked none" do
      main = workout("cycle-1-workout-1")
      main.update(no_warmup: true, no_cooldown: true)

      _(main.framed.map(&:example_slug)).must_equal %w[cycle-1-workout-1]
    end

    it "falls back to its program's when it picked nothing" do
      _(workout("home-strength-a").framed.map(&:example_slug)).must_equal %w[home-strength-a home-strength-cooldown]
    end
  end

  describe "framing" do
    it "only takes a warm-up as the warm-up" do
      main = workout("cycle-1-workout-1")
      main.warmup = workout("cycle-1-cooldown")

      _(main.valid?).must_equal false
      _(main.errors.full_messages).must_include "Warmup must be a warm-up"
    end

    it "is only for main workouts" do
      cooldown = workout("cycle-1-cooldown")
      cooldown.no_warmup = true

      _(cooldown.valid?).must_equal false
      _(cooldown.errors.full_messages).must_include "Warmup can only be picked for a main workout"
    end
  end

  describe "#archive! of a program's warm-up" do
    let(:warmup) { workout("cycle-1-warmup") }

    it "takes it off the program's workouts that ran with it, as off those that picked it" do
      own = workout("home-strength-a").tap { it.update(warmup_id: warmup.id) }
      picked = warmup.picked_by.map(&:example_slug)
      _(picked).must_equal %w[cycle-1-workout-1 cycle-1-workout-2 home-strength-a]

      warmup.archive!

      _(workout("cycle-1-workout-1").framed.map(&:example_slug)).must_equal %w[cycle-1-workout-1 cycle-1-cooldown]
      _(own.refresh.frame_choice("warmup")).must_equal "none"
      # Another program's workouts, which never ran with it, are left alone.
      _(workout("home-strength-b").frame_choice("warmup")).must_be_nil
    end

    it "waits while a session runs one of the program's workouts without it" do
      travel_to Time.zone.local(2026, 10, 25, 12)
      session_on(Date.current, "in_progress", workout: "cycle-1-workout-1", part_kinds: %w[workout cooldown])

      _ { warmup.archive! }.must_raise Workout::Running
      _(warmup.refresh.archived?).must_equal false
    end
  end

  describe "#duplicate!" do
    let(:original) { workout("cycle-1-workout-1") }
    let(:copy) { original.duplicate! }

    it "makes a standalone user copy with the same blocks and steps" do
      _(copy.source).must_equal "user"
      _(copy.example_slug).must_be_nil
      _(copy.program).must_be_nil
      _(copy.title).must_equal "#{original.title} (copy)"
      shape = ->(workout) { workout.blocks.map { [it.label, it.rounds, it.steps.map { |step| [step.exercise_id, step.reps, step.duration_seconds, step.weight, step.equipment_needed] }] } }
      _(shape.(copy)).must_equal shape.(original)
      _(copy.blocks.flat_map(&:steps).map(&:id) & original.blocks.flat_map(&:steps).map(&:id)).must_be_empty
    end

    it "keeps the warm-up and cool-down it ran with" do
      _(copy.framed.map(&:example_slug)).must_equal ["cycle-1-warmup", nil, "cycle-1-cooldown"]
      _(workout("home-strength-a").duplicate!.framed.map(&:example_slug)).must_equal [nil, "home-strength-cooldown"]
    end
  end
end
