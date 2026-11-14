module TrainerMcp
  class DeleteCoachNotes < CoachTool
    description <<~TEXT.squish
      Delete notes you (an agent) wrote, up to 100 at once: duplicates, and ones gone stale. All or nothing: when one
      isn't found or isn't yours, nothing is deleted. Deleting the current status or focus brings back the one before.
      The person's notes are theirs to delete. Tell the user what you deleted.
    TEXT
    input_schema(
      properties: {
        note_ids: {
          type: "array", items: { type: "integer" }, minItems: 1, maxItems: CoachNote::PAGE_LIMIT, uniqueItems: true,
          description: "The notes, from list_coach_notes."
        }
      },
      required: %w[note_ids]
    )
    annotations(title: "Delete coach notes", **REPLACES)

    def self.answer(note_ids:)
      CoachNote.db.transaction do
        found = CoachNote.where(id: note_ids).select_hash(:id, :author_kind)
        missing = note_ids - found.keys
        raise Problem, "no notes #{missing.join(", ")} (deleted already, or never there); list_coach_notes lists them. Nothing was deleted" if missing.any?

        theirs = found.reject { |_, author| author == "llm" }.keys.sort
        raise Problem, "notes #{theirs.join(", ")} are the person's; leave them out. Nothing was deleted" if theirs.any?

        CoachNote.where(id: note_ids).delete
        { deleted: note_ids.sort, count: note_ids.size }
      end
    end
  end
end
