# One change to the plan (#258): a session or routine planned, moved,
# removed, changed or ended, by the user in the app (`manual`) or by an agent
# (`llm`: a request or MCP call made with an API token, named by it). It says
# what the item was called, the days it left and joined, the fields it
# changed (`was` before, `now` after; a removal's `was` holds what putting it
# back needs), the reason given, and which changes went together (`batch`:
# one request or tool call).
#
# The Session and Routine models write these themselves (`record!`), so a
# session that leaves because its workout was archived or its routine changed
# is recorded like any other removal. What happens to a plan rather than what
# it is (starting, finishing, skipping, a routine day confirmed or made
# tentative again) is not a change, nor is deleting a finished session.
#
# An undo runs the same model code as the change, and is recorded as a
# change pointing at the one it takes back (`undoes_id`); a change is undone
# when another points at it. Only the latest change to an item is taken back,
# and only into a day that has not gone by.
class PlanChange < Record
  BY = %w[manual llm].freeze
  KINDS = %w[session routine].freeze
  ACTIONS = %w[planned moved removed changed ended].freeze
  # A session's fields a move or change records, by their API names.
  SESSION_FIELDS = { date: :date, position: :position, note: :note, parts: :part_kinds }.freeze
  # What a removed session needs to be planned again.
  SESSION_RESTORE = %i[workout_id date position note parts created_by agent_name routine_id routine_date].freeze
  MAX_LENGTHS = { reason: 2000 }.freeze
  # How far back a list reaches by default: the last two weeks.
  DEFAULT_DAYS = 14

  # Asked to take back a change that can't be: the message says why.
  class NotUndoable < StandardError; end

  per_user
  json_columns was: nil, now: nil
  many_to_one :session
  many_to_one :routine
  many_to_one :undoes, class: self

  dataset_module do
    order :newest_first, Sequel.desc(:id)
    where :by_agent, changed_by: "llm"
    # Changes no other change takes back.
    def not_undone = exclude(id: PlanChange.exclude(undoes_id: nil).select(:undoes_id))
    # Changes made on the days in `days` (a Range of Dates), the server's days.
    def made_in(days) = where(created_at: days.begin.beginning_of_day.to_time...(days.end + 1).beginning_of_day.to_time)
  end

  # Records a change to `item` (a Session or a Routine) as made now: by an
  # agent when the request or tool call came with a token, with the reason
  # given for it (Current.plan_reason) and in this request's batch. Nothing
  # while recording is off (`quietly`). An undo's first change of the same
  # kind is the one that takes the change back.
  def self.record!(item, action, from_date: nil, to_date: nil, was: nil, now: nil, removed: false)
    return if Current.plan_quiet

    kind = item.is_a?(Session) ? "session" : "routine"
    undo = Current.plan_undo
    undoes_id = (undo.delete(:id) if undo && undo[:kind] == kind)
    by = Current.agent_name ? "llm" : "manual"
    create(
      changed_by: by, agent_name: (Current.agent_name if by == "llm"), item_kind: kind,
      "#{kind}_id": (item.id unless removed), title: title_of(item), action:,
      from_date:, to_date:, was: json(was), now: json(now), reason: Current.plan_reason,
      batch: Current.plan_batch ||= SecureRandom.uuid, undoes_id:
    )
  end

  # Changes made in the block are not recorded: states such as a routine
  # day confirmed, and the inner steps of a change recorded as one.
  def self.quietly(&) = Current.set(plan_quiet: true, &)

  # Changes made in the block are recorded with `reason`, unless one is given
  # already (the agent's reason wins over a default such as "its routine
  # changed"), or with `reason` over it when `over` (the workout was archived).
  def self.because(reason, over: false, &)
    given = reason.is_a?(String) ? reason.strip.presence : nil
    Current.set(plan_reason: over ? given : (Current.plan_reason || given), &)
  end

  # Changes by `by` (manual or llm, nil for both) made on the days in `days`,
  # newest first.
  def self.list(days, by: nil)
    changes = made_in(days).newest_first
    by ? changes.where(changed_by: by) : changes
  end

  def self.title_of(item)
    case item
    when Session then item.workout&.title
    when Routine then item.title || item.sport&.capitalize || item.workout&.title
    end
  end

  # Dates as ISO 8601 and keys as text, as JSON keeps them.
  def self.json(fields)
    fields&.to_h { |key, value| [key.to_s, value.is_a?(Date) ? value.iso8601 : value] }
  end

  # What undo needs to know about a list of changes, read once for all of
  # them: which are taken back, the latest change per item, the items and
  # the workouts a removed session would be planned with again.
  # `sessions` and `routines` already loaded are not read again.
  class Lookup
    def initialize(changes, today:, sessions: [], routines: [])
      @today = today
      session_ids = changes.map(&:session_id).compact.uniq
      routine_ids = changes.map(&:routine_id).compact.uniq
      latest = Sequel.function(:max, :id).as(:latest)
      @undone_by = read(changes.map(&:id)) { PlanChange.where(undoes_id: it).select_hash(:undoes_id, :id) }
      @latest_session = read(session_ids) { PlanChange.where(session_id: it).group(:session_id).select_hash(:session_id, latest) }
      @latest_routine = read(routine_ids) { PlanChange.where(routine_id: it).group(:routine_id).select_hash(:routine_id, latest) }
      @sessions = loaded(sessions, session_ids) { Session.where(id: it).as_hash(:id) }
      @routines = loaded(routines, routine_ids) { Routine.where(id: it).as_hash(:id) }
      @routines.each_value { it.today = today }
      @workouts = read(changes.filter_map { it.was&.dig("workout_id") }.uniq) { Workout.where(id: it).as_hash(:id) }
      # The routine days a removed session confirmed that a session holds again.
      days = changes.filter_map { [it.was["routine_id"], it.was["routine_date"]] if it.action == "removed" && it.was&.dig("routine_id") }
      @held = read(days.map(&:first).uniq) { Session.where(routine_id: it).select_map([:routine_id, :routine_date]).to_set { |id, date| [id, date.iso8601] } }
    end

    attr_reader :today

    def undone_by(change) = @undone_by[change.id]
    def session(change) = @sessions[change.session_id]
    def routine(change) = @routines[change.routine_id]
    def workout(id) = @workouts[id]
    def held?(routine_id, date) = @held.include?([routine_id, date])

    # Whether no change to its item came after it. A removed session (or a
    # deleted routine) has no item left to change.
    def latest?(change)
      if change.session_id then @latest_session[change.session_id] == change.id
      elsif change.routine_id then @latest_routine[change.routine_id] == change.id
      else true
      end
    end

    private

    # What `query` reads for `ids`, or nothing without a query when there are none.
    def read(ids, &query) = ids.empty? ? {} : query.(ids)

    def loaded(records, ids, &query)
      known = records.to_h { [it.id, it] }.slice(*ids)
      known.merge(read(ids - known.keys, &query))
    end
  end

  # What the calendar shows of the changes an agent made, not taken back:
  # each session's and routine's latest, while no change of the user's came
  # after it (`of`), and a line for every session
  # moved away from a day in `days` or removed from it, from this week on
  # (`lines`), each as its JSON with whether it can be taken back.
  class Calendar
    def initialize(days, sessions:, routines:, today:)
      agent = PlanChange.by_agent.not_undone.where(undoes_id: nil)
      latest = agent.where(Sequel.|({ session_id: sessions.map(&:id) }, { routine_id: routines.map(&:id) })).order(:id).all
      @sessions = latest.select(&:session_id).to_h { [it.session_id, it] }
      @routines = latest.select(&:routine_id).to_h { [it.routine_id, it] }
      week = today - (today.cwday - 1)
      left = ([days.begin, week].max..days.end)
      lines = left.begin > left.end ? [] : agent.where(item_kind: "session", action: %w[moved removed], from_date: left).order(:from_date, :id).all
      @lookup = Lookup.new(@sessions.values + @routines.values + lines, today:, sessions:, routines:)
      # A move stays news while the session is where it put it: not once it
      # changed again or went.
      @lines = lines.select { it.action == "removed" || (it.session_id && @lookup.latest?(it)) }
    end

    def of(item)
      change = (item.is_a?(Session) ? @sessions[item.id] : @routines[item.id])
      change.as_json(lookup: @lookup) if change && @lookup.latest?(change)
    end

    def lines = @lines.map { it.as_json(lookup: @lookup) }
  end

  def undone?(lookup = Lookup.new([self], today: Time.zone.today)) = !lookup.undone_by(self).nil?

  # Why it can't be taken back on `today`, or nil when it can.
  def undo_problem(lookup)
    today = lookup.today
    return "this change was taken back already" if undone?(lookup)
    return "an undo can't be taken back; change it again instead" if undoes_id
    return planned_problem if action == "planned"
    return "it changed again since; only its latest change can be taken back" unless lookup.latest?(self)

    item_kind == "session" ? session_problem(lookup, today) : routine_problem(lookup, today)
  end

  # Takes the change back on `today`, as the same model code would make the
  # change, recorded as a change of the user's pointing at this one. Raises
  # NotUndoable when it can't be (anything the model refuses included), and
  # then nothing has changed. Answers with the change that took it back.
  def undo!(today: Time.zone.today)
    db.transaction do
      # Checked inside the transaction, which holds the connection, so a
      # second tap waits and then finds it taken back.
      problem = undo_problem(Lookup.new([self], today:))
      raise NotUndoable, problem if problem

      Current.set(plan_reason: nil, plan_quiet: nil) { take_back(today) }
      PlanChange.where(undoes_id: id).first || raise(NotUndoable, "there was nothing to take back")
    end
  rescue Sequel::UniqueConstraintViolation
    raise NotUndoable, "this change was taken back already"
  rescue Sequel::ValidationFailed => error
    raise NotUndoable, "it can't be taken back: #{error.errors.full_messages.join(", ")}"
  rescue Session::Settled, Routine::Settled => error
    raise NotUndoable, "it can't be taken back: #{error.message}"
  end

  def as_json(options = nil)
    lookup = options&.dig(:lookup) || Lookup.new([self], today: options&.dig(:today) || Time.zone.today)
    {
      id:, changed_by:, agent_name:, item_kind:, session_id:, routine_id:, title:, action:,
      from_date: from_date&.iso8601, to_date: to_date&.iso8601, was:, now:, reason:, batch:,
      undoes_id:, undone_by_id: lookup.undone_by(self), undoable: undo_problem(lookup).nil?, created_at:
    }
  end

  def validate
    super
    validates_presence %i[changed_by item_kind action batch]
    validates_includes BY, :changed_by
    validates_includes KINDS, :item_kind
    validates_includes ACTIONS, :action
    MAX_LENGTHS.each { |column, length| validates_max_length length, column, allow_nil: true, message: "is longer than #{length} characters" }
    # Another user's session, routine or change is not found, as a lookup
    # would say.
    { session_id: Session, routine_id: Routine, undoes_id: PlanChange }.each do |column, model|
      next unless (new? || column_changed?(column)) && !self[column].nil?

      errors.add(column, "is not found") unless Record.id(self[column]) && !model.where(id: Record.id(self[column])).empty?
    end
  end

  private

  def planned_problem
    item_kind == "session" ? "take a planned session off the calendar instead" : "end the routine instead"
  end

  def session_problem(lookup, today)
    if action == "removed"
      date = Date.iso8601(was["date"])
      return "its day, #{date.iso8601}, has gone by" if date < today

      workout = lookup.workout(was["workout_id"])
      return "its workout is gone" unless workout
      return "its workout is archived" if workout.archived?
      return "its routine day, #{was["routine_date"]}, is planned again" if was["routine_id"] && lookup.held?(was["routine_id"], was["routine_date"])

      return
    end
    session = lookup.session(self)
    return "the session is no longer on the calendar" unless session
    return "the session is #{session.shown_status(today).tr("_", " ")}; only a planned one changes back" unless session.status == "planned"
    return "its old day, #{was["date"]}, has gone by" if was&.key?("date") && Date.iso8601(was["date"]) < today

    nil
  end

  def routine_problem(lookup, today)
    if was&.dig("workout_id")
      workout = lookup.workout(was["workout_id"])
      return "its workout is gone" unless workout
      return "its workout is archived" if workout.archived?
    end
    if action == "ended"
      last = was["ends_on"] && Date.iso8601(was["ends_on"])
      return "its last day, #{last.iso8601}, has gone by" if last && last < today

      return
    end

    routine = lookup.routine(self)
    return "the routine is gone" unless routine
    return "the routine has ended" if routine.ended?

    nil
  end

  # Makes the change the other way, as the item's own model code; the first
  # change it records of the item's kind is the one taking this back.
  def take_back(today)
    Current.set(plan_undo: { id:, kind: item_kind }) { take_back_now(today) }
  end

  def take_back_now(today)
    case [item_kind, action]
    in ["session", "moved" | "changed"]
      session = Session.find!(session_id)
      session.today = today
      session.set(part_kinds: was["parts"]) if was.key?("parts")
      note = was.key?("note") ? was["note"] : session.note
      if was.key?("date")
        session.move!(date: was["date"], position: was["position"], note:)
      else
        session.note = note
        session.save_changes
      end
    in ["session", "removed"]
      put_back(today, (Routine.with_pk(was["routine_id"]) if was["routine_id"]))
    in ["routine", "changed"]
      routine = Routine.find!(routine_id)
      routine.today = today
      fields = was.transform_keys(&:to_sym)
      fields[:starts_on] = [Date.iso8601(fields[:starts_on]), today].max if fields[:starts_on]
      routine.revise!(fields)
    in ["routine", "ended"]
      fields = was.transform_keys(&:to_sym)
      starts_on = [Date.iso8601(fields[:starts_on]), today].max
      ends_on = fields[:ends_on] && Date.iso8601(fields[:ends_on])
      fields = fields.slice(*Routine::FIELDS).merge(starts_on:, ends_on: (ends_on if ends_on && ends_on >= starts_on))
      routine = Routine.plan!(fields, today:, created_by: was["created_by"], agent_name: was["agent_name"])
      put_back_days(routine, today)
    end
  end

  # Plans the removed session again, confirming its routine's day again when
  # `routine` still has that day free.
  def put_back(today, routine)
    date = was["routine_date"] && Date.iso8601(was["routine_date"])
    # A day the user skipped or moved meanwhile keeps that, and the session
    # comes back on its own.
    free = routine && date && routine.workout_id == was["workout_id"] && routine.day?(date) &&
           Session.where(routine_id: routine.id, routine_date: date).empty? && RoutineDay.where(routine_id: routine.id, date:).empty?
    Session.add!(
      workout: Workout.find!(was["workout_id"]), date: was["date"], position: was["position"], status: "planned",
      note: was["note"], part_kinds: was["parts"], created_by: was["created_by"], agent_name: was["agent_name"],
      today:, **(free ? { routine_id: routine.id, routine_date: date } : {})
    )
  end

  # The sessions that confirmed an ended routine's days and went with it (in
  # the same batch) are put back on the routine planned again, each recorded
  # as taking its removal back, while their day is still to come and still
  # one of its days.
  def put_back_days(routine, today)
    return unless was["id"]

    removals = PlanChange.where(batch:, item_kind: "session", action: "removed").where(Sequel[:id] > id).all
    removals = removals.select { it.was["routine_id"] == was["id"] && it.was["routine_date"] }
    lookup = Lookup.new(removals, today:)
    removals.each do |removal|
      next if removal.undo_problem(lookup) || !routine.day?(Date.iso8601(removal.was["routine_date"]))

      removal.put_back_on(routine, today)
    end
  end

  protected

  # Takes this removal back by planning the session again on `routine`.
  def put_back_on(routine, today)
    Current.set(plan_undo: { id:, kind: item_kind }) { put_back(today, routine) }
  end

end
