module TrainerMcp
  class ResolveConcern < CoachTool
    description <<~TEXT.squish
      Resolve an open concern you (an agent) raised, saying how it was resolved. A concern the person or their coach
      raised is theirs to resolve: write a note about it instead.
    TEXT
    input_schema(
      properties: {
        note_id: { type: "integer", description: "The concern, from get_coach_board." },
        resolution: { type: "string", description: "How it was resolved." }
      },
      required: %w[note_id resolution]
    )
    annotations(title: "Resolve concern", **WRITES, idempotent_hint: true)

    def self.answer(note_id:, resolution:)
      concern = CoachNote.with_pk(note_id) || raise(Problem, "no note #{note_id}; get_coach_board lists the concerns")
      raise Problem, "note #{note_id} is a #{concern.kind}, not a concern" unless concern.concern?
      raise Problem, "concern #{note_id} is the person's to resolve; write a note about it instead" unless concern.author_kind == "llm"
      raise Problem, "concern #{note_id} is already resolved" if concern.resolved?

      note(concern.resolve!(resolution))
    end
  end
end
