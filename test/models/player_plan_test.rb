require "test_helper"

describe PlayerPlan do
  def plan_for(slug)
    PlayerPlan.new([Workout.expanded.first!(example_slug: slug)])
  end

  it "runs each block as a circuit with rest between rounds" do
    items = plan_for("cycle-1-workout-1").items
    block_a = items.take_while { it[:block][:label] == "A" }

    _(block_a.map { it[:type] == "rest" ? "rest" : it[:exercise][:slug] }).must_equal %w[
      goblet-squat straight-leg-deadlift rest
      goblet-squat straight-leg-deadlift rest
      goblet-squat straight-leg-deadlift
    ]
    _(block_a.map { it[:block][:round] }).must_equal [1, 1, 1, 2, 2, 2, 3, 3]
    _(block_a.find { it[:type] == "rest" }[:seconds]).must_equal 60
  end

  it "runs per-side steps left then right" do
    items = plan_for("cycle-1-workout-1").items.select { it[:type] == "exercise" && it[:exercise][:slug] == "single-leg-deadlift" }

    _(items.map { it[:side] }).must_equal %w[left right left right]
  end

  it "marks timed and rep-based steps" do
    items = plan_for("cycle-1-warmup").items.select { it[:type] == "exercise" }
    quad = items.first
    bridge = items.find { it[:exercise][:slug] == "glute-bridge-single-leg-lift" }
    calf = items.find { it[:exercise][:slug] == "calf-stretch" }

    _(bridge[:mode]).must_equal "reps"
    _(calf[:note]).must_equal "Knee straight, then bent"
    _(quad[:mode]).must_equal "timed"
    _(quad[:seconds]).must_equal 20
  end

  it "carries the target weight" do
    squat = plan_for("cycle-1-workout-1").items.first

    _(squat[:weight]).must_equal({ value: 40.0, unit: "lb" })
    _(squat[:tempo]).must_equal "2111"
  end

  describe "a step done with gear in set weights but no weight" do
    def unweighted_fly
      workout = Workout.first!(example_slug: "cycle-1-workout-1")
      step = Step.where(block_id: workout.blocks_dataset.select(:id), exercise_id: Exercise.first!(slug: "reverse-fly").id).first!
      step.update(weight_value: nil, weight_unit: nil)
      ExerciseWeight.where(exercise_id: step.exercise_id).delete
      PlayerPlan.new([Workout.expanded.first!(id: workout.id)])
    end

    it "can still take a weight: its unit and the owned weights to step through, as a target" do
      plan = unweighted_fly
      fly = plan.items.find { it[:exercise] && it[:exercise][:slug] == "reverse-fly" }
      target = plan.targets.find { it[:exercise][:name] == "Reverse fly" }

      _(fly[:weight]).must_be_nil
      _(fly[:weight_unit]).must_equal "lb"
      _(fly[:weight_equipment]).must_equal "dumbbell"
      _(fly[:allowed_weights]).must_equal [10.0, 20.0]
      _(target[:weight]).must_be_nil
      _(target[:weight_unit]).must_equal "lb"
    end
  end

  it "leaves a step done without weights without a unit or a target" do
    plan = plan_for("cycle-1-warmup")

    _(plan.items.select { it[:type] == "exercise" }.map { it[:weight_unit] }.uniq).must_equal [nil]
    _(plan.targets).must_be_empty
  end

  it "carries what the player needs to animate and explain each exercise" do
    quad = plan_for("cycle-1-warmup").items.find { it[:exercise] && it[:exercise][:slug] == "half-kneel-quad-stretch" }

    _(quad[:exercise][:animation]["anchor"]).must_equal "knee_near"
    _(quad[:exercise][:instructions]).wont_be_empty
    _(quad[:exercise].keys).must_include :mistakes
  end

  it "gives weighted items the owned weights to step through" do
    items = plan_for("cycle-1-workout-1").items.select { it[:type] == "exercise" }
    by_slug = items.index_by { it[:exercise][:slug] }

    _(by_slug["goblet-squat"][:allowed_weights]).must_equal [10.0, 20.0, 40.0]
    _(by_slug["straight-leg-deadlift"][:allowed_weights]).must_equal [40.0]
    _(by_slug["reverse-fly"][:allowed_weights]).must_equal [10.0, 20.0]
    _(by_slug["dead-bug"][:allowed_weights]).must_be_nil
  end

  it "does an exercise without a weight once no weight is remembered, whatever its step sets" do
    ExerciseWeight.remember!(exercise("goblet-squat"), nil)
    plan = plan_for("cycle-1-workout-1")
    squat = plan.items.first
    target = plan.targets.find { it[:exercise][:name] == "Goblet squat" }

    _(squat[:weight]).must_be_nil
    _(squat[:weight_unit]).must_equal "lb"
    _(squat[:seed_weight]).must_equal({ value: 40.0, unit: "lb" })
    _(target[:weight]).must_be_nil
  end

  it "keeps the stepper of a step whose only weight was the remembered one, once that is no weight" do
    workout = Workout.first!(example_slug: "cycle-1-workout-1")
    step = Step.where(block_id: workout.blocks_dataset.select(:id), exercise_id: exercise("dead-bug").id).first!
    ExerciseWeight.remember!(step.exercise, nil, "lb")
    dead_bug = PlayerPlan.new([Workout.expanded.first!(id: workout.id)]).items.find { it[:step_id] == step.id }

    _(dead_bug[:weight]).must_be_nil
    _(dead_bug[:weight_unit]).must_equal "lb"
  end

  it "keeps a step's weight in the unit of the gear it is done with when its exercise names none" do
    inventory("kettlebell").update(unit: "kg", weights: [16])
    workout = Workout.first!(example_slug: "cycle-1-workout-1")
    step = Step.where(block_id: workout.blocks_dataset.select(:id), exercise_id: exercise("dead-bug").id).first!
    step.update(equipment_pks: [Equipment.first!(slug: "kettlebell").id], weight_value: 16, weight_unit: "kg")
    dead_bug = PlayerPlan.new([Workout.expanded.first!(id: workout.id)]).items.find { it[:step_id] == step.id }

    _(dead_bug[:weight_unit]).must_equal "kg"
    _(dead_bug[:weight]).must_equal({ value: 16.0, unit: "kg" })
    _(dead_bug[:allowed_weights]).must_equal [16.0]
  end

  it "steps an exercise done with different gear through the weights of all of it on Get ready" do
    one = Workout.first!(example_slug: "cycle-1-workout-1")
    two = Workout.first!(example_slug: "cycle-1-workout-2")
    fly = exercise("reverse-fly")
    two.blocks.first.add_step(exercise: fly, position: 99, reps: 10, equipment_pks: [Equipment.first!(slug: "kettlebell").id])
    plan = PlayerPlan.new([Workout.expanded.first!(id: one.id), Workout.expanded.first!(id: two.id)])
    flies = plan.items.select { it[:exercise] && it[:exercise][:slug] == "reverse-fly" }
    target = plan.targets.select { it[:exercise][:id] == fly.id }

    _(flies.map { it[:allowed_weights] }.uniq).must_equal [[10.0, 20.0], [40.0]]
    _(target.size).must_equal 1
    _(target.first[:allowed_weights]).must_equal [10.0, 20.0, 40.0]
  end

  it "steps by band when the fixed-weight equipment is not owned" do
    inventory("dumbbell").update(owned: false)
    fly = plan_for("cycle-1-workout-1").items.find { it[:exercise] && it[:exercise][:slug] == "reverse-fly" }

    _(fly[:allowed_weights]).must_be_nil
  end

  it "lists the equipment once" do
    _(plan_for("cycle-1-workout-2").equipment).must_equal %w[kettlebell bench dumbbell weight stability_ball]
  end

  it "starts a home strength session with its own warm-up block and ends with the cool-down" do
    session = workout("home-strength-a")
    items = PlayerPlan.new(session.framed).items

    _(session.framed.map(&:kind)).must_equal %w[workout cooldown]
    _(items.first[:block][:label]).must_equal "Warm-up"
    _(items.last[:workout][:kind]).must_equal "cooldown"
  end
end
