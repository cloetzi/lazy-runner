# What a user has of an item in the equipment catalogue: whether they own it
# and, for fixed-weight equipment such as dumbbells, the weights they own and
# the unit they come in. An item without a row is not owned.
#
# `unit` is null until the user sets it or lists weights: the item follows
# the user's unit (Settings) until then, and keeps its own after (clearing
# the weights included), so changing Settings later doesn't turn 20 lb
# dumbbells into 20 kg ones.
class UserEquipment < Record.Model(:user_equipment)
  per_user
  json_columns weights: []

  many_to_one :equipment

  # The unit of the signed-in user's `item`, nil for gear without weights:
  # their row's, else their unit (Settings). An any_weight item's is the one
  # all the owned weights listed come in (Equipment.fixed), else Settings'.
  # Read once per request.
  def self.unit_of(item)
    return unless item.unit

    units = gear_units
    return units[:any_weight] || units[:default] if item.any_weight

    units[:rows][item.id] || units[:default]
  end

  def self.gear_units
    user = Current.user!.id
    cached = Current.gear_units
    return cached if cached&.dig(:user) == user

    default = Setting.unit
    weighted = where(owned: true, equipment_id: Equipment.weighted.select(:id)).all
               .select { it.weights.any? }.map { it.unit || default }.uniq
    Current.gear_units = {
      user:, default:, rows: exclude(unit: nil).select_hash(:equipment_id, :unit), any_weight: (weighted.first if weighted.one?)
    }
  end

  # Forgets what gear_units read, after the user's gear or unit changed.
  def self.forget_units! = Current.gear_units = nil

  def weights_in
    unit = self.unit || self.class.unit_of(equipment)
    weights.map { { value: it.to_f, unit: } }
  end

  def before_validation
    super
    # Listing weights settles the unit they were listed in.
    self.unit ||= Setting.unit if weights.is_a?(Array) && weights.any? && equipment&.unit
  end

  def after_save
    super
    self.class.forget_units!
  end

  def after_destroy
    super
    self.class.forget_units!
  end

  def validate
    super
    return errors.add(:equipment, "is any dumbbell or kettlebell you own: mark those instead") if equipment&.any_weight
    return errors.add(:weights, "must be a list") unless weights.is_a?(Array)

    errors.add(:weights, "must be positive numbers") unless weights.all? { it.is_a?(Numeric) && it.positive? }
    errors.add(:weights, "can only be listed for equipment with a unit, such as dumbbells") if weights.any? && equipment&.unit.nil?
    return if unit.nil?

    validates_includes ExerciseWeight::UNITS, :unit
    errors.add(:unit, "can only be set for equipment with weights, such as dumbbells") if equipment&.unit.nil?
  end
end
