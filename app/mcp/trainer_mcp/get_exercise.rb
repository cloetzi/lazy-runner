# frozen_string_literal: true

module TrainerMcp
  class GetExercise < Tool
    description <<~TEXT.squish
      One exercise from the library, by slug or id: its cues, step-by-step instructions, common
      mistakes and the equipment it needs, with its weight. The weight is remembered per exercise:
      changing it applies to every workout that uses the exercise, while reps and time are set per
      workout step. `remembered_weight` is that weight (absent while workouts still use their own step
      weight; 0 when the user does it without one), in `weight_unit`; `allowed_weights` are the owned weights it can step through
      (fixed-weight equipment only). `used_in` lists the workouts with the exercise.
    TEXT
    input_schema(
      properties: { exercise: { type: %w[string integer], description: "The exercise's slug, or its id." } },
      required: ["exercise"]
    )
    annotations(title: "Get exercise", **READ_ONLY)

    def self.answer(exercise:)
      exercise = find_exercise(exercise)
      unit = exercise.weight_unit

      compact(
        exercise.as_json.except(:animation).merge(
          retired: (true if exercise.retired),
          weight_unit: unit,
          remembered_weight: remembered_weight(exercise.remembered, unit),
          allowed_weights: Equipment.allowed_for(exercise.equipment_slugs, unit),
          used_in: Workout.with_exercise(exercise).all.map { { id: it.id, title: it.title, kind: it.kind, source: it.source } }
        )
      )
    end
  end
end
