# frozen_string_literal: true

module TrainerMcp
  class SetExerciseWeight < Tool
    description <<~TEXT.squish
      Set the weight remembered for an exercise. It applies to every workout that uses the exercise, from the next
      session on; reps and time are not remembered, they are set per workout step (update_workout). The weight is
      kept in the exercise's unit (`weight_unit` in get_exercise): one given in the other unit is converted and
      snapped to a weight the user owns, so give one of `allowed_weights` where there are any. The app suggests
      no weights: recommend one from the sets, RPE and feedback (training_summary), and set it
      when the user asks or agrees; say so in your answer. Every change is recorded with the `reason`, shown on Get
      ready until the exercise is next trained, and the user can change it back with one tap.
    TEXT
    input_schema(
      properties: {
        exercise: { type: %w[string integer], description: "The exercise's slug, or its id." },
        value: { type: "number",
                 description: "The weight; 0 for none: the exercise is then done without a weight, whatever its workout steps set." },
        unit: { type: "string", enum: ExerciseWeight::UNITS, description: "lb or kg; the exercise's unit when left out." },
        reason: { type: "string",
                  description: "Why, shown to the user with the change, such as \"You asked for heavier: RPE 6 on all sets last week\"." }
      },
      required: %w[exercise value]
    )
    annotations(title: "Set exercise weight", **WRITES, idempotent_hint: true)

    def self.answer(exercise:, value:, unit: nil, reason: nil)
      exercise = find_exercise(exercise)
      raise Problem, "#{exercise.slug} is retired from the library; pick another exercise" if exercise.retired

      remembered = PlanChange.because(reason) { ExerciseWeight.remember!(exercise, value, unit) }

      compact(
        exercise: exercise.slug, name: exercise.name,
        remembered_weight: remembered_weight(remembered, exercise.weight_unit),
        used_in: Workout.with_exercise(exercise).all.map { { id: it.id, title: it.title } }
      )
    end
  end
end
