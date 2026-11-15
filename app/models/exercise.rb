class Exercise < Record
  CATEGORIES = %w[stretch mobility activation strength cardio].freeze
  AREAS = %w[legs hips core upper_body].freeze
  PATTERNS = %w[squat lunge hinge push pull anti_extension anti_rotation mobility].freeze
  # Patterns close enough to stand in for each other.
  RELATED_PATTERNS = { "squat" => "lunge", "lunge" => "squat", "anti_extension" => "anti_rotation", "anti_rotation" => "anti_extension" }.freeze
  # How closely a swap trains the same movement, best first.
  MATCHES = %w[same similar other].freeze

  json_columns areas: [], cues: [], mistakes: [], instructions: [], animation: nil

  plugin :association_pks
  # What it needs, in inventory order; set through equipment_pks.
  many_to_many :equipment, join_table: :exercise_equipment, order: Sequel[:equipment][:position]
  pks_setter :equipment
  # The signed-in user's remembered weight for it (ExerciseWeight is per user).
  one_to_one :remembered, class: :ExerciseWeight
  add_association_dependencies equipment: :nullify

  dataset_module do
    # Out of the seeds, kept only for the history logged against it.
    where :current, retired: false

    # Exercises that need nothing outside `equipment` (records or ids).
    def doable_with(equipment)
      ids = equipment.map { it.is_a?(Equipment) ? it.id : it }
      exclude(id: db[:exercise_equipment].exclude(equipment_id: ids).select(:exercise_id))
    end
  end

  # Whether `slugs` name just what it needs, in any order: a step that lists
  # them has no gear of its own.
  def same_gear?(slugs)
    slugs.sort == equipment_slugs.sort
  end

  def equipment_slugs
    equipment.map(&:slug)
  end

  # The one unit its weights are kept in: the one the signed-in user's gear
  # comes in, so weights line up with what is owned, else their unit (Settings).
  def weight_unit
    gear_unit || Setting.unit
  end

  # The unit its gear in set weights comes in for the signed-in user, nil
  # when it names none.
  def gear_unit
    gear = equipment.find(&:unit)
    UserEquipment.unit_of(gear) if gear
  end

  # Exercises that can stand in for this one for a session: doable with the
  # equipment owned and of the same category, ranked by how well they do the
  # same job: the same movement pattern first (then a related one), then the
  # same body areas and highlighted muscles, the most equipment in common,
  # done the same way (per side or both at once) and the same kind of target
  # (reps or seconds). A per-side exercise can stand in for a two-sided one
  # and the other way round; the player runs the sides it needs.
  def alternatives
    candidates = Exercise.current.doable_with(Equipment.owned.all).where(category:).exclude(id:).eager(:equipment, :remembered).all
    candidates.sort_by do |other|
      [
        MATCHES.index(match(other)), -(areas & other.areas).size, -(regions & other.regions).size,
        -(equipment_slugs & other.equipment_slugs).size, [unilateral, alternating] == [other.unilateral, other.alternating] ? 0 : 1,
        timed? == other.timed? ? 0 : 1, other.name
      ]
    end
  end

  # How closely another exercise trains the same movement: same, similar or other.
  def match(other)
    return "other" unless pattern && other.pattern
    return "same" if pattern == other.pattern

    RELATED_PATTERNS[pattern] == other.pattern ? "similar" : "other"
  end

  # One line on why another exercise is offered as a swap for this one:
  # "Same movement, same dumbbells".
  def match_reason(other)
    movement = { "same" => "Same movement", "similar" => "Similar movement" }[match(other)]
    movement ||= (areas & other.areas).any? ? "Works the same area" : "Same kind of exercise"
    shared = equipment.select { other.equipment_slugs.include?(it.slug) }
    gear = if other.equipment_slugs.empty? then "no equipment"
           elsif shared.any? then "same #{shared.map { it.any_weight ? "weight" : it.name.downcase }.join(" and ")}"
           else other.equipment.map { it.name.downcase }.join(" and ")
           end
    side = ("one side at a time" if other.unilateral && !unilateral) || ("alternating sides" if other.alternating && !alternating) ||
           ("both sides at once" if (unilateral || alternating) && !other.unilateral && !other.alternating)
    [movement, gear, side].compact.join(", ")
  end

  # The body regions the animation highlights, without the near/far side.
  def regions
    Array(animation&.dig("highlight")).map { it.sub(/_(near|far)\z/, "") }.uniq
  end

  # Held for time rather than counted in reps, as a step is (Step#timed?).
  def timed?
    !default_seconds.nil?
  end

  # What to start at: the remembered weight, else the weight a program sets
  # (`seed`, looked up for many exercises at once with Step.first_weights).
  def start_weight(seed)
    Weights.convert(remembered ? remembered.weight : seed, weight_unit)
  end

  # Whether it can carry a weight when done with its own gear: it has one to
  # start at (or a program sets one, or "no weight" is remembered), or
  # that gear comes in set weights (as Step#takes_weight?).
  def takes_weight?(weight)
    !!(weight || remembered || equipment.any?(&:unit))
  end

  # A weight from a client, converted to `target` (by default the unit this
  # exercise's gear in set weights comes in; a step passes its own,
  # Step#gear_unit) and snapped to an owned weight it rounds from. Without
  # such gear it keeps the unit given. Anything that is not a number in a
  # known unit goes through as given, for validation to reject.
  def in_weight_unit(value, unit, target = gear_unit)
    number = value.is_a?(Numeric) ? value : Float(value, exception: false)
    return { value:, unit: } unless number && ExerciseWeight::UNITS.include?(unit)

    target ||= unit
    Weights.normalize({ value: number.to_f, unit: }, target, Equipment.owned_weights(target))
  end

  def as_json(*)
    {
      id:, slug:, name:, category:, areas:, pattern:, cues:, mistakes:, equipment: equipment_slugs, unilateral:, alternating:, weights_held:,
      default_reps:, default_seconds:, instructions:, animation:
    }
  end

  def validate
    super
    validates_includes [1, 2], :weights_held, message: "must be 1 or 2"
    validates_presence %i[slug name]
    validates_unique :slug
    validates_includes CATEGORIES, :category
    validates_includes PATTERNS, :pattern, allow_nil: true
    validates_number :default_reps, :default_seconds, only_integer: true, greater_than: 0, allow_nil: true
    errors.add(:base, "needs default reps or default seconds, not both") if default_reps && default_seconds
    errors.add(:base, "is either done one side at a time or alternates sides, not both") if unilateral && alternating

    unknown = Array(areas) - AREAS
    errors.add(:areas, "unknown: #{unknown.join(", ")}") if unknown.any?
    Animation.problems(animation).each { errors.add(:animation, it) } if animation
  end
end
