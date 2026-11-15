class Step < Record
  # The signed-in user's: those of their workouts' blocks (see Record.per_user).
  per_user(:block_id) { Block.select(:id) }
  # Rough time per rep when no tempo is given, plus a few seconds to set up.
  SECONDS_PER_REP = 3
  SETUP_SECONDS = 10
  # Seconds for each phase of one rep, for example "2111" or "301".
  TEMPO = /\A\d{3,4}\z/
  # Bounds on what one step asks for (#204).
  MAX_REPS = 1000
  MAX_SECONDS = 3600
  MAX_NOTE = 500

  many_to_one :block
  many_to_one :exercise
  plugin :association_pks
  # Set when the step is done with something other than what the exercise
  # names, for example a goblet squat with the kettlebell; set through
  # equipment_pks. The rows go with the step (ON DELETE CASCADE).
  many_to_many :equipment, join_table: :step_equipment, order: Sequel[:equipment][:position]
  pks_setter :equipment

  # Done per side when the exercise is, unless said otherwise: no default of
  # its own, so a step that says nothing reads (and saves) its exercise's.
  default_values.delete(:per_side)

  # Deletes the steps, of a workout of the user's; their logged sets stay and
  # lose only the link, since each one carries what history needs.
  def self.remove!(ids)
    SetLog.where(step_id: ids).update(step_id: nil, updated_at: Time.now)
    where(id: ids).delete
  end

  # The weight the first weighted step of each exercise sets in the signed-in
  # user's workouts, by exercise id.
  def self.first_weights(exercise_ids)
    first = where(exercise_id: exercise_ids).exclude(weight_value: nil).group(:exercise_id).select { min(id) }
    where(id: first).select_map(%i[exercise_id weight_value weight_unit])
      .to_h { |exercise_id, value, unit| [exercise_id, { value: value.to_f, unit: }] }
  end

  # Held for seconds rather than counted in reps. A step has one or the other.
  def timed?
    !duration_seconds.nil?
  end

  def sides
    per_side ? 2 : 1
  end

  def weight
    { value: weight_value.to_f, unit: weight_unit } if weight_value
  end

  # What to aim for: the step's own reps or seconds, and the exercise's
  # remembered weight winning over the step's, "no weight" included (in the
  # step's unit).
  def target(remembered = nil)
    {
      reps:,
      seconds: duration_seconds,
      weight: in_gear_unit(remembered ? remembered.weight : weight)
    }
  end

  # How many weights are held: the step's own count (when done with other
  # equipment) or the exercise's.
  def held
    weights_held || exercise.weights_held
  end

  # The first of its gear that comes in set weights (dumbbells, a
  # kettlebell), if any: with one it takes a weight even while it has none.
  def set_weight_gear
    (equipment.empty? ? exercise.equipment : equipment).find(&:unit)
  end

  # The unit its weights are kept in: that of the gear in set weights it is
  # done with (its own, else its exercise's), so a goblet squat done with a
  # kettlebell in kg reads in kg even while the exercise names dumbbells in
  # lb (#197); else its exercise's (Exercise#weight_unit).
  def gear_unit
    self.class.unit_for(equipment, exercise) || Setting.unit
  end

  # The unit of a step done with `items` (its own gear, none to follow the
  # exercise): that of the first of them in set weights, else that of its
  # exercise's (Exercise#gear_unit); nil when neither names any.
  def self.unit_for(items, exercise)
    gear = items.find(&:unit)
    (gear && UserEquipment.unit_of(gear)) || exercise.gear_unit
  end

  # Whether it can carry a weight: it has one to start at, sets one of its
  # own or its exercise has one remembered, "no weight" included (so stepping
  # down to no weight can be stepped back up), or it is done with gear in set
  # weights (which takes one even while it has none).
  def takes_weight?(target_weight, remembered = nil)
    !!(target_weight || weight_value || remembered || set_weight_gear)
  end

  # The unit its target weight is kept in, nil when it takes no weight.
  def target_unit(target_weight, remembered = nil)
    gear_unit if takes_weight?(target_weight, remembered)
  end

  def equipment_needed
    own_equipment || exercise.equipment_slugs
  end

  # The slugs of what the step is done with besides what its exercise names;
  # nil while it follows the exercise, the same gear listed again included.
  def own_equipment
    slugs = equipment.map(&:slug)
    slugs unless slugs.empty? || exercise.same_gear?(slugs)
  end

  # The weights the stepper moves through, in the step's unit.
  def allowed_weights(fixed = Equipment.fixed)
    Equipment.allowed_for(equipment_needed, gear_unit, fixed)
  end

  # Which owned gear carries each of those weights, for the generic weight.
  def any_weight(fixed = Equipment.fixed)
    Equipment.any_weight_for(equipment_needed, gear_unit, fixed)
  end

  def estimated_seconds
    work = timed? ? duration_seconds : (reps || 1) * seconds_per_rep
    sides * work + SETUP_SECONDS
  end

  # `equipment` and `weights_held` are the step's own, nil while it follows
  # its exercise, so the step can be sent back to the builder as it is, even
  # with another exercise; `equipment_needed` is what it is done with.
  def as_json(*)
    own = own_equipment
    {
      id:, position:, reps:, duration_seconds:, tempo:, weight:, weights_held:, per_side:, note:,
      equipment: own, equipment_needed: own || exercise.equipment_slugs, exercise: exercise.as_json
    }
  end

  # Per side when its exercise is, unless the step says otherwise.
  def per_side
    value = super
    value.nil? && exercise ? exercise.unilateral : value
  end

  def before_validation
    self.per_side = per_side if self[:per_side].nil?
    super
  end

  def validate
    super
    validates_number :reps, only_integer: true, greater_than: 0, at_most: MAX_REPS, allow_nil: true
    validates_number :duration_seconds, only_integer: true, greater_than: 0, at_most: MAX_SECONDS, allow_nil: true
    validates_max_length MAX_NOTE, :note, allow_nil: true, message: "is longer than #{MAX_NOTE} characters"
    validates_format TEMPO, :tempo, message: "must be 3 or 4 digits, seconds per phase", allow_nil: true
    validates_number :weight_value, at_least: 0, allow_nil: true
    if weight_value.nil?
      errors.add(:weight_unit, "needs a weight") if weight_unit.present?
    else
      validates_includes ExerciseWeight::UNITS, :weight_unit
    end
    validates_includes [1, 2], :weights_held, message: "must be 1 or 2", allow_nil: true
    # Reps or seconds, never both; neither only when the note says what to do.
    errors.add(:base, "needs reps or seconds, not both") if reps && duration_seconds
    errors.add(:base, "needs reps, seconds or a note") unless reps || duration_seconds || note.present?
    sides_match_exercise
  end

  private

  # A weight in the step's unit, snapped to an owned weight when it comes in
  # the other one (as the device converts it).
  def in_gear_unit(weight)
    unit = gear_unit
    weight && weight[:unit] != unit ? Weights.normalize(weight, unit, allowed_weights) : weight
  end

  def seconds_per_rep
    tempo ? tempo.chars.sum(&:to_i) : SECONDS_PER_REP
  end

  def sides_match_exercise
    return unless exercise && per_side != exercise.unilateral

    errors.add(:per_side, exercise.unilateral ? "must be set, #{exercise.slug} is done one side at a time" : "must not be set, #{exercise.slug} works both sides at once")
  end
end
