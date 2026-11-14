module TrainerMcp
  # What the coach tools share: goals and notes as they answer with them.
  class CoachTool < Tool
    def self.goal(goal)
      compact(
        id: goal.id, title: goal.title, why: goal.why, target_date: goal.target_date&.iso8601, status: goal.status,
        position: (goal.position if goal.active?), reason: goal.proposed_reason, replaces: goal.replaces_id,
        decided: day(goal.decided_at)
      )
    end

    # The day a moment was in the server's time zone (TZ), as `today` is.
    def self.day(time) = time&.in_time_zone&.to_date&.iso8601

    def self.note(note)
      compact(
        note.as_json.slice(:id, :kind, :title, :body, :author_kind, :author_name, :date, :resolution).merge(
          about: note.about&.except(:date), written: day(note.created_at),
          resolved: day(note.resolved_at)
        )
      )
    end

    # A note an agent wrote, which an agent may change or delete; the
    # person's (and a coach's they named) stay theirs.
    def self.agents_note(id)
      note = CoachNote.with_pk(id) || raise(Problem, "no note #{id}; list_coach_notes lists them")
      raise Problem, "note #{id} is the person's; leave it, or write a note of your own" unless note.author_kind == "llm"

      note
    end
  end
end
