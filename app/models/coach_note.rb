# frozen_string_literal: true

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
#
# A reply (`reply_to_id`) is the user's answer to a note they didn't write:
# a plain note, about what its note is about, shown under it rather than in
# the journal or on a day of its own. One level: a reply has no replies.
class CoachNote < Record
  KINDS = %w[status focus concern note].freeze
  AUTHORS = %w[user human llm].freeze
  # What the app may send for a note.
  FIELDS = %i[kind title body author_kind author_name date activity_id session_id reply_to_id].freeze
  MAX_LENGTHS = { title: 200, body: 5000, author_name: 100, resolution: 2000 }.freeze
  # The most notes one page of the journal holds.
  PAGE = 20
  PAGE_LIMIT = 100
  # The most notes an agent writes in a day (the server's), so one stuck in a
  # loop can't bury the board.
  AGENT_DAILY_LIMIT = 20

  # Asked to resolve a note that isn't a concern.
  class NotAConcern < StandardError; end
  # An agent's note past AGENT_DAILY_LIMIT.
  class DailyLimit < StandardError; end

  per_user
  many_to_one :activity
  many_to_one :session
  many_to_one :reply_to, class: self
  one_to_many :replies, class: self, key: :reply_to_id, order: :id

  dataset_module do
    # Notes with their replies under them, the replies left out on their own.
    def threads = where(reply_to_id: nil).eager(:replies)
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
    # `day` (the server's), but those the user replied to, whose replies would go too.
    def tidy_before(day)
      start = day.in_time_zone.to_time
      journal.by_agent.where { created_at < start }.exclude(id: CoachNote.exclude(reply_to_id: nil).select(:reply_to_id))
    end
  end

  def concern? = kind == "concern"
  def reply? = !reply_to_id.nil?
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
      activity_id:, session_id:, about: about, reply_to_id:,
      replies: reply? ? [] : replies.map(&:as_json),
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
    # What a token writes is the agent's, whatever the request says.
    self.author_kind = "llm" if Current.agent_name && new?
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
    MAX_LENGTHS.each do |column, length|
      validates_max_length length, column, allow_nil: true, message: "is longer than #{length} characters"
    end
    validate_reply if reply? || column_changed?(:reply_to_id)
    if !new? && author_kind == "user" && column_changed?(:author_kind) && !replies_dataset.empty?
      errors.add(:author_kind, "can't be user: you replied to this note")
    end
    # Another user's activity or session is not found, as a lookup would say.
    { activity_id: Activity, session_id: Session }.each do |column, model|
      next unless (new? || column_changed?(column)) && !self[column].nil?

      errors.add(column, "is not found") unless Record.id(self[column]) && !model.where(id: Record.id(self[column])).empty?
    end
  end

  # An agent changes and deletes only the notes it wrote: the user's, and a
  # coach's they named, are theirs.
  def before_save
    unless new?
      theirs!
      if Current.agent_name && (column_changed?(:author_kind) || column_changed?(:author_name))
        Record.user_only!("note #{id} stays signed as the agent's")
      end
    end
    super
  end

  # However it is written, over MCP or the API, an agent writes at most
  # AGENT_DAILY_LIMIT notes a day.
  def before_create
    if author_kind == "llm" && Current.agent_name && CoachNote.by_agent.written_today.count >= AGENT_DAILY_LIMIT
      raise DailyLimit, "an agent writes at most #{AGENT_DAILY_LIMIT} notes a day; change or delete the ones there"
    end

    super
  end

  # The user's replies go with the note they answer (the foreign key
  # cascades), so an agent leaves a note the user replied to.
  def before_destroy
    theirs!
    if Current.agent_name && !replies_dataset.empty?
      Record.user_only!("note #{id} has the user's replies; an agent changes it rather than deleting it")
    end
    super
  end

  private

  def theirs!
    Record.user_only!("note #{id} is the user's; an agent changes only the notes it wrote") unless initial_value(:author_kind) == "llm"
  end

  # A reply answers a note the user didn't write, and is theirs: a plain
  # note with no day or link of its own, under a note that isn't a reply.
  def validate_reply
    return errors.add(:reply_to_id, "can't be changed") if !new? && column_changed?(:reply_to_id)

    if new?
      target = Record.id(reply_to_id) && CoachNote.with_pk(Record.id(reply_to_id))
      return errors.add(:reply_to_id, "is not found") unless target

      errors.add(:reply_to_id, "is a reply; answer the note it replies to") if target.reply?
      errors.add(:reply_to_id, "is your own note; edit it instead") if target.author_kind == "user"
    end
    errors.add(:kind, "must be note for a reply") unless kind == "note"
    errors.add(:author_kind, "must be user for a reply") unless author_kind == "user"
    %i[date activity_id session_id].each { errors.add(it, "is the note's, not a reply's") unless self[it].nil? }
  end
end
