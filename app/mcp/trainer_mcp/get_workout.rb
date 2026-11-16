# frozen_string_literal: true

module TrainerMcp
  class GetWorkout < Tool
    description <<~TEXT.squish
      One workout with its blocks and steps. A block runs its steps in order for `rounds` rounds,
      with `rest_seconds` between rounds. A step is one exercise with reps or seconds (set per
      step), tempo (seconds per phase), whether it is done per side, `equipment` when it is done
      with other gear than its exercise needs, and its `target`: the reps or seconds and the weight
      to use. The weight comes from the exercise's remembered weight when there is one, so
      changing an exercise's weight applies to every workout that uses it, while reps and time are
      set per workout step. The blocks can be sent back to update_workout, changed where needed. `allowed_weights` are the owned weights a step can
      use. `framed` is what a session of it runs: its
      warm-up, the workout and its cool-down. `editable` is false for archived workouts.
    TEXT
    input_schema(
      properties: { workout_id: { type: "integer", description: "The workout's id, from list_workouts." } },
      required: ["workout_id"]
    )
    annotations(title: "Get workout", **READ_ONLY)

    def self.answer(workout_id:)
      shown(find_workout(workout_id).id)
    end

    # The workout as this tool gives it, which the write tools answer with too.
    def self.shown(id, workout = Workout.expanded.find!(id))
      detail = workout.detail.except(:plan, :weight_steps)
      detail[:blocks] = detail[:blocks].map do |block|
        block.merge(steps: block[:steps].map { step(it) })
      end
      compact(detail)
    end

    # A step with its exercise named, and `equipment` only when it is done
    # with other gear than the exercise needs (as Step#as_json gives it), so
    # that sending it back to update_workout keeps it as it is, even with
    # another exercise.
    def self.step(step)
      step.except(:equipment_needed, :weight_unit).merge(exercise: step[:exercise].slice(:id, :slug, :name, :alternating, :equipment))
    end
  end
end
