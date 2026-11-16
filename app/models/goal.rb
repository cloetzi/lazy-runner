# frozen_string_literal: true

# What the user trains for: "Ski season with strong, quiet knees", with an
# optional target date and why it matters. Goals anchor the Coach tab, and
# the coach ties status, focus and plans back to them.
#
# Only the user writes active goals. An agent can only propose one
# (`propose!`): a goal with status `proposed`, a reason, and maybe the goal it
# would change (`replaces`). The user accepts it, which makes it active in
# that goal's place, or dismisses it, which keeps it as `dismissed` so the
# agent can see it was turned down.
#
# Active goals are in `position` order, 1 first; achieved and dropped ones
# stay as a record of what was.
class Goal < Record
  STATUSES = %w[active achieved dropped proposed dismissed].freeze
  # The statuses the user sets on a goal of theirs; a proposal changes only
  # by accept! or dismiss!.
  SETTABLE = %w[active achieved dropped].freeze
  CREATORS = %w[user llm].freeze
  # What the app may send for a goal.
  FIELDS = %i[title why target_date status position].freeze
  MAX_LENGTHS = { title: 200, why: 2000, proposed_reason: 2000 }.freeze
  # The most proposals waiting for the user at once.
  OPEN_PROPOSALS = 5

  # Asked to accept or dismiss a goal that is no longer a proposal, or to
  # change a proposal other than by accepting or dismissing it.
  class NotProposed < Refusal; end

  per_user
  include AgentSigned

  many_to_one :replaces, class: self

  dataset_module do
    order :in_order, :position, :id
    where :active, status: "active"
    where :proposed, status: "proposed"
    where :dismissed, status: "dismissed"
    # Achieved, dropped and dismissed goals, the latest decided first.
    def past
      exclude(status: %w[active proposed]).order(Sequel.desc(Sequel.function(:coalesce, :decided_at, :updated_at)), Sequel.desc(:id))
    end
  end

  # A goal an agent proposes, for the user to accept or dismiss. `replaces`
  # is the id of an active goal it would change. Refused when the user
  # already dismissed a goal of the same title, or has OPEN_PROPOSALS
  # waiting.
  def self.propose!(title:, reason:, why: nil, target_date: nil, replaces: nil)
    replaced = active.with_pk(Record.id(replaces)) || raise(NotFound.new(self, replaces, "no active goal #{replaces}")) if replaces
    # Compared in Ruby: SQLite's lower() folds ASCII letters only.
    if (dismissed = self.dismissed.all.find { it.title.downcase == title.to_s.strip.downcase })
      raise NotProposed,
            "the user dismissed #{dismissed.title.inspect} on #{dismissed.decided_at.in_time_zone.to_date.iso8601}; don't propose it again"
    end
    raise NotProposed, "#{OPEN_PROPOSALS} proposals are already waiting for the user" if proposed.count >= OPEN_PROPOSALS

    create(title:, why:, target_date:, status: "proposed", created_by: "llm", proposed_reason: reason, replaces_id: replaced&.id)
  end

  # A goal the user adds: active, last unless `position` says otherwise.
  def self.add!(fields)
    user_only!("only the user adds a goal; an agent proposes one (MCP propose_goal)")
    db.transaction(savepoint: true) do
      position = fields[:position]
      goal = create(**fields.except(:position, :status), status: "active", created_by: "user", position: next_position)
      goal.move_to!(position) if position
      goal
    end
  end

  def self.next_position = (active.max(:position) || 0) + 1

  def proposed? = status == "proposed"
  def active? = status == "active"

  # The user's changes to a goal of theirs. A proposal changes only by
  # accept! or dismiss!.
  def revise!(fields)
    Record.user_only!("only the user changes a goal; an agent proposes a change (MCP propose_goal with `replaces`)")
    raise NotProposed, "a proposed goal is accepted or dismissed, not edited" if proposed? || status == "dismissed"

    db.transaction(savepoint: true) do
      position = fields[:position]
      changes = fields.except(:position)
      if changes.key?(:status)
        unless SETTABLE.include?(changes[:status])
          errors.add(:status, "must be one of #{SETTABLE.join(", ")}")
          raise Sequel::ValidationFailed, self
        end
        if changes[:status] != status
          changes[:decided_at] = changes[:status] == "active" ? nil : Time.now
          changes[:position] = self.class.next_position if changes[:status] == "active"
        end
      end
      update(changes)
      move_to!(position) if position && active?
      renumber! unless active?
      self
    end
  end

  # The proposal becomes an active goal: in the place of the goal it
  # replaces, which is dropped, else last.
  def accept!
    Record.user_only!("only the user accepts a proposed goal, in the app")
    raise NotProposed, "goal #{id} is #{status}, not proposed" unless proposed?

    db.transaction(savepoint: true) do
      replaced = replaces if replaces&.active?
      position = replaced ? replaced.position : self.class.next_position
      replaced&.update(status: "dropped", decided_at: Time.now, position: 0)
      update(status: "active", position:, decided_at: Time.now)
      renumber!
      self
    end
  end

  def dismiss!
    Record.user_only!("only the user dismisses a proposed goal, in the app")
    raise NotProposed, "goal #{id} is #{status}, not proposed" unless proposed?

    update(status: "dismissed", decided_at: Time.now)
  end

  # Puts an active goal at `position` (1 first) among the active ones.
  def move_to!(position)
    position = Record.id(position)
    unless position&.positive?
      errors.add(:position, "must be greater than 0")
      raise Sequel::ValidationFailed, self
    end

    others = self.class.active.exclude(id:).in_order.select_map(:id)
    others.insert([position - 1, others.size].min, id)
    renumber!(others)
    refresh
  end

  def as_json(*)
    {
      id:, title:, why:, target_date: target_date&.iso8601, status:, position: (position if active?),
      created_by:, agent_name:, proposed_reason:, replaces_id:, decided_at:, created_at:, updated_at:
    }
  end

  def before_validation
    %i[title why proposed_reason].each do |column|
      value = self[column]
      self[column] = value.strip.presence if value.is_a?(String)
    end
    super
  end

  def validate
    super
    validates_presence :title
    validates_includes STATUSES, :status
    validates_includes CREATORS, :created_by
    validates_presence :proposed_reason if proposed?
    # An agent's goal waits for the user (Goal.propose!).
    errors.add(:status, "must be proposed for a goal an agent writes") if new? && Current.agent_name && !proposed?
    MAX_LENGTHS.each do |column, length|
      validates_max_length length, column, allow_nil: true, message: "is longer than #{length} characters"
    end
  end

  def before_destroy
    Record.user_only!("only the user deletes a goal, in the app")
    super
  end

  # The active goals left close up behind one deleted.
  def after_destroy
    super
    renumber! if active?
  end

  private

  # Active goals numbered 1, 2, 3... in `ids` order, else as they are.
  def renumber!(ids = self.class.active.in_order.select_map(:id))
    ids.each_with_index { |goal_id, index| self.class.where(id: goal_id).update(position: index + 1) }
  end
end
