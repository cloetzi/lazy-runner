# frozen_string_literal: true

module TrainerMcp
  class MoveSession < SessionTool
    description <<~TEXT.squish
      Move a planned or missed session to another day from today on (last there unless `position` says otherwise),
      or to another place on its day, or change the note of one you planned. Works on sessions the user planned
      too: give a `reason` (required for theirs), and say so in your answer. Their note stays as it is. Every move is
      recorded with who made it and the reason, and the user can take it back. Sessions started,
      skipped or done can't be moved. A missed session moved to today or later is planned again. #{CALENDAR}
      Answers with the session and the days it left and joined.
    TEXT
    input_schema(
      properties: {
        session_id: { type: "integer", description: "The session, from list_sessions." },
        date: { type: "string", description: "Its new day, YYYY-MM-DD, today or later." },
        position: { type: "integer", minimum: 1, description: "Its place on the day, 1 first." },
        reason: { type: "string",
                  description: "Why it moves, shown to the user with the change, such as \"Legs fresh for Sunday's long run\". " \
                               "Required for a session the user planned." },
        note: { type: %w[string null],
                description: "Replaces its note; empty or null clears it. Only for a session you planned (`created_by: llm`): the note " \
                             "says what it is for, the reason why it moved." }
      },
      required: %w[session_id]
    )
    annotations(title: "Move session", **WRITES, idempotent_hint: true)

    def self.answer(session_id:, reason: nil, **changes)
      raise Problem, "nothing to change: give a date, position or note" if changes.empty?

      session = find_session(session_id)
      if changes.key?(:note) && session.created_by != "llm" && session.status == "planned"
        raise Problem, "session #{session_id} is the user's: their note stays as it is; give the reason for the move in `reason`"
      end

      reason!(session, reason, "move", date: changes[:date])
      from = session.date
      changes[:note] = changes[:note].presence if changes.key?(:note)
      PlanChange.because(reason) { session.move!(**changes) }
      days = [from, session.date].uniq.sort.to_h { [it.iso8601, day(it)] }
      { session: shown(session), days: }
    end
  end
end
