module TrainerMcp
  class RemoveSession < SessionTool
    description <<~TEXT.squish
      Take a planned or missed session off the calendar, the user's included; say so in your answer when you remove
      one of theirs. Sessions started, skipped or done are history and can't be removed, and skipping is the user's
      to do. An empty day is a rest day, so a day emptied needs nothing else. Answers with what was removed and what
      is left on its day.
    TEXT
    input_schema(
      properties: { session_id: { type: "integer", description: "The session, from list_sessions." } },
      required: %w[session_id]
    )
    annotations(title: "Remove session", **REPLACES)

    def self.answer(session_id:)
      session = find_session(session_id)
      removed = shown(session)
      session.remove!
      { removed:, day: day(session.date) }
    end
  end
end
