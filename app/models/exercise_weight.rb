# frozen_string_literal: true

# A user's remembered weight for an exercise. Shared by every workout of
# theirs the exercise appears in, and always wins over the seed value. Reps and seconds are not
# remembered: they belong to each workout's step. A null `value` remembers
# "no weight" (#230): the exercise is done without one, whatever the steps
# set, until a weight is remembered again.
class ExerciseWeight < Record
  UNITS = %w[lb kg].freeze
  # What a change records of a remembered weight: its value (nil for no
  # weight) and unit, both nil while nothing is remembered.
  NOTHING = { value: nil, unit: nil }.freeze

  per_user
  many_to_one :exercise

  # Remembers `value` for the exercise, in `unit` (else the unit remembered,
  # else the exercise's); a weight in the other unit is converted and
  # snapped to an owned weight. A nil or 0 `value` remembers no weight. Raises
  # Sequel::ValidationFailed for a value that is no weight. A change is
  # recorded (PlanChange), from what was remembered to what is.
  def self.remember!(exercise, value, unit = nil)
    # Read in the transaction, which holds the connection, so what it was
    # is what this changes.
    db.transaction do
      remembered = find_or_new(exercise_id: exercise.id)
      if value.is_a?(String) && value.strip.empty?
        remembered.errors.add(:value, "is not a number")
        raise Sequel::ValidationFailed, remembered
      end
      unit = unit.presence || remembered.unit || exercise.weight_unit
      given = none?(value) ? { value: nil, unit: } : exercise.in_weight_unit(value, unit)
      was = remembered.recorded
      remembered.update(value: given[:value], unit: given[:unit])
      remembered.record_change(exercise, was)
      remembered
    end
  end

  # Forgets the weight remembered, so the steps' own weights count again,
  # recorded as a change (undo puts it back to nothing remembered).
  def self.forget!(exercise)
    remembered = first(exercise_id: exercise.id) or return
    db.transaction do
      was = remembered.recorded
      remembered.destroy
      PlanChange.record!(exercise, "changed", was:, now: NOTHING)
    end
  end

  def recorded = new? ? NOTHING : { value: value&.to_f, unit: }

  def record_change(exercise, was)
    now = recorded
    PlanChange.record!(exercise, "changed", was:, now:) unless now == was
  end

  # No weight: nil, or a weight of 0 (as the MCP tools give none).
  def self.none?(value)
    value.nil? || (value.is_a?(Numeric) && value.zero?) || (value.is_a?(String) && Float(value, exception: false)&.zero?)
  end

  # Nil for no weight.
  def weight
    { value: value.to_f, unit: } if value
  end

  def none?
    value.nil?
  end

  # Goes back to the last weight logged for the exercise, or to the seed
  # weight when nothing is logged. With no weight to go back to, nothing is
  # left to remember.
  def fall_back!
    weight = SetLog.weighted.for_exercise(exercise_id).latest_first.first&.weight
    weight ||= Step.where(exercise_id:).exclude(weight_value: nil).order(:id).first&.weight
    weight = Weights.convert(weight, exercise.weight_unit)
    return destroy unless weight

    update(value: (weight[:value] unless self.class.none?(weight[:value])), unit: weight[:unit])
  end

  def as_json(*)
    { exercise_id:, value: value&.to_f, unit:, updated_at: }
  end

  def validate
    super
    validates_number :value, at_least: 0, allow_nil: true
    validates_includes UNITS, :unit
  end
end
