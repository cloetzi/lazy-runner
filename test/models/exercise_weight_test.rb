# frozen_string_literal: true

require "test_helper"

describe ExerciseWeight do
  describe "#fall_back!" do
    def log(slug, on:, value:)
      SetLog.create(session: session_on(on), step: step_for("cycle-1-workout-1", slug), set_number: 1, reps: 8, weight_value: value,
                    weight_unit: "lb")
    end

    it "goes back to the weight of the latest session that logged the exercise" do
      log("goblet-squat", on: "2026-10-14", value: 30)
      log("goblet-squat", on: "2026-10-07", value: 50)
      remembered = ExerciseWeight.create(exercise: exercise("goblet-squat"), value: 60, unit: "lb")

      remembered.fall_back!

      _(remembered.refresh.weight).must_equal({ value: 30.0, unit: "lb" })
    end

    it "goes back to no weight when the latest set logged was 0" do
      log("goblet-squat", on: "2026-10-14", value: 0)
      remembered = ExerciseWeight.create(exercise: exercise("goblet-squat"), value: 60, unit: "lb")

      remembered.fall_back!

      _(remembered.refresh.none?).must_equal true
    end

    it "goes back to the seed weight when nothing is logged" do
      remembered = ExerciseWeight.create(exercise: exercise("goblet-squat"), value: 60, unit: "lb")

      remembered.fall_back!

      _(remembered.refresh.weight).must_equal({ value: 40.0, unit: "lb" })
    end

    it "keeps the converted weight in the exercise's unit" do
      log("goblet-squat", on: "2026-10-14", value: 30)
      SetLog.last.update(weight_value: 20, weight_unit: "kg")
      remembered = ExerciseWeight.create(exercise: exercise("goblet-squat"), value: 60, unit: "lb")

      remembered.fall_back!

      _(remembered.refresh.unit).must_equal "lb"
      _(remembered.value.to_f).must_be_close_to 44.1, 0.1
    end

    it "is gone with nothing to go back to" do
      remembered = ExerciseWeight.create(exercise: exercise("plank"), value: 10, unit: "lb")

      remembered.fall_back!

      _(ExerciseWeight.where(id: remembered.id).empty?).must_equal true
    end
  end
end
