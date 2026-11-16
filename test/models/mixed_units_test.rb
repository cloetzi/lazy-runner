# frozen_string_literal: true

require "test_helper"

# Gear in mixed units: dumbbells in lb, the kettlebell in kg (#197).
describe "weights with gear in mixed units" do
  let(:fly) { exercise("reverse-fly") }
  let(:fly_step) { step_for("cycle-1-workout-1", "reverse-fly") }

  before { inventory("kettlebell").update(unit: "kg", weights: [16, 24]) }

  def with_kettlebell(step, value)
    step.update(equipment_pks: [equipment("kettlebell").id], weight_value: value, weight_unit: "kg")
    step.refresh
  end

  def plan_item(step)
    PlayerPlan.new([Workout.expanded.first!(id: step.block.workout_id)]).items.find { it[:step_id] == step.id }
  end

  describe "a step done with other gear than its exercise names" do
    it "keeps its weight, target and stepper in that gear's unit" do
      step = with_kettlebell(fly_step, 16)
      item = plan_item(step)

      _(step.gear_unit).must_equal "kg"
      _(item[:weight]).must_equal({ value: 16.0, unit: "kg" })
      _(item[:weight_unit]).must_equal "kg"
      _(item[:allowed_weights]).must_equal [16.0, 24.0]
    end

    it "shows the remembered weight in that unit, snapped to an owned weight" do
      step = with_kettlebell(fly_step, 16)
      ExerciseWeight.remember!(fly, 24, "kg")

      _(step.target(ExerciseWeight.first(exercise_id: fly.id))[:weight]).must_equal({ value: 24.0, unit: "kg" })
    end

    it "steps Get ready through the weights of all its gear, in the first step's unit" do
      fly_step
      two = workout("cycle-1-workout-2")
      two.blocks.first.add_step(exercise: fly, position: 99, reps: 10, equipment_pks: [equipment("kettlebell").id])
      plan = PlayerPlan.new([Workout.expanded.first!(id: fly_step.block.workout_id), Workout.expanded.first!(id: two.id)])
      target = plan.targets.find { it[:exercise][:id] == fly.id }

      _(target[:weight_unit]).must_equal "lb"
      _(target[:allowed_weights]).must_equal [10.0, 20.0, 35.27, 52.91]
    end

    it "leaves a step done with the exercise's own gear in its unit" do
      _(fly_step.gear_unit).must_equal "lb"
      _(plan_item(fly_step)[:allowed_weights]).must_equal [10.0, 20.0]
    end
  end

  describe "a unit relabelled" do
    it "relabels the step weights and remembered weights that were an owned weight of that gear" do
      kettlebell_step = with_kettlebell(step_for("cycle-1-workout-1", "straight-leg-deadlift"), 16)
      ExerciseWeight.remember!(fly, 20, "lb")
      fly_step.update(weight_value: 10, weight_unit: "lb")
      odd = step_for("cycle-1-workout-1", "goblet-squat")

      inventory("dumbbell").update(unit: "kg")

      _(fly_step.refresh.weight).must_equal({ value: 10.0, unit: "kg" })
      _(ExerciseWeight.first!(exercise_id: fly.id).weight).must_equal({ value: 20.0, unit: "kg" })
      _(kettlebell_step.refresh.weight).must_equal({ value: 16.0, unit: "kg" })
      _(odd.refresh.weight).must_equal({ value: 40.0, unit: "lb" })
    end

    it "leaves a weight that was none of the owned ones" do
      fly_step.update(weight_value: 15, weight_unit: "lb")

      inventory("dumbbell").update(unit: "kg")

      _(fly_step.refresh.weight).must_equal({ value: 15.0, unit: "lb" })
    end

    it "relabels by the weights owned before when the same change lists new ones" do
      fly_step.update(weight_value: 10, weight_unit: "lb")

      inventory("dumbbell").update(unit: "kg", weights: [4, 8])

      _(fly_step.refresh.weight).must_equal({ value: 10.0, unit: "kg" })
    end

    it "relabels the steps done with a kettlebell, not those of its exercise's dumbbells" do
      step = with_kettlebell(fly_step, 16)
      dumbbells = workout("cycle-1-workout-2").blocks.first.add_step(exercise: fly, position: 99, reps: 10, weight_value: 16,
                                                                     weight_unit: "kg")

      inventory("kettlebell").update(unit: "lb")

      _(step.refresh.weight).must_equal({ value: 16.0, unit: "lb" })
      _(dumbbells.refresh.weight).must_equal({ value: 16.0, unit: "kg" })
    end
  end

  describe "an example imported" do
    it "snaps a step done with other gear to that gear's weights, in its unit" do
      Current.set(user: create_user("mixed", bare: true)) do
        UserEquipment.create(equipment: equipment("dumbbell"), owned: true, unit: "lb", weights: [10, 20])
        UserEquipment.create(equipment: equipment("kettlebell"), owned: true, unit: "kg", weights: [16, 24])
        Example.find!("cycle-1").import!
        deadlift = Step.where(exercise_id: exercise("straight-leg-deadlift").id).all.find { it.equipment.map(&:slug) == ["kettlebell"] }

        _(deadlift.weight).must_equal({ value: 16.0, unit: "kg" })
      end
    end
  end
end
