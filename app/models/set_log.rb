# What was actually done for one set of a step (one side, for per-side steps).
# Self-contained: it names the exercise planned and the one done, the block and
# the target as shown, so history stays true when the workout changes. The step
# link is kept while the step exists; `step_ref` keeps the step's id after it
# has gone, and with the session, set number and side names the set.
class SetLog < Record
  STATUSES = %w[done skipped].freeze
  SIDES = %w[left right].freeze
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
  end
end
