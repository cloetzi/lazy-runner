# frozen_string_literal: true

# A user's settings, one row each: the unit weights are shown in (lb or kg)
# and the one distances are (km or mi). Weights are still kept in each
# exercise's own unit, and distances in metres; this is how they are shown,
# and the unit for exercises whose equipment has none.
class Setting < Record
  per_user

  # The signed-in user's, made with the defaults on first use; in a
  # transaction, so two first requests at once can't both make one.
  def self.current = first || db.transaction { first || create }

  def self.unit = current.unit

  DISTANCE_UNITS = %w[km mi].freeze

  def after_save
    super
    UserEquipment.forget_units!
  end

  def as_json(*)
    { unit:, distance_unit:, updated_at: }
  end

  def validate
    super
    validates_includes ExerciseWeight::UNITS, :unit
    validates_includes DISTANCE_UNITS, :distance_unit
  end
end
