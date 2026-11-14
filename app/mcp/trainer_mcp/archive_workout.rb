module TrainerMcp
  class ArchiveWorkout < Tool
    description <<~TEXT.squish
      Archive a workout of the user's or yours that is no longer wanted. It leaves list_workouts, and its sessions
      planned from today on are taken off the calendar (`removed_sessions`); past sessions, missed ones included,
      keep it and read as archived. A warm-up or cool-down also leaves the main workouts that pick it
      (`reframed_workouts`), which then run without one; it can't be archived while a session runs it. There is
      no undo through this server, so check with the user before archiving one of theirs.
    TEXT
    input_schema(
      properties: { workout_id: { type: "integer", description: "The workout's id, from list_workouts." } },
      required: %w[workout_id]
    )
    annotations(title: "Archive workout", **REPLACES, idempotent_hint: true)

    def self.answer(workout_id:)
      workout = editable_workout(workout_id)
      reframed = workout.picked_by.map { { id: it.id, title: it.title } }
      removed = workout.archive!
      {
        id: workout.id, title: workout.title, archived: true,
        removed_sessions: removed.map { { id: it.id, date: it.date.iso8601 } },
        reframed_workouts: reframed
      }
    end
  end
end
