require "test_helper"

# The rules a workout, its blocks and steps keep, in the models and in the
# database, so whatever writes them (seeds, builder, MCP) leaves something the
# player can run.
describe "workout rules" do
  let(:block) { workout("cycle-1-workout-1").blocks.first }
  let(:squat) { exercise("goblet-squat") }
  let(:lunge) { exercise("curtsy-lunge") }

  def step(**attrs) = Step.new(block:, exercise: squat, position: 99, reps: 8, **attrs)

  def problems(record, context = nil)
    record.valid?(validation_context: context)
    record.errors.full_messages
  end

  describe Step do
    it "accepts a step with reps, tempo and weight" do
      _(problems(step(tempo: "2111", weight_value: 40, weight_unit: "lb"))).must_be_empty
    end

    it "needs reps or seconds, not both" do
      _(problems(step(duration_seconds: 30))).must_include "needs reps or seconds, not both"
      _(problems(step(reps: nil))).must_include "needs reps, seconds or a note"
      _(problems(step(reps: nil, note: "Until tired"))).must_be_empty
    end

    it "needs positive whole reps and seconds" do
      _(problems(step(reps: 0))).must_include "Reps must be greater than 0"
      _(problems(step(reps: nil, duration_seconds: -5))).must_include "Duration seconds must be greater than 0"
      _ { step(reps: 2.5).save }.must_raise Sequel::ValidationFailed
      _(problems(step(reps: "2.5"))).must_include "Reps must be an integer"
      _(problems(step(reps: Float::INFINITY))).must_include "Reps is not a number"
      _(problems(step(reps: "ten"))).must_include "Reps is not a number"
    end

    it "needs a tempo of three or four digits" do
      _(problems(step(tempo: "slow"))).must_include "Tempo must be 3 or 4 digits, seconds per phase"
      _(problems(step(tempo: "21"))).wont_be_empty
      _(problems(step(tempo: "301"))).must_be_empty
    end

    it "needs a known unit with a weight, and no unit without one" do
      _(problems(step(weight_value: 20))).must_include "Weight unit is not included in the list"
      _(problems(step(weight_value: 20, weight_unit: "stone"))).must_include "Weight unit is not included in the list"
      _(problems(step(weight_unit: "kg"))).must_include "Weight unit needs a weight"
      _(problems(step(weight_value: -1, weight_unit: "kg"))).must_include "Weight value must be greater than or equal to 0"
      _(problems(step(weight_value: Float::INFINITY, weight_unit: "kg"))).must_include "Weight value is not a number"
    end

    it "is done per side exactly when its exercise is" do
      _(Step.new(exercise: lunge).per_side).must_equal true
      _(Step.new(exercise: squat).per_side).must_equal false
      _(problems(step(per_side: true))).must_include "Per side must not be set, goblet-squat works both sides at once"
      _(problems(step(exercise: lunge, per_side: false))).must_include "Per side must be set, curtsy-lunge is done one side at a time"
    end

    it "is timed when it has seconds, as its exercise is" do
      _(step(reps: nil, duration_seconds: 30).timed?).must_equal true
      _(step.timed?).must_equal false
      _(exercise("plank").timed?).must_equal true
      _(squat.timed?).must_equal false
    end

    it "needs what its exercise needs, unless it names its own equipment" do
      _(step.equipment_needed).must_equal squat.equipment_slugs
      own = step.save
      own.add_equipment(equipment("kettlebell"))
      _(own.equipment_needed).must_equal ["kettlebell"]
    end

    it "has no gear of its own when it lists what its exercise needs" do
      _(step.own_equipment).must_be_nil
      same = step.save
      squat.equipment.each { same.add_equipment(it) }
      _(same.own_equipment).must_be_nil
      other = step(position: 98).save
      other.add_equipment(equipment("kettlebell"))
      _(other.as_json.values_at(:equipment, :equipment_needed)).must_equal [["kettlebell"], ["kettlebell"]]
    end
  end

  describe Exercise do
    it "has default reps or default seconds, not both" do
      squat.default_seconds = 30
      _(problems(squat)).must_include "needs default reps or default seconds, not both"
    end

    it "works known areas only" do
      squat.areas = %w[legs knees]
      _(problems(squat)).must_include "Areas unknown: knees"
    end

    it "trains a known movement pattern" do
      squat.pattern = "jump"
      _(problems(squat)).must_include "Pattern is not included in the list"
    end
  end

  describe Block do
    it "needs a label, at least one round and no negative rest" do
      block.set(label: "", rounds: 0, rest_seconds: -10)
      _(problems(block)).must_equal ["Label can't be blank", "Rounds must be greater than or equal to 1", "Rest seconds must be greater than or equal to 0"]
    end

    it "needs a step to be run" do
      empty = Block.create(workout: block.workout, label: "Z", position: 9)
      _(problems(empty)).must_be_empty
      _(problems(empty, :publish)).must_equal ["needs at least one step"]
    end
  end

  describe Workout do
    it "is runnable with the seeded blocks" do
      _(problems(workout("cycle-1-workout-1"), :publish)).must_be_empty
    end

    it "needs a block, each with a step, to be run" do
      fresh = Workout.create(program: Program.first, example_slug: "fresh", kind: "workout", title: "Fresh", position: 9)
      _(problems(fresh, :publish)).must_equal ["needs at least one block"]

      Block.create(workout: fresh, label: "A", position: 1)
      _(problems(fresh.refresh, :publish)).must_equal ["block A: needs at least one step"]
    end
  end

  describe "in the database" do
    def rejects(&write) = _ { write.call }.must_raise(Sequel::ConstraintViolation, write.source_location.inspect)

    it "rejects what the models would, even past them" do
      steps = Step.where(id: block.steps.first.id)

      rejects { Block.where(id: block.id).update(rounds: 0) }
      rejects { Block.where(id: block.id).update(rest_seconds: -1) }
      rejects { steps.update(reps: 8, duration_seconds: 30) }
      rejects { steps.update(reps: nil, duration_seconds: nil, note: nil) }
      rejects { steps.update(reps: -1) }
      rejects { steps.update(tempo: "slow") }
      rejects { steps.update(weight_value: 20, weight_unit: nil) }
      rejects { steps.update(weight_value: 20, weight_unit: "stone") }
      rejects { steps.update(weight_value: -5, weight_unit: "lb") }
      rejects { Exercise.where(id: squat.id).update(default_reps: 8, default_seconds: 30) }
    end
  end
end
