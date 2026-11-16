# frozen_string_literal: true

module TrainerMcp
  class DeleteCoachNotes < CoachTool
    description <<~TEXT.squish
      Delete notes you (an agent) wrote, up to 100 at once: duplicates, and ones gone stale. All or nothing: when one
      isn't found or isn't yours, nothing is deleted. Deleting the current status or focus brings back the one before.
      The person's notes are theirs to delete, and so is a note of yours they replied to (its `replies`): update it instead. Tell the user what you deleted.
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
        if missing.any?
          raise Problem,
                "no notes #{missing.join(", ")} (deleted already, or never there); list_coach_notes lists them. Nothing was deleted"
        end

        theirs = found.reject { |_, author| author == "llm" }.keys.sort
        raise Problem, "notes #{theirs.join(", ")} are the person's; leave them out. Nothing was deleted" if theirs.any?

        answered = CoachNote.where(reply_to_id: note_ids).select_order_map(:reply_to_id).uniq
        raise Problem, "notes #{answered.join(", ")} have the person's replies; update them instead. Nothing was deleted" if answered.any?

        CoachNote.where(id: note_ids).delete
        { deleted: note_ids.sort, count: note_ids.size }
      end
    end
  end
end
