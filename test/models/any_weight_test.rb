require "test_helper"

# The generic weight (#225): exercises that need one weight, any dumbbell or
# kettlebell, and how the gear owned stands in for it.
describe "the generic weight" do
  let(:weight) { equipment("weight") }

  def own_only(*slugs)
    Equipment.weighted.exclude(slug: slugs).all.each { inventory(it.slug).update(owned: false) }
  end

  it "is owned with any gear in set weights, and not with none" do
    own_only("kettlebell")
    _(Equipment.owned.select_map(:slug)).must_include "weight"
    _(Exercise.doable_with(Equipment.owned.all).select_map(:slug)).must_include "goblet-squat"

    own_only
    _(Equipment.owned.select_map(:slug)).wont_include "weight"
    _(Exercise.doable_with(Equipment.owned.all).select_map(:slug)).wont_include "goblet-squat"
  end

  it "comes along when dumbbells or a kettlebell are named, but not other gear" do
    _(Equipment.named("kettlebell").map(&:slug).sort).must_equal %w[kettlebell weight]
    _(Equipment.named("stability_ball").map(&:slug)).must_equal ["stability_ball"]
    _(Exercise.doable_with(Equipment.named("dumbbell")).select_map(:slug)).must_include "goblet-squat"
  end

  it "steps through every weight owned, in one unit" do
    step = Step.new(reps: 8).tap { it.exercise = exercise("goblet-squat") }

    _(step.equipment_needed).must_equal ["weight"]
    _(step.allowed_weights).must_equal [10.0, 20.0, 40.0]
  end

  it "names the owned item with the weight set in the player" do
    squat = exercise("goblet-squat").id
    workout = Workout.create_with!({ kind: "workout", title: "Squats", blocks: [{ label: "A", steps: [
      { exercise_id: squat, reps: 8, weight: { value: 40, unit: "lb" } }, { exercise_id: squat, reps: 8, weight: { value: 30, unit: "lb" } }
    ] }] }, source: "user")
    ExerciseWeight.where(exercise_id: squat).delete

    items = PlayerPlan.new([workout.refresh], weights: {}).items.select { it[:exercise] }

    _(items.map { it[:weight_equipment] }).must_equal %w[kettlebell weight]
  end

  it "keeps its weights in the unit all the gear comes in, else the user's" do
    inventory("dumbbell").update(unit: "kg", weights: [4, 8])
    inventory("kettlebell").update(unit: "kg", weights: [16])
    _(exercise("goblet-squat").weight_unit).must_equal "kg"
    _(Equipment.allowed_for(["weight"], "kg")).must_equal [4.0, 8.0, 16.0]

    inventory("kettlebell").update(unit: "lb", weights: [40])
    _(exercise("goblet-squat").weight_unit).must_equal Setting.unit
  end

  it "can't be owned as such" do
    error = _ { UserEquipment.create(equipment: weight, owned: true) }.must_raise Sequel::ValidationFailed
    _(error.message).must_include "mark those instead"
  end
end
