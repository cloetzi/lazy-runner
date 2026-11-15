# What a coach writes on the user's board: the current `status` (where things
# stand), the `focus` (what to work on), a `concern` (something to watch,
# open until resolved), or a plain `note` in the journal.
#
# The current status or focus is the newest of its kind; the ones before stay
# in the journal, and deleting the current one brings the one before back.
#
# `author_kind` says who wrote it: `user` (the signed-in person, shown as
# "You"), `human` (a coach without an account, named in `author_name`, written
# on the user's account) or `llm` (an agent over MCP, maybe named too). A note
# can be about a day, an activity or a session of the user's.
class CoachNote < Record
  KINDS = %w[status focus concern note].freeze
  AUTHORS = %w[user human llm].freeze
  # What the app may send for a note.
  FIELDS = %i[kind title body author_kind author_name date activity_id session_id].freeze
  MAX_LENGTHS = { title: 200, body: 5000, author_name: 100, resolution: 2000 }.freeze
  # The most notes one page of the journal holds.
  PAGE = 20
  PAGE_LIMIT = 100
  # The most notes an agent writes in a day (the server's), so one stuck in a
  # loop can't bury the board.
  AGENT_DAILY_LIMIT = 20

  # Asked to resolve a note that isn't a concern.
  class NotAConcern < StandardError; end

  per_user
  many_to_one :activity
  many_to_one :session

  dataset_module do
    # Newest first: ids grow as notes are written.
    order :newest_first, Sequel.desc(:id)
    def of_kind(kind) = where(kind:)
    where :open_concerns, kind: "concern", resolved_at: nil
    where :by_agent, author_kind: "llm"
    # Written since the start of the server's day.
    def written_today = where { created_at >= Time.zone.now.beginning_of_day.to_time }
    # Notes that show on one of the days in `days`, in the order written:
    # one about a session or activity on its day now (a note follows its
    # session when it moves), any other on the day it is dated to.
    def on_days(days)
      where(
        Sequel.|(
          { session_id: nil, activity_id: nil, date: days },
          { session_id: Session.where(date: days).select(:id) },
          { activity_id: Activity.where(date: days).select(:id) }
        )
      ).order(:id)
    end

    # Notes by who wrote them: `user`, `human` or `llm`, one or several.
    def by(authors) = where(author_kind: authors)

    # The journal: every note but the current status and focus and the open
    # concerns, which say where things stand.
    def journal
      current = %w[status focus].filter_map { CoachNote.of_kind(it).newest_first.get(:id) }
      exclude(id: current).exclude(kind: "concern", resolved_at: nil)
    end

    # What "Tidy up" removes: an agent's notes in the journal written before
    # `day` (the server's).
    def tidy_before(day)
      start = day.in_time_zone.to_time
      journal.by_agent.where { created_at < start }
    end
  end

  def concern? = kind == "concern"
  def resolved? = !resolved_at.nil?

  # Resolves a concern, saying how when given.
  # Resolves a concern, saying how when given. One resolved already keeps
  # when it was; a resolution given replaces the one it had.
  def resolve!(resolution = nil)
    concern!
    return update(resolution:) if resolved? && resolution
    return self if resolved?

    update(resolved_at: Time.now, resolution:)
  end

  # Opens a resolved concern again.
  def reopen!
    concern!
    update(resolved_at: nil, resolution: nil)
  end

  def concern!
    raise NotAConcern, "only a concern can be resolved; this is a #{kind}" unless concern?
  end

  def as_json(*)
    {
      id:, kind:, title:, body:, author_kind:, author_name:, date: date&.iso8601,
      activity_id:, session_id:, about: about,
      resolved_at:, resolution:, created_at:, updated_at:
    }
  end

  # A word on what the note is about, for the board to show: the activity's
  # title (else sport) or the session's workout.
  def about
    if activity then { type: "activity", id: activity.id, date: activity.date.iso8601, label: activity.title || activity.sport.capitalize }
    elsif session then { type: "session", id: session.id, date: session.date.iso8601, label: session.workout&.title }
    end
  end

  def before_validation
    %i[title body author_name resolution].each do |column|
      value = self[column]
      self[column] = value.strip.presence if value.is_a?(String)
    end
    self.author_name = nil if author_kind == "user"
    # An agent's note is signed with its API token's name, as everything it
    # writes is (Record::AgentSigned).
    self.author_name = Current.agent_name if author_kind == "llm" && new? && Current.agent_name
    # Only a concern is resolved: one changed to another kind is open again,
    # and only a resolved one says how.
    self.resolved_at = nil unless concern?
    self.resolution = nil unless resolved_at
    super
  end

  def validate
    super
    validates_presence %i[kind body author_kind]
    validates_includes KINDS, :kind
    validates_includes AUTHORS, :author_kind
    validates_presence :author_name if author_kind == "human"
    validates_presence :title if concern?
    MAX_LENGTHS.each { |column, length| validates_max_length length, column, allow_nil: true, message: "is longer than #{length} characters" }
    # Another user's activity or session is not found, as a lookup would say.
    { activity_id: Activity, session_id: Session }.each do |column, model|
      next unless (new? || column_changed?(column)) && !self[column].nil?

      errors.add(column, "is not found") unless Record.id(self[column]) && !model.where(id: Record.id(self[column])).empty?
    end
  end
end
