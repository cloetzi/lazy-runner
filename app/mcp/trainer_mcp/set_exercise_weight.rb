module TrainerMcp
  class SetExerciseWeight < Tool
    description <<~TEXT.squish
      Set the weight remembered for an exercise. It applies to every workout that uses the exercise, from the next
      session on; reps and time are not remembered, they are set per workout step (update_workout). The weight is
      kept in the exercise's unit (`weight_unit` in get_exercise): one given in the other unit is converted and
      snapped to a weight the user owns, so give one of `allowed_weights` where there are any. A pending suggestion
      for the exercise is answered by it: accepted when this is the suggested weight, else dismissed. Change a
      weight when the user asks or agrees, or when the history clearly calls for it, and say so in your answer.
    TEXT
    input_schema(
      properties: {
        exercise: { type: %w[string integer], description: "The exercise's slug, or its id." },
        value: { type: "number", description: "The weight; 0 for none: the exercise is then done without a weight, whatever its workout steps set." },
        unit: { type: "string", enum: ExerciseWeight::UNITS, description: "lb or kg; the exercise's unit when left out." }
      },
      required: %w[exercise value]
    )
    annotations(title: "Set exercise weight", **WRITES, idempotent_hint: true)

    def self.answer(exercise:, value:, unit: nil)
      exercise = find_exercise(exercise)
      raise Problem, "#{exercise.slug} is retired from the library; pick another exercise" if exercise.retired

      pending = WeightSuggestion.pending.where(exercise_id: exercise.id).all
      remembered = ExerciseWeight.remember!(exercise, value, unit)

      compact(
        exercise: exercise.slug, name: exercise.name,
        remembered_weight: remembered_weight(remembered, exercise.weight_unit),
        suggestion: pending.first&.refresh&.then { { direction: it.direction, value: it.value.to_f, unit: it.unit, status: it.status } },
        used_in: Workout.with_exercise(exercise).all.map { { id: it.id, title: it.title } }
      )
    end
  end
end
