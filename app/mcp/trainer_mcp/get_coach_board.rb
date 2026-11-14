module TrainerMcp
  class GetCoachBoard < CoachTool
    description <<~TEXT.squish
      The user's Coach tab: their goals (active, in order: what everything else ties back to), your proposals still
      waiting for them, and the ones they dismissed (don't propose those again); the current status and focus (the
      newest of each), open concerns, the latest of the journal (notes, and the statuses, focus and concerns since replaced or
      resolved), and this week (Monday to Sunday) as a plain list of
      sessions, activities and dated notes. Each note says who wrote it: `user` (the person), `human` (a coach they
      named) or `llm` (you or another agent). Nothing is summed or scored: judge from the numbers and the notes.
      Read this first.
    TEXT
    annotations(title: "Get coach board", **READ_ONLY)

    def self.answer
      board = CoachBoard.new
      week = board.week
      compact(
        **today_and_weekday,
        goals: board.goals.map { goal(it) },
        proposals: board.proposals.map { goal(it) },
        dismissed: board.dismissed.map { goal(it) },
        status: board.current("status")&.then { note(it) }, focus: board.current("focus")&.then { note(it) },
        concerns: board.open_concerns.map { note(it) },
        notes: board.journal.map { note(it) },
        week: {
          from: week.begin.iso8601, to: week.end.iso8601,
          sessions: Session.eager(:completion, :workout).where(date: week).in_order.all.then { |sessions| minutes = {}; sessions.map { SessionTool.shown(it, minutes) } },
          activities: board.week_activities.map { it.as_json.except(:client_ref, :created_at, :updated_at) },
          notes: board.week_notes.map { note(it) }
        }
      )
    end
  end
end
