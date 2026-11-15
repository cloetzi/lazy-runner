module TrainerMcp
  class ListCoachNotes < CoachTool
    description <<~TEXT.squish
      Every note on the user's Coach tab, newest first: statuses, focus, concerns (open or resolved) and journal notes,
      each saying who wrote it (`user` the person, `human` a coach they named, `llm` you or another agent).
      get_coach_board shows only the latest; this is how to find a note to update_coach_note or delete_coach_notes.
      `author: llm` keeps yours. With `from` or `to`, only notes on a day in that range (about a session or activity on it, else dated to it): with only `from` 28 days on, with only `to` 28 days back, at most 366 days. `count` is how many match;
      pass `before` from the answer for the next page.
    TEXT
    input_schema(
      properties: {
        kind: { type: "string", enum: CoachNote::KINDS },
        author: { type: "string", enum: CoachNote::AUTHORS, description: "Who wrote it; llm for yours." },
        from: { type: "string", format: "date", description: "First day the notes are about, YYYY-MM-DD." },
        to: { type: "string", format: "date", description: "Last day the notes are about, YYYY-MM-DD." },
        before: { type: "integer", description: "Only notes older than this id, from a previous answer." },
        limit: { type: "integer", minimum: 1, maximum: CoachNote::PAGE_LIMIT, description: "How many, 50 unless given." }
      }
    )
    annotations(title: "List coach notes", **READ_ONLY)

    def self.answer(kind: nil, author: nil, from: nil, to: nil, before: nil, limit: 50)
      notes = CoachNote.eager(:activity, session: :workout)
      notes = notes.of_kind(kind) if kind
      notes = notes.by(author) if author
      notes = notes.on_days(days(from, to)) if from || to
      count = notes.count
      notes = notes.where { id < before } if before
      page = notes.newest_first.limit(limit + 1).all
      more = page.size > limit
      page = page.first(limit)

      compact(**today_and_weekday, count:, notes: page.map { note(it) }, before: (page.last.id if more))
    end
  end
end
