module TrainerMcp
  class ArchiveWorkout < Tool
    description <<~TEXT.squish
      Archive a workout of the user's or yours that is no longer wanted. It leaves list_workouts, and its sessions
      planned from today on are taken off the calendar (`removed_sessions`); past sessions, missed ones included,
      keep it and read as archived. A warm-up or cool-down also leaves the main workouts that pick it
      (`reframed_workouts`), which then run without one; it can't be archived while a session runs it. There is
      no undo through this server, so check with the user before archiving one of theirs, and give a `reason`.
    TEXT
    input_schema(
      properties: {
        workout_id: { type: "integer", description: "The workout's id, from list_workouts." },
        reason: { type: "string", description: "Why, shown to the user with the change, such as \"Replaced by Strength B, as agreed\". Required for a workout the user made (`source: user`)." }
      },
      required: %w[workout_id]
    )
    annotations(title: "Archive workout", **REPLACES, idempotent_hint: true)

    def self.answer(workout_id:, reason: nil)
      workout = editable_workout(workout_id)
      workout_reason!(workout, reason, "archive")
      reframed = workout.picked_by.map { { id: it.id, title: it.title } }
      removed = PlanChange.because(reason) { workout.archive! }
      {
        id: workout.id, title: workout.title, archived: true,
        removed_sessions: removed.map { { id: it.id, date: it.date.iso8601 } },
        reframed_workouts: reframed
      }
    end
  end
end
