module TrainerMcp
  class UpdateWorkout < WorkoutTool
    description <<~TEXT.squish
      Change a workout of the user's or yours: its title, subtitle, warm-up or cool-down, and with `blocks` its whole
      structure, which replaces what is there. Fields left out are kept. Name the ids get_workout gives to keep a
      block or step (the sets logged against a step keep their link); a step given another exercise becomes a new
      step. Archived workouts can't change. While a
      session of the workout is under way, its structure, warm-up and cool-down can't change. #{RULES} Answers with
      the workout as get_workout gives it.
    TEXT
    input_schema(
      properties: {
        workout_id: { type: "integer", description: "The workout's id, from list_workouts." },
        **FIELDS,
        blocks: BLOCKS
      },
      required: %w[workout_id]
    )
    annotations(title: "Update workout", **REPLACES, idempotent_hint: true)

    def self.answer(workout_id:, **fields)
      raise Problem, "nothing to change: give a title, subtitle, warmup, cooldown or blocks" if fields.empty?

      editable_workout(workout_id).revise!(changes(fields))
      answered(workout_id)
    end
  end
end
