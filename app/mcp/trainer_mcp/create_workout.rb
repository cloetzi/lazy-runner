module TrainerMcp
  class CreateWorkout < WorkoutTool
    description <<~TEXT.squish
      Build a new workout from library exercises, with its whole structure: blocks of steps, each step one exercise
      by slug with its reps or seconds. It is yours (`source: llm`), stands on its own under "My workouts" and can
      be changed later with update_workout. A main workout (kind workout) runs framed by the warm-up and cool-down
      it names; without them it runs on its own. #{RULES} Answers with the workout as get_workout gives it, with
      the ids to name when changing it.
    TEXT
    input_schema(
      properties: {
        kind: { type: "string", enum: Workout::KINDS, description: "warmup, workout (a main workout) or cooldown." },
        **FIELDS,
        blocks: BLOCKS
      },
      required: %w[kind title blocks]
    )
    annotations(title: "Create workout", **WRITES)

    def self.answer(kind:, blocks:, **fields)
      workout = Workout.create_with!(changes(fields).merge("kind" => kind, "blocks" => blocks), source: "llm")
      answered(workout.id)
    end
  end
end
