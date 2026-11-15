# Flattens workouts into the ordered list of screens the player walks through.
#
# Blocks are circuits: each round runs every step in order, per-side steps run
# left then right, and the block's rest follows every round except the last.
# Targets are resolved: a remembered weight wins over the seed value, in the
# exercise's unit, and items that take a weight (`weight_unit`), set or not,
# carry the owned weights to step through.
class PlayerPlan
  def initialize(workouts, weights: ExerciseWeight.as_hash(:exercise_id), suggestions: WeightSuggestion.pending.as_hash(:exercise_id), fixed: Equipment.fixed)
    @workouts = workouts
    @weights = weights
    @suggestions = suggestions
    @fixed = fixed
  end

  def items
    @workouts.flat_map { |workout| workout_items(workout) }
  end

  def equipment
    @workouts.flat_map(&:blocks).flat_map(&:steps).flat_map(&:equipment_needed).uniq
  end

  # One line per exercise that takes a weight, for the get-ready screen:
  # those with one, and those done with gear in set weights that have none yet.
  # The weight is one per exercise (ExerciseWeight), so an exercise done with
  # different gear in different steps steps through the owned weights of all
  # of it (those in the first step's unit).
  def targets
    weighted = items.select { it[:type] == "exercise" && it[:weight_unit] }
    weighted.group_by { it[:exercise][:id] }.map do |_, same|
      item = same.first
      lists = same.select { it[:weight_unit] == item[:weight_unit] }.filter_map { it[:allowed_weights] }
      allowed = lists.flatten.uniq.sort unless lists.empty?
      item.slice(:weight, :weight_unit, :weights_held, :weight_equipment, :any_weight, :seed_weight, :suggestion, :equipment)
          .merge(allowed_weights: allowed, exercise: item[:exercise].slice(:id, :name))
    end
  end

  def as_json(*)
    { equipment:, targets:, items: }
  end

  private

  def workout_items(workout)
    workout.blocks.flat_map do |block|
      (1..block.rounds).flat_map do |round|
        work = block.steps.flat_map { |step| step_items(workout, block, step, round) }
        rest = round < block.rounds && block.rest_seconds.positive? ? [rest_item(workout, block, round)] : []
        work + rest
      end
    end
  end

  def step_items(workout, block, step, round)
    sides = step.per_side ? %w[left right] : [nil]
    target = step.target(@weights[step.exercise_id])
    unit = step.target_unit(target[:weight], @weights[step.exercise_id])
    sides.map do |side|
      {
        type: "exercise",
        mode: step.timed? ? "timed" : "reps",
        **place(workout, block, round),
        step_id: step.id,
        side:,
        reps: target[:reps],
        seconds: target[:seconds],
        tempo: step.tempo,
        weight: target[:weight],
        weight_unit: unit,
        weights_held: (step.held if unit),
        weight_equipment: (weight_equipment(step, target[:weight]) if unit),
        allowed_weights: (step.allowed_weights(@fixed) if unit),
        any_weight: (any_weight(step) if unit),
        seed_weight: step.weight,
        suggestion: @suggestions[step.exercise_id]&.as_json,
        note: step.note,
        equipment: step.equipment_needed,
        exercise: step.exercise.as_json.slice(:id, :slug, :name, :category, :alternating, :cues, :mistakes, :instructions, :animation)
      }
    end
  end

  # The equipment that carries a step's weight: the one with owned weights,
  # else the first that comes in set weights, else the first it needs. For
  # the generic weight, the owned item that has the target weight, so the
  # player names the gear to pick up.
  def weight_equipment(step, weight = nil)
    needed = step.equipment_needed
    slug = needed.find { @fixed.key?(it) } || step.set_weight_gear&.slug || needed.first
    return slug unless @fixed[slug].is_a?(Equipment::AnyWeight) && weight

    Equipment.carrying(weight, @fixed) || slug
  end

  # Once per step, however many rounds and sides it has.
  def any_weight(step)
    (@any_weight ||= {}).fetch(step.id) { @any_weight[step.id] = step.any_weight(@fixed) }
  end

  def rest_item(workout, block, round)
    {
      type: "rest",
      mode: "timed",
      **place(workout, block, round),
      seconds: block.rest_seconds
    }
  end

  def place(workout, block, round)
    { workout: { id: workout.id, kind: workout.kind, title: workout.title }, block: { label: block.label, round:, rounds: block.rounds } }
  end
end
