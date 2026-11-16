# frozen_string_literal: true

module TrainerMcp
  class RemoveSession < SessionTool
    description <<~TEXT.squish
      Take a planned or missed session off the calendar, the user's included: give a `reason` (required for theirs),
      and say so in your answer. The removal is recorded with who made it and the reason, and the user can put it
      back. Sessions started, skipped or done are history and can't be removed, and skipping is the user's
      to do. An empty day is a rest day, so a day emptied needs nothing else. Answers with what was removed and what
      is left on its day.
    TEXT
    input_schema(
      properties: {
        session_id: { type: "integer", description: "The session, from list_sessions." },
        reason: { type: "string", description: "Why it goes, shown to the user with the change. Required for a session the user planned." }
      },
      required: %w[session_id]
    )
    annotations(title: "Remove session", **REPLACES)

    def self.answer(session_id:, reason: nil)
      session = find_session(session_id)
      reason!(session, reason, "removal")
      removed = shown(session)
      PlanChange.because(reason) { session.remove! }
      { removed:, day: day(session.date) }
    end
  end
end
