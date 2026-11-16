# frozen_string_literal: true

module TrainerMcp
  class UpdateWorkout < WorkoutTool
    description <<~TEXT.squish
      Change a workout of the user's or yours: its title, subtitle, warm-up or cool-down, and with `blocks` its whole
      structure, which replaces what is there. Fields left out are kept. Name the ids get_workout gives to keep a
      block or step (the sets logged against a step keep their link); a step given another exercise becomes a new
      step. Archived workouts can't change. While a
      session of the workout is under way, its structure, warm-up and cool-down can't change. Every edit is recorded
      with who made it, what changed and the `reason`, shown to the user on the workout and its next session, and they
      can change it back with one tap. #{RULES} Answers with
      the workout as get_workout gives it.
    TEXT
    input_schema(
      properties: {
        workout_id: { type: "integer", description: "The workout's id, from list_workouts." },
        **FIELDS,
        blocks: BLOCKS,
        reason: { type: "string",
                  description: "Why, shown to the user with the change, such as \"One more round in block B: the last two weeks felt " \
                               "easy\". Required for a workout the user made (`source: user`)." }
      },
      required: %w[workout_id]
    )
    annotations(title: "Update workout", **REPLACES, idempotent_hint: true)

    def self.answer(workout_id:, reason: nil, **fields)
      raise Problem, "nothing to change: give a title, subtitle, warmup, cooldown or blocks" if fields.empty?

      workout = editable_workout(workout_id)
      workout_reason!(workout, reason, "edit")
      PlanChange.because(reason) { workout.revise!(changes(fields)) }
      answered(workout_id)
    end
  end
end
