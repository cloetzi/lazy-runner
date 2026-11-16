# frozen_string_literal: true

module TrainerMcp
  class UpdateRoutine < RoutineTool
    description <<~TEXT.squish
      Change a routine you planned (`created_by: llm`); the user's own are theirs to change. Fields left out stay;
      null clears one. Days gone by never change: changing when one with days before today runs (weekdays, sport,
      workout, start) ends it yesterday and starts a new routine today, which is what this answers with. The
      user's confirmed and moved days from today on carry over while they are still among its days; tell the user
      when one doesn't. #{RULES}
    TEXT
    input_schema(
      properties: {
        routine_id: { type: "integer", description: "The routine, from list_routines." },
        sport: { type: %w[string null], description: "The sport, for a sport routine; null when it becomes a workout routine." },
        workout_id: { type: %w[integer null], description: "The workout, for a workout routine; null when it becomes a sport routine." },
        **FIELDS,
        reason: { type: "string", description: "Why it changes, shown to the user with the change." }
      },
      required: %w[routine_id]
    )
    annotations(title: "Change a routine", **REPLACES)

    def self.answer(routine_id:, reason: nil, **arguments)
      routine = own_routine(routine_id)
      revised = PlanChange.because(reason) { routine.revise!(attributes(arguments)) }
      { routine: shown(revised), ended: (shown(routine.refresh) if revised.id != routine.id) }.compact
    end
  end
end
