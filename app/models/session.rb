# A workout on a date, of one user. The player runs a main workout framed by its program's
# warm-up and cool-down, and logs every set against this session.
#
# A day can hold several sessions, in `position` order (1 first). A planned
# session whose day has gone by reads as missed: the database keeps planned,
# so moving it to today or later makes it planned again.
class Session < Record
  STATUSES = %w[planned in_progress done skipped].freeze
  # The statuses a session reads as, missed (derived) included.
  SHOWN_STATUSES = %w[planned missed in_progress done skipped].freeze
  CREATORS = %w[manual llm].freeze
  # The most sessions planned in one go, four weeks of one a day.
  PLAN_LIMIT = 28

  # Asked to move or remove a session that is no longer planned: it has
  # started, was skipped or is done.
  class Settled < StandardError; end

  # One of several sessions planned at once that can't be planned; `index`
  # counts from 0 in the order given.
  class EntryInvalid < Sequel::ValidationFailed
    attr_reader :index

    def initialize(session, index)
      @index = index
      super(session)
    end
  end

  json_columns part_kinds: nil

  # When a session happened on its day: its finish, else its start.
  MOMENT = Sequel.function(:coalesce, Sequel.lit("(SELECT completions.finished_at FROM completions WHERE completions.session_id = sessions.id)"), Sequel[:sessions][:started_at])
  # Newest first in the order `after` goes by: by date, then by when
  # sessions happened, the ones that neither started nor finished last, in
  # the day's planned order.
  LATEST_FIRST = [
    Sequel.desc(Sequel[:sessions][:date]),
    Sequel.desc(Sequel.expr(MOMENT => nil)),
    Sequel.desc(MOMENT),
    Sequel.desc(Sequel.case({ { MOMENT => nil } => Sequel[:sessions][:position] }, nil)),
    Sequel.desc(Sequel[:sessions][:id])
  ].freeze

  per_user
  include AgentSigned
  many_to_one :workout, key: %i[user_id workout_id], primary_key: %i[user_id id]
  one_to_many :set_logs, key: %i[user_id session_id], primary_key: %i[user_id id]
  one_to_one :completion
  # Its set logs and completion go with it (ON DELETE CASCADE).

  dataset_module do
    order :in_order, :date, :position, :id
    # What a session's summary reads: its workout, sets and completion.
    def summarized = eager(:workout, :set_logs, :completion)

    # Sessions that happened after `session`: on a later date, or later on
    # the same day by when they finished (else started). The day's order is
    # only where the planner put them, so it decides only between sessions
    # that neither started nor finished, which come after the ones that did.
    def after(session)
      date, position, id = Sequel[:sessions][:date], Sequel[:sessions][:position], Sequel[:sessions][:id]
      moment = session.moment
      same_day =
        if moment
          (MOMENT > moment) | ((MOMENT =~ moment) & (id > session.id)) | Sequel.expr(MOMENT => nil)
        else
          Sequel.expr(MOMENT => nil) & ((position > session.position) | ((position =~ session.position) & (id > session.id)))
        end
      where((date > session.date) | ((date =~ session.date) & same_day))
    end

    # Newest first, as `after` orders sessions.
    def latest_first = order(*LATEST_FIRST)

    # The session that best represents a day: the first under way, then the
    # first still planned, then the last done, then the last skipped.
    def for_day(date)
      rank = Sequel.case({ { status: "in_progress" } => 0, { status: "planned" } => 1, { status: "done" } => 2 }, 3)
      place = Sequel.case({ { status: %w[in_progress planned] } => :position }, Sequel[:position] * -1)
      where(date:).order(rank, place, Sequel.desc(:id)).first
    end

    # Sessions that read as one of `statuses` on `today`, missed included: a
    # planned one is missed before today and planned from today on.
    def with_status(statuses, today: Time.zone.today)
      conditions = statuses.map do |status|
        case status
        when "missed" then Sequel.&({ status: "planned" }, Sequel[:date] < today)
        when "planned" then Sequel.&({ status: "planned" }, Sequel[:date] >= today)
        else Sequel.expr(status:)
        end
      end
      # None asked for, none match.
      where(conditions.empty? ? false : Sequel.|(*conditions))
    end
  end

  # Done sessions per week (Monday to Sunday) from `from` to `to`, newest
  # week first, counted among the given sessions (each one's workout and
  # completion are read). Sessions ended early count apart, as partial; a
  # warm-up or cool-down done on its own is not a training day.
  def self.weeks(sessions, from, to)
    monday = ->(date) { date - (date.cwday - 1) }
    finished = sessions.select { it.status == "done" && it.workout.kind == "workout" }.group_by { monday.(it.date) }
    monday.(to).step(monday.(from), -7).map do |start|
      partial, done = finished.fetch(start, []).partition { it.completion&.ended_early }
      { week_start: start.iso8601, done: done.size, partial: partial.size }
    end
  end

  # The statuses a "planned,missed" list (or an array) names, nil for all of
  # them; raises ArgumentError for one a session never reads as.
  def self.statuses(given)
    return if given.blank?

    statuses = (given.is_a?(Array) ? given : given.to_s.split(",")).map { it.to_s.strip }
    unknown = statuses - SHOWN_STATUSES
    raise ArgumentError, "unknown status: #{unknown.join(", ")}" if unknown.any?

    statuses
  end

  # Adds a session on a day at `position` (last by default); the sessions
  # from there on move down one. A planned one needs a day from today on.
  def self.add!(date:, position: nil, **attributes)
    session = new(**attributes)
    db.transaction { session.send(:place!, date, position) }
    session
  end

  # Plans a workout on a day from today on, as add! does.
  def self.plan!(workout:, date:, position: nil, note: nil, parts: nil, created_by: "manual", client_ref: nil)
    add!(workout:, date:, position:, note:, part_kinds: parts, created_by:, client_ref:, status: "planned")
  end

  # Plans several sessions, all or nothing: one that can't be planned leaves
  # the calendar as it was. Each entry takes plan!'s keywords; they are
  # planned in turn, so a position counts the ones planned before it.
  def self.plan_all!(entries, created_by: "manual")
    raise ArgumentError, "plan at most #{PLAN_LIMIT} sessions at once" if entries.size > PLAN_LIMIT

    db.transaction do
      entries.each_with_index.map do |entry, index|
        plan!(created_by:, **entry)
      rescue Sequel::ValidationFailed => error
        raise EntryInvalid.new(error.model, index)
      end
    end
  end

  # Numbers a user's sessions on a day 1..n, in their order or in the order
  # given, writing only the positions that change.
  def self.renumber(date, sessions = where(date:).order(:position, :id).all)
    sessions.each.with_index(1) do |session, position|
      next if session.position == position

      session.update_columns(position:)
    end
  end

  # The day planning and status checks count from: the client's own when it
  # sent one (see ApplicationController#client_today), else the server's.
  attr_writer :today

  def today
    @today || Time.zone.today
  end

  # When it happened on its day, as `after` orders it: its finish, else its
  # start; nil for one that has done neither.
  def moment
    completion&.finished_at || started_at
  end

  # The status it reads as: planned on a day before `today` is missed.
  def shown_status(today = self.today)
    status == "planned" && date < today ? "missed" : status
  end

  # Moves a planned (or missed) session to another day from today on (last
  # there unless `position` says otherwise), or to another place on its day;
  # the days it leaves and joins are renumbered. A note given replaces the
  # planner's note.
  def move!(date: self.date, position: nil, note: self.note)
    planned!("moved")

    self.note = note
    db.transaction { place!(date, position) }
    self
  end

  # Takes a planned (or missed) session off the calendar, as the calendar's
  # Remove and the trainer (MCP) do; erase! deletes a session of any status.
  def remove!
    planned!("removed")

    destroy
  end

  # Deletes the session with everything logged against it. A remembered
  # weight this session set (it matches the last weight logged here, and no
  # later session logged the exercise) goes back to what the remaining history
  # says: the last weight logged elsewhere, or the seed weight.
  def erase!
    db.transaction do
      weights = ExerciseWeight.where(exercise_id: last_weights.keys).as_hash(:exercise_id)
      affected = last_weights.select do |exercise_id, weight|
        weights[exercise_id] && Weights.same?(weights[exercise_id].weight, weight) && !later_logs?(exercise_id)
      end
      destroy
      affected.each_key { weights[it].fall_back! }
    end
  end

  # The workouts this session runs: its workout with the warm-up and
  # cool-down it includes.
  def parts
    workout.framed(part_kinds)
  end

  def plan
    PlayerPlan.new(parts)
  end

  # `today` (an option, else the session's today) decides what is missed.
  def as_json(options = nil)
    {
      id:, date: date.iso8601, position:, status: shown_status(options&.dig(:today) || today),
      created_by:, agent_name:, note:, started_at:, client_ref:, parts: part_kinds,
      routine_id:, routine_date: routine_date&.iso8601,
      workout: workout.summary,
      sets_done: set_logs.count { it.status == "done" && it.main? },
      completion: completion&.as_json, created_at:
    }
  end

  # A new session goes last on its day, and a day keeps no gaps.
  # super first, so it is the user's (PerUser).
  def before_validation
    super
    self.position ||= Session.where(date:).max(:position).to_i + 1 if date
  end

  def validate
    super
    validates_presence :date
    validates_includes STATUSES, :status
    validates_includes CREATORS, :created_by
    validates_number :position, only_integer: true, greater_than: 0
    history_stays
    routine_own
    return unless planning?

    planned_ahead
    workout_current
  end

  # Picked up again, a session is no longer finished: its finish goes until
  # it is finished again.
  def after_update
    # super first: dirty records what this save changed in its own
    # after_update, and column_previously_changed? reads that.
    super
    record_plan_change
    return unless column_previously_changed?(:status, from: "done")

    completion&.destroy
    associations.delete(:completion)
  end

  # A session planned is a change to the plan (PlanChange), unless it
  # confirms a routine's day (Routine#confirm! records nothing).
  def after_create
    super
    PlanChange.record!(self, "planned", to_date: date) if status == "planned"
  end

  def after_destroy
    super
    Session.renumber(date)
    # Taken off the calendar while planned (or missed): recorded with what
    # planning it again needs.
    return unless status == "planned"

    PlanChange.record!(self, "removed", from_date: date, removed: true, was: PlanChange::SESSION_RESTORE.to_h { [it, it == :parts ? part_kinds : self[it]] })
  end

  private

  # A planned session moved to another day, or its note or parts changed, is
  # a change to the plan (PlanChange); a new place on its day, or a change of
  # status (started, skipped, planned again), is not.
  def record_plan_change
    changes = previous_changes
    return unless changes.fetch(:status, [status]).first == "planned" && status == "planned"

    moved = changes.key?(:date)
    fields = PlanChange::SESSION_FIELDS.select { |name, column| changes.key?(column) && (moved || name != :position) }
    return if fields.empty?

    was = fields.to_h { |name, column| [name, plan_value(column, changes[column].first)] }
    now = fields.to_h { |name, column| [name, plan_value(column, changes[column].last)] }
    if moved && !was.key?(:position)
      was[:position] = now[:position] = position
    end
    PlanChange.record!(self, moved ? "moved" : "changed", from_date: changes.dig(:date, 0) || date, to_date: date, was:, now:)
  end

  # A value as dirty kept it, parts read from their JSON.
  def plan_value(column, value)
    column == :part_kinds && value.is_a?(String) ? JSON.parse(value) : value
  end

  # Puts the session on the `given` date (a Date or YYYY-MM-DD, read
  # strictly) at `position`, clamped to the day, and saves it. Without a
  # position it keeps its place on its own day, and goes last on another. A
  # planned session's new date must be today or later (planned_ahead).
  def place!(given, position)
    from = date unless new?
    date, problem = date_from(given)
    if problem
      errors.add(:date, problem)
      raise Sequel::ValidationFailed, self
    end

    position ||= self.position if date == from
    day = Session.where(date:).exclude(id:).order(:position, :id).all
    index = (position || day.size + 1).clamp(1, day.size + 1) - 1
    self.date, self.position = date, index + 1
    # Only what changed: this copy may be older than the row (another
    # device logging a set meanwhile), and a full save would write it back.
    save_changes
    Session.renumber(date, day.insert(index, self))
    Session.renumber(from) if from && from != date
  end

  # The date given, or what is wrong with it.
  def date_from(given)
    return [nil, "can't be blank"] if given.blank?

    [DateRange.date(given, :date), nil]
  rescue DateRange::Invalid => error
    [nil, error.problem]
  end

  # Only a session still planned (or missed) can be moved or removed.
  def planned!(done)
    raise Settled, "session #{id} is #{shown_status.tr("_", " ")}; only a planned session can be #{done}" unless status == "planned"
  end

  # Planned, moved while planned, or made planned again.
  def planning?
    status == "planned" && (new? || column_changed?(:date) || column_changed?(:status))
  end

  # A session planned, moved or made planned again goes on today or later:
  # one planned on a day gone by would read as missed straight away.
  def planned_ahead
    errors.add(:date, "must be today or later") if date.is_a?(Date) && date < today
  end

  # An archived workout is off the calendar from today on: nothing is
  # planned with it, moved or planned again.
  def workout_current
    errors.add(:workout, "is archived; plan another workout") if workout&.archived?
  end

  # A session with sets logged is history: it can't be planned again, so a
  # planned one never holds sets to lose when it is moved or removed. A
  # finished one keeps its status and the parts it ran, though one ended
  # early may be picked up again, back in progress.
  def history_stays
    status_changed = column_changed?(:status)
    if !new? && status_changed && status == "planned" && !set_logs_dataset.empty?
      errors.add(:status, "can't go back to planned once sets are logged")
    end
    return unless !new? && initial_value(:status) == "done"
    return if status == "in_progress" && completion&.ended_early

    errors.add(:status, "can't change once the session is done") if status_changed
    errors.add(:parts, "can't change once the session is done") if changing?(:part_kinds)
  end

  # A session planned for a routine's day is of the user's routine and runs
  # its workout: another user's routine is not found, as a lookup would say.
  def routine_own
    return if routine_id.nil? || !(new? || column_changed?(:routine_id))

    routine = Record.id(routine_id) && Routine.with_pk(Record.id(routine_id))
    errors.add(:routine_id, "is not found") unless routine
    errors.add(:routine_date, "is not a day of the routine") if routine && !(routine_date.is_a?(Date) && routine.day?(routine_date))
    errors.add(:workout, "is not the routine's") if routine && routine.workout_id != workout_id
  end

  # The weight of the last done, weighted set per exercise in this session.
  def last_weights
    @last_weights ||= set_logs_dataset.weighted.order(:id).all.to_h { [it.exercise_id, it.weight] }
  end

  def later_logs?(exercise_id)
    !SetLog.weighted.for_exercise(exercise_id).where(session_id: Session.after(self).select(:id)).empty?
  end
end
