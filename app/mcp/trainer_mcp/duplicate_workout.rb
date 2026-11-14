module TrainerMcp
  class DuplicateWorkout < Tool
    description <<~TEXT.squish
      Copy a workout into one of yours (`source: llm`) under "My workouts", with the same blocks, steps,
      warm-up and cool-down: a variation to plan for one day, or a start for a new one. The original stays
      as it is. Answers with the copy as get_workout gives it.
    TEXT
    input_schema(
      properties: {
        workout_id: { type: "integer", description: "The workout to copy, from list_workouts." },
        title: { type: "string", maxLength: Workout::MAX_LENGTHS[:title], description: "The copy's name; \"<title> (copy)\" when left out." }
      },
      required: %w[workout_id]
    )
    annotations(title: "Duplicate workout", **WRITES)

    def self.answer(workout_id:, title: nil)
      copy = find_workout(workout_id).duplicate!(title:, source: "llm")
      GetWorkout.shown(copy.id)
    end
  end
end
