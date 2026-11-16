# frozen_string_literal: true

module TrainerMcp
  class WriteCoachNote < CoachTool
    description <<~TEXT.squish
      Write on the user's Coach tab, as yourself (`author_kind: llm`, signed with your API token's name). `status` is where things stand and `focus`
      what to work on: each replaces the current one, which stays in the journal. The Coach page opens on them: give a
      status a `title`, its headline there, of at most eight words, and write a focus as up to three lines, one thing to
      do each, separated by line breaks, without dashes or numbers (the page draws the list). A `concern` is something to watch,
      open until resolved (resolve_concern). A `note` goes in the journal. Tie each to a goal. A note can be about a
      `date`, an `activity_id` or a `session_id`. Write a new note only for something new: to correct or add to one you
      wrote, update_coach_note it (list_coach_notes finds it). The same note sent again (the same day, for a plain note) is not written twice
      (`already_written`), and you write at most #{CoachNote::AGENT_DAILY_LIMIT} a day.
      When the person's note and yours disagree, theirs wins.
    TEXT
    input_schema(
      properties: {
        kind: { type: "string", enum: CoachNote::KINDS },
        title: { type: "string",
                 description: "A short headline; needed for a concern. A status's is the page's headline: at most eight words." },
        body: { type: "string", description: "The note, a few plain sentences. A focus: up to three lines, one thing to do each." },
        date: { type: "string", format: "date",
                description: "The day it is about, YYYY-MM-DD. Not for what a planned session or run is for: that goes in its own note." },
        activity_id: { type: "integer", description: "The activity it is about." },
        session_id: { type: "integer", description: "The session it is about, from list_sessions." },
        author_name: { type: "string", description: "Ignored: the app signs your notes with your API token's name." }
      },
      required: %w[kind body]
    )
    annotations(title: "Write coach note", **WRITES)

    # Checked and saved in one transaction, so calls sent side by side can't
    # both get past the repeat check or the daily limit.
    # `author_name` is still taken, so a prompt that names it keeps working,
    # but the note is signed with the token's name (CoachNote).
    # rubocop:disable-next Lint/UnusedMethodArgument -- author_name, as above
    def self.answer(kind:, body:, title: nil, author_name: nil, **about)
      written = CoachNote.new(kind:, body:, title:, author_kind: "llm", **about)
      CoachNote.db.transaction do
        written.validate! # tidies the text as saving would, to compare it
        same = same_as(written)
        next note(same).merge(already_written: true) if same

        # The daily limit is the model's (CoachNote#before_create), said here
        # with the tools that help.
        begin
          note(written.save(validate: false))
        rescue CoachNote::DailyLimit
          raise Problem, "you wrote #{CoachNote::AGENT_DAILY_LIMIT} notes today, the most in a day: update_coach_note " \
                         "the ones there, or delete_coach_notes what is stale"
        end
      end
    end

    # A note of the agent's still in place that says the same: a plain note
    # written today, an open concern, the current status or focus.
    def self.same_as(written)
      same = CoachNote.by_agent.where(%i[kind title body date activity_id session_id author_name].to_h { [it, written[it]] }).newest_first
      case written.kind
      when "concern" then same.where(resolved_at: nil).first
      when "note" then same.written_today.first
      else same.first&.then { it if CoachNote.of_kind(written.kind).newest_first.get(:id) == it.id }
      end
    end
  end
end
