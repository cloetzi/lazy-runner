module TrainerMcp
  class EndRoutine < RoutineTool
    description <<~TEXT.squish
      Stop a routine you planned (`created_by: llm`) from today on; the user's own are theirs to end. One with days
      before today ends yesterday and keeps them; one without is deleted. Its days from today on go, and sessions
      the user confirmed for them come off the calendar: say so when that happens.
    TEXT
    input_schema(
      properties: { routine_id: { type: "integer", description: "The routine, from list_routines." } },
      required: %w[routine_id]
    )
    annotations(title: "End a routine", **REPLACES)

    def self.answer(routine_id:)
      routine = own_routine(routine_id)
      outcome = routine.end!
      { id: routine.id, outcome:, ends_on: (routine.ends_on.iso8601 if outcome == :ended) }.compact
    end
  end
end
