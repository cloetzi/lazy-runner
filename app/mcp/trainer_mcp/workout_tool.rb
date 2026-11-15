module TrainerMcp
  # What the tools that write workouts share: the schema of a workout's
  # fields and of its whole structure, as WorkoutStructure reads it, and the
  # answer, the workout as get_workout gives it.
  class WorkoutTool < Tool
    STEP = {
      type: "object",
      description: "One exercise. Exactly one of reps or duration_seconds (or neither, with only a note saying what to do).",
      properties: {
        id: { type: "integer", description: "A step of this workout to keep, from get_workout: the sets logged against it keep their link. Leave it out for a new step." },
        exercise: {
          type: %w[string integer object],
          description: "The exercise's slug from search_exercises (or its id). The { id, slug, name } get_workout gives works too."
        },
        reps: { type: %w[integer null], minimum: 1, maximum: Step::MAX_REPS, description: "Reps per set: per side when the exercise is done one side at a time (unilateral), both sides together when it alternates sides (alternating: 10 is 5 a side)." },
        duration_seconds: { type: %w[integer null], minimum: 1, maximum: Step::MAX_SECONDS, description: "Seconds per set, instead of reps." },
        tempo: { type: %w[string null], description: "Seconds per phase, 3 or 4 digits such as \"3110\" (down, pause, up, pause)." },
        weight: {
          type: %w[number object null],
          description: "The weight to start at while the exercise has no remembered weight; once it has one, that wins " \
                       "(set_exercise_weight). Either a number in the unit of the gear the step is done with, such as 20, or an object with " \
                       "its value, such as {\"value\": 20, \"unit\": \"lb\"}. Leave it out for none: a step sent " \
                       "without one has none. Use a weight the user owns for the gear the step is done with.",
          properties: { value: { type: "number", minimum: 0 }, unit: { type: "string", enum: ExerciseWeight::UNITS } },
          required: ["value"]
        },
        weights_held: { type: %w[integer null], description: "1 or 2, when done with other equipment than the exercise names." },
        note: { type: %w[string null], maxLength: Step::MAX_NOTE, description: "A short cue shown with the step." },
        equipment: {
          type: %w[array null], items: { type: "string" },
          description: "Equipment slugs from list_equipment, only when done with other gear than the exercise needs (such as " \
                       "a straight-leg deadlift with the kettlebell rather than dumbbells). A step can't drop the gear its exercise needs: for " \
                       "bodyweight, pick an exercise that needs none, or leave the weight out and say so in the note."
        }
      }
    }.freeze

    BLOCK = {
      type: "object",
      description: "Steps run in order, for a number of rounds.",
      properties: {
        id: { type: "integer", description: "A block of this workout to keep, from get_workout. Leave it out for a new block." },
        label: { type: "string", maxLength: Block::MAX_LABEL, description: "Its name, unique in the workout, such as \"Main\" or \"Core finisher\"." },
        rounds: { type: "integer", minimum: 1, maximum: Block::MAX_ROUNDS, description: "How many times the steps run; 1 when left out." },
        rest_seconds: { type: "integer", minimum: 0, maximum: Block::MAX_REST_SECONDS, description: "Rest after each round but the last; 0 when left out." },
        steps: { type: "array", items: STEP, minItems: 1, maxItems: WorkoutStructure::MAX_STEPS }
      },
      required: %w[label steps]
    }.freeze

    BLOCKS = {
      type: "array", items: BLOCK, minItems: 1, maxItems: WorkoutStructure::MAX_BLOCKS,
      description: "The whole structure, in order. It replaces what is there: blocks and steps left out are deleted " \
                   "(the sets logged against them stay in the history). Each step is sent whole: what it leaves out (weight, " \
                   "tempo, note, equipment) it doesn't have. get_workout's blocks can be sent back as they are, " \
                   "changed where needed; what only get_workout gives (position, target, ...) is ignored."
    }.freeze

    FRAME = {
      type: %w[integer string null],
      description: "For a main workout: the id of a warm-up (or cool-down) from list_workouts, or \"none\"."
    }.freeze

    FIELDS = {
      title: { type: "string", maxLength: Workout::MAX_LENGTHS[:title], description: "Its name, as the user sees it." },
      subtitle: { type: %w[string null], maxLength: Workout::MAX_LENGTHS[:subtitle], description: "A line on what it is for." },
      warmup: FRAME,
      cooldown: FRAME
    }.freeze

    # What a write tool says about the structure, besides the schema.
    RULES = <<~TEXT.squish
      All or nothing: when anything is wrong, nothing is written and the error names each block and step at fault
      (counted from 1) and what to change. Weights belong to the exercise, reps and time to the step: a step's reps,
      seconds and tempo are its own, while the weight a session uses is the exercise's remembered weight, shared by
      every workout with it. Sessions planned with the workout run it as it is when they start, so a change applies to
      every future session of it. The answer's `warnings`, when there are any, name steps that were saved but need a
      look: a weight the user doesn't own for the step's gear, or gear they don't own.
    TEXT

    # The workout as get_workout gives it, with `warnings` for what was saved
    # but won't run as written.
    def self.answered(id)
      workout = Workout.expanded.find!(id)
      shown = GetWorkout.shown(id, workout)
      warnings = warnings(workout)
      warnings.any? ? shown.merge(warnings:) : shown
    end

    # Steps done with gear the user doesn't own, or with a weight (the
    # remembered one, else the step's) that isn't one they own for the step's
    # gear, naming an owned item that has it, such as the kettlebell for a
    # 40 lb goblet squat.
    def self.warnings(workout)
      owned = Equipment.owned.select_map(:slug)
      generic = Equipment.current.where(any_weight: true).select_map(:slug)
      fixed = Equipment.fixed
      remembered = ExerciseWeight.where(exercise_id: workout.blocks.flat_map { it.steps.map(&:exercise_id) }).all.index_by(&:exercise_id)
      workout.blocks.each_with_index.flat_map do |block, b|
        block.steps.each_with_index.flat_map do |step, s|
          where = "Block #{b + 1} (#{block.label}), step #{s + 1} (#{step.exercise.slug})"
          missing = step.equipment_needed - owned
          [
            ("#{where}: needs #{missing.join(", ")}, which the user doesn't own: pick an exercise without it, or update_equipment once they say they have it#{" (weight is any dumbbell or kettlebell)" if missing.intersect?(generic)}" if missing.any?),
            weight_warning(step, remembered[step.exercise_id], fixed, where)
          ].compact
        end
      end
    end

    def self.weight_warning(step, remembered, fixed, where)
      weight = step.target(remembered)[:weight]
      return unless weight && weight[:value].positive?

      allowed = step.allowed_weights(fixed) or return
      unit = weight[:unit]
      value = weight[:value]
      return if allowed.any? { Weights.same?({ value: it, unit: }, weight) }

      gear = step.equipment_needed.find { fixed.key?(it) }
      other = Equipment.carrying(weight, fixed, except: gear)
      change = remembered ? "it is the exercise's remembered weight, which wins over a step's: set_exercise_weight changes it once the user agrees" : "give one of those"
      hint = other ? "give equipment [\"#{other}\"] if it is done with that, or #{change}" : change
      gear = "any weight" if fixed[gear].is_a?(Equipment::AnyWeight)
      "#{where}: #{format_weight(value)} #{unit} is not a weight the user owns for #{gear} (#{allowed.map { format_weight(it) }.join(", ")} #{unit}); #{hint}"
    end

    def self.format_weight(value) = value % 1 == 0 ? value.to_i.to_s : value.to_s

    # The workout fields and structure among `arguments`, as Workout#revise! takes them.
    def self.changes(arguments)
      arguments.slice(*FIELDS.keys, :blocks).transform_keys(&:to_s)
    end
  end
end
