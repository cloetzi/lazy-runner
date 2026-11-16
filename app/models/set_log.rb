# frozen_string_literal: true

# What was actually done for one set of a step (one side, for per-side steps).
# Self-contained: it names the exercise planned and the one done, the block and
# the target as shown, so history stays true when the workout changes. The step
# link is kept while the step exists; `step_ref` keeps the step's id after it
# has gone, and with the session, set number and side names the set.
class SetLog < Record
  STATUSES = %w[done skipped].freeze
  SIDES = %w[left right].freeze
  # A block's label as the player showed it (Block::MAX_LABEL, with room).
  MAX_BLOCK_LABEL = 100
  # The part of the session it was logged in: the session's own workout, or
  # the warm-up or cool-down framing it.
  PARTS = Workout::KINDS

  # A user's, as its session is; user_id is kept here too, since history
  # reads sets by exercise across sessions.
  per_user
  many_to_one :session, key: %i[user_id session_id], primary_key: %i[user_id id]
  many_to_one :step
  many_to_one :exercise
  many_to_one :planned_exercise, class: :Exercise

  # Columns are qualified, so these hold in a join with sessions.
  dataset_module do
    where :done, Sequel[:set_logs][:status] => "done"

    # Done sets with a weight, the ones that say what an exercise was lifted at.
    def weighted = done.exclude(Sequel[:set_logs][:weight_value] => nil)

    def for_exercise(exercise_id) = where(Sequel[:set_logs][:exercise_id] => exercise_id)

    # Newest session first (as Session.latest_first orders them), and within
    # one the last set logged first.
    def latest_first
      join(:sessions, id: :session_id).select_all(:set_logs).order(*Session::LATEST_FIRST, Sequel.desc(Sequel[:set_logs][:id]))
    end
  end

  def swapped?
    exercise_id != planned_exercise_id
  end

  # In the main workout rather than its warm-up or cool-down. A set logged
  # before parts were kept, whose step has gone, counts as main.
  def main? = part.nil? || part == "workout"

  # The part a step is in for a session: its own workout is the main one
  # ("workout", whatever that workout's kind), anything else the kind of the
  # warm-up or cool-down it frames it with.
  # A set for a step the session can't take: one of another workout, or one
  # it no longer runs that comes without what the player showed.
  class NotPartOfSession < Refusal
    refuses_with :bad_request

    def details = { fields: { step_id: ["is not part of this session"] } }
  end

  # Logs a set of `session`, or updates it when logged before: a set is
  # named by its step (`step_ref`), round (`set_number`) and `side`, so a
  # retry or a reload updates it. `exercise_id` names a swap. The weight
  # given is converted to the unit of the gear the step is done with (the
  # exercise's own when swapped). `shown` is what the player showed
  # ({ exercise_id:, block_label:, target:, part: }, as sent), which keeps a
  # set whose step the session no longer runs, unlinked. The first set
  # starts a planned session. Returns the set and whether it is new.
  def self.log!(session, step_ref, set_number:, side: nil, exercise_id: nil, reps: nil, seconds: nil, weight: nil, status: nil,
                shown: {})
    step = Step.eager(:block).first(id: step_ref)
    # A step of none of the parts its workout can have is no set of it.
    if step && !session.workout.framed_ids.include?(step.block.workout_id)
      raise NotPartOfSession, "step #{step.id} is not part of this session"
    end

    # The step as the session runs it now, or nil when it no longer does.
    linked = step if step && session.workout.framed_ids(session.part_kinds).include?(step.block.workout_id)
    planned = shown_plan(step, step_ref, shown) unless linked
    # A swap names the exercise done instead.
    exercise = exercise_id ? Exercise.find!(exercise_id) : (linked&.exercise || planned[0])
    # In the unit of the gear the step is done with, unless swapped.
    unit = linked && linked.exercise_id == exercise.id ? Step.unit_for(linked.equipment, exercise) : exercise.gear_unit
    weight = exercise.in_weight_unit((weight || {})[:value], (weight || {})[:unit], unit)
    attempts = 0
    begin
      log = find_or_new(user_id: session.user_id, session_id: session.id, step_ref:, set_number:, side:)
      created = log.new?
      # The target is the one shown when the set was first logged.
      if created && linked
        log.step_id = linked.id
        log.plan_from(linked, linked.target(ExerciseWeight.first(exercise_id: linked.exercise_id)))
      elsif created
        log.record_plan(*planned)
      end
      # From the step while it exists, else as the player sent it.
      log.part = step ? part_of(session, step) : shown[:part] if created
      log.update(
        exercise_id: exercise.id, reps:, seconds:,
        weight_value: weight[:value], weight_unit: weight[:value] && weight[:unit],
        status: status || "done"
      )
    rescue Sequel::UniqueConstraintViolation
      # A concurrent post of the same set inserted it between the lookup and
      # the insert; looking it up again finds it and updates it.
      raise if (attempts += 1) > 1

      retry
    end
    session.update(status: "in_progress", started_at: session.started_at || Time.now) if session.status == "planned"
    [log, created]
  end

  # What a set of a step the session no longer runs was planned as, from
  # what the player showed: [exercise, block label, target]. Without that, a
  # step that is gone is not found, and one of a part left out is refused.
  def self.shown_plan(step, step_ref, shown)
    if shown[:exercise_id].nil?
      raise Record::NotFound.new(Step, step_ref) unless step

      raise NotPartOfSession, "step #{step.id} is not part of this session"
    end

    planned = Exercise.find!(shown[:exercise_id])
    target = shown[:target].is_a?(Hash) ? shown[:target] : {}
    given = target[:weight].is_a?(Hash) ? target[:weight] : {}
    weight = planned.in_weight_unit(given[:value], given[:unit])
    weight = nil unless weight[:value].is_a?(Numeric) && ExerciseWeight::UNITS.include?(weight[:unit])
    reps, seconds = target.values_at(:reps, :seconds).map { Integer(it.to_s, exception: false) }
    [planned, shown[:block_label] || step&.block&.label, { reps:, seconds:, weight: }]
  end
  private_class_method :shown_plan

  def self.part_of(session, step)
    step.block.workout_id == session.workout_id ? "workout" : step.block.workout.kind
  end

  # Records what the step asked for, as the player showed it.
  def plan_from(step, target)
    record_plan(step.exercise, step.block.label, target)
  end

  # Records what was planned: the exercise, its block and the target
  # ({ reps:, seconds:, weight: { value:, unit: } }).
  def record_plan(planned_exercise, block_label, target)
    self.planned_exercise = planned_exercise
    self.block_label = block_label
    self.target_reps = target[:reps]
    self.target_seconds = target[:seconds]
    self.target_weight_value = target[:weight]&.dig(:value)
    self.target_weight_unit = target[:weight]&.dig(:unit)
  end

  def weight
    { value: weight_value.to_f, unit: weight_unit } if weight_value
  end

  def target
    weight = { value: target_weight_value.to_f, unit: target_weight_unit } if target_weight_value
    { reps: target_reps, seconds: target_seconds, weight: }
  end

  def as_json(*)
    {
      id:, session_id:, step_id:, step_ref:, exercise_id:, planned_exercise_id:, block_label:, part:, set_number:, side:,
      reps:, seconds:, weight:, status:, target:
    }
  end

  # The step is a plain link, not keyed by the user: one of another user's
  # workouts is refused, as Record.per_user refuses their records.
  def before_save
    if step_id && (new? || column_changed?(:step_id)) && Step.where(id: step_id).empty?
      raise Current::Mismatch, "this set's step is another user's"
    end

    # A finished or skipped session is history: an agent logs sets only in
    # one planned or under way.
    if Current.agent_name && %w[done skipped].include?(session&.status)
      Record.user_only!("session #{session_id} is #{session.status}: only the user changes the sets of a session done or skipped")
    end
    super
  end

  # Without a plan of its own, a new log takes its step's, and the planned
  # exercise was the one done.
  def before_validation
    if new?
      plan_from(step, step.target) if step && !planned_exercise_id
      self.part = self.class.part_of(session, step) if part.nil? && step && session
      self.exercise_id ||= planned_exercise_id
      self.step_ref ||= step_id
    end
    super
  end

  def validate
    super
    validates_number :set_number, only_integer: true, greater_than: 0
    validates_includes SIDES, :side, allow_nil: true
    validates_includes PARTS, :part, allow_nil: true
    validates_includes STATUSES, :status
    validates_includes ExerciseWeight::UNITS, :weight_unit unless weight_value.nil?
    validates_includes ExerciseWeight::UNITS, :target_weight_unit unless target_weight_value.nil?
    validates_number :reps, :seconds, only_integer: true, at_least: 0, allow_nil: true
    validates_number :weight_value, :target_weight_value, at_least: 0, allow_nil: true
    return unless new? || column_changed?(:block_label)

    validates_max_length MAX_BLOCK_LABEL, :block_label, allow_nil: true, message: "is longer than #{MAX_BLOCK_LABEL} characters"
  end
end
