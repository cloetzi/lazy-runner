module TrainerMcp
  class UpdateCoachNote < CoachTool
    description <<~TEXT.squish
      Change a note you (an agent) wrote: its title, body, the day it is about, or the activity or session (null takes
      one off). Use it to correct or add to a note rather than writing it again; a status or focus stays where it is
      on the board. A note the person (or a coach they named) wrote is theirs: write a note of your own instead.
    TEXT
    input_schema(
      properties: {
        note_id: { type: "integer", description: "The note, from list_coach_notes or get_coach_board." },
        title: { type: "string", description: "A short headline; a concern needs one." },
        body: { type: "string", description: "The note, a few plain sentences." },
        date: { type: %w[string null], format: "date", description: "The day it is about, YYYY-MM-DD." },
        activity_id: { type: %w[integer null], description: "The activity it is about." },
        session_id: { type: %w[integer null], description: "The session it is about, from list_sessions." }
      },
      required: %w[note_id]
    )
    annotations(title: "Update coach note", **REPLACES, idempotent_hint: true)

    def self.answer(note_id:, **fields)
      raise Problem, "nothing to change: send title, body, date, activity_id or session_id" if fields.empty?

      note(agents_note(note_id).tap { it.update(fields) })
    end
  end
end
