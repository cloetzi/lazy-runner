module TrainerMcp
  class MoveSession < SessionTool
    description <<~TEXT.squish
      Move a planned or missed session to another day from today on (last there unless `position` says otherwise),
      or to another place on its day, or change its note. Works on sessions the user planned too; say so in your
      answer when you move one of theirs. Sessions started, skipped or done can't be moved. A missed session moved to
      today or later is planned again. #{CALENDAR} Answers with the session and the days it left and joined.
    TEXT
    input_schema(
      properties: {
        session_id: { type: "integer", description: "The session, from list_sessions." },
        date: { type: "string", description: "Its new day, YYYY-MM-DD, today or later." },
        position: { type: "integer", minimum: 1, description: "Its place on the day, 1 first." },
        note: { type: %w[string null], description: "Replaces its note; empty or null clears it. On a session you planned, keep what the note says it is for and add why it moved, rather than writing a coach note; leave the note of one the user planned as it is." }
      },
      required: %w[session_id]
    )
    annotations(title: "Move session", **WRITES, idempotent_hint: true)

    def self.answer(session_id:, **changes)
      raise Problem, "nothing to change: give a date, position or note" if changes.empty?

      session = find_session(session_id)
      from = session.date
      changes[:note] = changes[:note].presence if changes.key?(:note)
      session.move!(**changes)
      days = [from, session.date].uniq.sort.to_h { [it.iso8601, day(it)] }
      { session: shown(session), days: }
    end
  end
end
