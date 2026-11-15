# What the user means to do, tentatively: a weekly routine ("run every
# Wednesday") or a one-off on one day ("maybe a hike on Saturday"). It is a
# sport, fulfilled by a logged activity of the same family (Sport) on its day,
# or one of the user's workouts, fulfilled by a session of it.
#
# Its days are worked out when the calendar is read (RoutineCalendar); only
# the days the user changed are stored (RoutineDay), and a workout routine's
# confirmed day is a planned session that names it (`routine_id` +
# `routine_date`).
#
# Days in the past never change after the fact: changing when a routine runs
# (`SCHEDULE`) once it has days before today ends it yesterday and starts a
# new one today (`revise!`). Ending a routine sets `ends_on`; there is no
# other way to stop one.
class Routine < Record
  EFFORTS = %w[easy moderate hard].freeze
  CREATORS = %w[manual llm].freeze
  WEEKDAYS = (1..7)
  # What a client may send for a routine.
  FIELDS = %i[title sport workout_id weekdays starts_on ends_on minutes distance_m effort note].freeze
  # What decides which days a routine has and what fulfils them.
  SCHEDULE = %i[sport workout_id weekdays starts_on].freeze
  MAX_LENGTHS = { title: 200, sport: 40, note: 2000 }.freeze

  # Asked to change a day or a routine in a way its history doesn't allow:
  # a day already done, a one-off on a day gone by, an ended routine.
  class Settled < StandardError; end

  per_user
  include AgentSigned
  json_columns weekdays: []
  many_to_one :workout, key: %i[user_id workout_id], primary_key: %i[user_id id]
  one_to_many :stored_days, class: :RoutineDay
  # Its stored days go with it (ON DELETE CASCADE); sessions and activities
  # linked to its days keep their place on the calendar, unlinked (SET NULL).

  dataset_module do
    order :in_order, :starts_on, :id

    # Routines with days in `days` (a Range of Dates).
    def running_in(days) = where { starts_on <= days.end }.where(Sequel.|({ ends_on: nil }, Sequel[:ends_on] >= days.begin))

    # Routines not ended before `today`: ones with days still to come,
    # including a day moved (or planned as a session) to today or later.
    def current(today)
      where(
        Sequel.|(
          { ends_on: nil }, Sequel[:ends_on] >= today,
          { id: RoutineDay.where { moved_to >= today }.select(:routine_id) },
          { id: Session.exclude(routine_id: nil).where { date >= today }.select(:routine_id) }
        )
      )
    end
  end

  # Plans a routine from `attributes` (FIELDS), starting `today` unless it
  # says otherwise. `confirmed` makes a one-off's day confirmed in the same
  # write ("Planned" rather than "Maybe").
  # `agent_name` names the agent of one planned again by an undo.
  def self.plan!(attributes, today: Time.zone.today, created_by: "manual", confirmed: false, agent_name: nil)
    routine = new(created_by:, agent_name:, today:)
    routine.set(attributes.to_h.transform_keys(&:to_sym).slice(*FIELDS))
    routine.starts_on ||= today
    db.transaction do
      routine.save
      PlanChange.record!(routine, "planned", to_date: routine.starts_on)
      if confirmed
        raise Settled, "only a one-off can be planned as confirmed; confirm a weekly routine's days one at a time" unless routine.one_off?

        routine.confirm!(routine.starts_on)
      end
    end
    routine
  end

  # The day routine and day changes count from: the client's own when it sent
  # one (ApplicationController#client_today), else the server's.
  attr_writer :today

  def today
    @today || Time.zone.today
  end

  def one_off? = weekdays.empty?
  # Ended before today, with no day of it moved (or planned as a session) to
  # today or later.
  def ended?
    return false if ends_on.nil? || ends_on >= today

    stored_days_dataset.where(Sequel[:moved_to] >= today).empty? && Session.where(routine_id: id).where(Sequel[:date] >= today).empty?
  end
  # Days before today, which stay as they were.
  def history? = starts_on < today

  # Whether `date` is one of its days.
  def day?(date)
    return false if date < starts_on || (ends_on && date > ends_on)

    one_off? ? date == starts_on : weekdays.include?(date.cwday)
  end

  # Its days within `range`, in order.
  def dates_in(range)
    from = [range.begin, starts_on].max
    to = [range.end, ends_on].compact.min
    return [] if from > to

    one_off? ? [starts_on] : (from..to).select { weekdays.include?(it.cwday) }
  end

  # How its day `date` reads now (RoutineCalendar::Day); NotFound when it is
  # not one of its days.
  def day(date)
    date = DateRange.date(date, :date)
    raise NotFound.new(RoutineDay, date.iso8601, "routine #{id} has no day #{date.iso8601}") unless day?(date)

    RoutineCalendar.day(self, date, today:)
  rescue DateRange::Invalid
    raise NotFound.new(RoutineDay, date, "routine #{id} has no day #{date}")
  end

  # "I'm going": the day is confirmed. A workout routine's day is planned as a
  # session of its workout (Session.plan!), so it needs to be today or later,
  # as a confirmed sport day does. A state of the day, so no change to the
  # plan is recorded (PlanChange), not even for the session it plans.
  def confirm!(date)
    users_day!
    PlanChange.quietly { confirm_day(date) }
  end

  private def confirm_day(date)
    day = day(date)
    return day if day.state == "confirmed"

    open!(day, "confirmed")
    if day.on < today
      errors.add(:date, "must be today or later")
      raise Sequel::ValidationFailed, self
    end

    db.transaction do
      if day.session
        day.session.today = today
        day.session.update(status: "planned")
      elsif workout_id
        Session.add!(workout:, date: day.on, status: "planned", created_by:, agent_name:, today:, routine_id: id, routine_date: day.date)
        stored_days_dataset.where(date: day.date).delete
      else
        store!(day.date, "confirmed", day.on == day.date ? nil : day.on)
      end
    end
    day(date)
  end

  # "Not this week": the day won't happen, on the day it shows. One planned
  # as a session is skipped with it.
  def skip!(date)
    users_day!
    day = day(date)
    return day if day.state == "skipped"

    open!(day, "skipped")
    db.transaction do
      if day.session
        session = day.session
        raise Session::Settled, "session #{session.id} is #{session.shown_status.tr("_", " ")}; only a planned one can be skipped" unless session.status == "planned"

        session.update(status: "skipped")
      else
        store!(day.date, "skipped", day.on == day.date ? nil : day.on)
      end
    end
    day(date)
  end

  # Moves a day to another day from today on, where it reads as it did
  # (tentative or confirmed); its own date takes the move back. A day planned
  # as a session moves the session.
  def move!(date, to)
    users_day!
    day = day(date)
    open!(day, "moved")
    to = DateRange.date(to, :moved_to)
    if to < today
      errors.add(:moved_to, "must be today or later")
      raise Sequel::ValidationFailed, self
    end

    db.transaction do
      if day.session
        day.session.today = today
        day.session.move!(date: to)
      else
        moved_to = to == day.date ? nil : to
        status = day.stored&.status == "confirmed" ? "confirmed" : "moved"
        moved_to.nil? && status == "moved" ? stored_days_dataset.where(date: day.date).delete : store!(day.date, status, moved_to)
      end
    end
    day(date)
  rescue DateRange::Invalid => error
    errors.add(:moved_to, error.problem)
    raise Sequel::ValidationFailed, self
  end

  # Makes a confirmed or skipped day tentative again where it shows: a move
  # stays (moving it back to its own date undoes that), and a session planned
  # for it is taken off the calendar (Session::Settled once it has started).
  # A day gone by stays as it was. Like confirm!, it records no change to the
  # plan.
  def reset!(date)
    users_day!
    PlanChange.quietly { reset_day(date) }
  end

  private def reset_day(date)
    day = day(date)
    raise Settled, "#{day.on.iso8601} has gone by; it stays as it was" if day.on < today

    db.transaction do
      session = day.session
      if session&.status == "skipped" && session.set_logs_dataset.empty?
        session.destroy
      else
        session&.remove!
      end
      day.on == day.date ? stored_days_dataset.where(date: day.date).delete : store!(day.date, "moved", day.on)
    end
    day(date)
  end

  # Changes the routine. Changing when it runs (SCHEDULE) once it has days
  # before today ends it yesterday and starts a new routine today with the
  # change, which is returned; anything else changes it in place. Days stored
  # from today on, and the sessions and activities linked to them, move to
  # what the routine is now when they are still among its days (a session
  # only for the same workout, an activity only for a sport); otherwise the
  # days go, sessions still planned come off the calendar and other links are
  # dropped.
  def revise!(changes)
    users_own!
    changes = changes.to_h.transform_keys(&:to_sym).slice(*FIELDS)
    draft = Routine.new((columns - %i[id created_at updated_at]).to_h { [it, public_send(it)] }).set(changes)
    draft.today = today
    draft.send(:normalize)
    rescheduled = SCHEDULE.any? { draft.public_send(it) != public_send(it) }
    before = field_values

    db.transaction do
      if rescheduled && history?
        raise Settled, "routine #{id} ended on #{ends_on.iso8601}; plan a new one" if ended?
        raise Settled, "this one-off was on #{starts_on.iso8601}, a day gone by; plan a new one" if one_off?

        draft.starts_on = [draft.starts_on, today].max
        draft.save
        update(ends_on: today - 1)
        # One change to the user: the new routine is the one changed.
        draft.send(:record_change, before)
        PlanChange.because("its routine changed") { carry_days(today, draft) }
        draft
      else
        raise Settled, "routine #{id} ended on #{ends_on.iso8601}; plan a new one" if ended? && changes.key?(:ends_on) && draft.ends_on != ends_on

        reach = rescheduled || draft.ends_on != ends_on
        set(changes)
        save_changes
        record_change(before)
        PlanChange.because("its routine changed") { carry_days(today, self) } if reach
        self
      end
    end
  end

  # What a client may send, as the routine has it now.
  def field_values = FIELDS.to_h { [it, public_send(it)] }

  # Stops the routine from today on: one with days before today ends
  # yesterday and keeps them; one without is deleted. Its days from today on
  # go, sessions still planned for them come off the calendar. An ended
  # routine asked to `erase` is deleted with its history; otherwise ending it
  # again changes nothing. Answers :ended or :deleted.
  # `archived`: its workout was archived, which ends the routines running
  # it whoever planned them (Workout#archive!).
  def end!(erase: false, archived: false)
    users_own! unless archived
    @ending = true
    db.transaction do
      if ended?
        next :ended unless erase

        # Its history goes, which is not a change to the plan.
        destroy
        next :deleted
      end
      # Its id too, to find the sessions that went with it.
      PlanChange.record!(self, "ended", from_date: today, was: field_values.merge(created_by:, agent_name:, id:))
      PlanChange.because("its routine ended") do
        if history?
          update(ends_on: today - 1)
          carry_days(today, nil)
          :ended
        else
          carry_days(starts_on, nil)
          destroy
          :deleted
        end
      end
    end
  ensure
    @ending = nil
  end

  # Sessions and activities that fulfilled its days stay, unlinked: the
  # foreign key nulls routine_id, and this the day it named.
  def before_destroy
    users_own! unless @ending
    super
    Session.where(routine_id: id).update(routine_id: nil, routine_date: nil)
    Activity.where(routine_id: id).update(routine_id: nil, routine_date: nil)
  end

  # The user's own routines are theirs to change or end; an agent changes
  # only the ones it planned.
  def users_own!
    Record.user_only!("routine #{id} is the user's; only they change or end it") unless created_by == "llm"
  end

  # A day's state is the user's word: going, skipping, moving it.
  def users_day!
    Record.user_only!("only the user confirms, skips or moves a routine's day, in the app")
  end

  def as_json(*)
    {
      id:, title:, sport:, workout: workout&.summary, weekdays:, one_off: one_off?,
      starts_on: starts_on.iso8601, ends_on: ends_on&.iso8601,
      minutes:, distance_m:, effort:, note:, created_by:, agent_name:, created_at:, updated_at:
    }
  end

  def before_validation
    normalize
    super
  end

  def validate
    super
    validates_presence :starts_on
    validates_includes CREATORS, :created_by
    validates_includes EFFORTS, :effort, allow_nil: true
    validates_number :minutes, :distance_m, only_integer: true, greater_than: 0, allow_nil: true
    MAX_LENGTHS.each { |column, length| validates_max_length length, column, allow_nil: true, message: "is longer than #{length} characters" }
    if sport.nil? == workout_id.nil?
      errors.add(:base, "A routine is a sport or a workout, not both") if sport && workout_id
      errors.add(:sport, "can't be blank without a workout") unless sport || workout_id
    end
    unless weekdays.is_a?(Array) && weekdays.all? { it.is_a?(Integer) && WEEKDAYS.cover?(it) }
      errors.add(:weekdays, "must be a list of weekdays, 1 (Monday) to 7 (Sunday)")
    end
    if starts_on.is_a?(Date) && (new? || column_changed?(:starts_on)) && starts_on < today
      errors.add(:starts_on, "must be today or later")
    end
    errors.add(:ends_on, "must not be before starts on") if starts_on.is_a?(Date) && ends_on.is_a?(Date) && ends_on < starts_on
    # Ending it earlier would take away days gone by.
    if !new? && column_changed?(:ends_on) && ends_on.is_a?(Date) && starts_on.is_a?(Date) && starts_on < today && ends_on < today - 1
      errors.add(:ends_on, "must be yesterday or later: days gone by stay as they were")
    end
    workout_own if new? || column_changed?(:workout_id)
  end

  private

  # Kept as they are compared: the sport as Activity.sport keeps it, weekdays
  # sorted once each, a one-off ending on its day.
  def normalize
    self.sport = Activity.sport(sport)
    self.sport = nil if sport == ""
    %i[title note effort].each do |column|
      value = self[column]
      self[column] = value.strip.presence if value.is_a?(String)
    end
    self.weekdays = (weekdays || []).map { it.is_a?(String) && it.match?(/\A\d\z/) ? it.to_i : it }.uniq.sort_by { it.is_a?(Integer) ? it : 0 } if weekdays.is_a?(Array)
    self.ends_on = starts_on if one_off_shape? && starts_on.is_a?(Date)
  end

  def one_off_shape? = weekdays.is_a?(Array) && weekdays.empty?

  # Records what changed since `before` (fields as they were) as one change
  # to the plan, from the first day it reaches.
  def record_change(before)
    after = field_values
    changed = FIELDS.reject { before[it] == after[it] }
    return if changed.empty?

    day = [starts_on, today].max
    PlanChange.record!(self, "changed", from_date: day, to_date: day, was: before.slice(*changed), now: after.slice(*changed))
  end

  # One of the user's workouts that isn't archived: another user's is not
  # found, as a lookup would say.
  def workout_own
    return if workout_id.nil?

    found = Record.id(workout_id) && Workout.with_pk(Record.id(workout_id))
    if !found
      errors.add(:workout_id, "is not found")
    elsif found.archived?
      errors.add(:workout, "is archived; pick another workout")
    end
  end

  # A day already done stays done.
  def open!(day, change)
    raise Settled, "#{day.date.iso8601} is done already; it can't be #{change}" if day.state == "done"
  end

  def store!(date, status, moved_to)
    stored = RoutineDay.first(routine_id: id, date:) || RoutineDay.new(routine_id: id, date:)
    stored.set(status:, moved_to:)
    stored.save_changes || stored
  end

  # What is linked to this routine's days from `from` on, or shows from then
  # on (a day moved forward), goes to `into` (nil: nowhere) while still among
  # its days; see revise!.
  def carry_days(from, into)
    stored_days_dataset.where { (date >= from) | (moved_to >= from) }.all.each do |stored|
      if !into&.day?(stored.date)
        stored.destroy
      elsif into.workout_id && stored.status == "confirmed"
        # A workout routine's day is confirmed by a session of its workout.
        stored.moved_to ? stored.update(routine_id: into.id, status: "moved") : stored.destroy
      else
        stored.update(routine_id: into.id) unless into.id == id
      end
    end
    Session.where(routine_id: id).where { (routine_date >= from) | (date >= from) }.all.each do |session|
      if into&.day?(session.routine_date) && into.workout_id == session.workout_id
        session.update_columns(routine_id: into.id) unless into.id == id
      elsif session.status == "planned" && session.date >= today
        session.destroy
      else
        session.update_columns(routine_id: nil, routine_date: nil)
      end
    end
    Activity.where(routine_id: id).where { routine_date >= from }.all.each do |activity|
      if into&.day?(activity.routine_date) && into.sport
        activity.update_columns(routine_id: into.id) unless into.id == id
      else
        activity.update_columns(routine_id: nil, routine_date: nil)
      end
    end
  end
end
