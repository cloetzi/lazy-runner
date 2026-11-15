# Weight arithmetic shared by everything that stores or compares a weight.
# Weights are { value:, unit: } hashes, kept in the unit of the gear they are
# for (Exercise#weight_unit, Step#gear_unit); anything given in the other unit
# is converted on the way in, and snapped to an owned weight when it is that
# weight rounded.
module Weights
  KG_PER_LB = 0.45359237
  # The app shows converted weights to the nearest 0.5 kg or lb, so anything
  # within half of that of a weight is the same weight shown in the other unit.
  TOLERANCE = { "kg" => 0.25, "lb" => 0.25 / KG_PER_LB }.freeze

  # The weight in `unit`, kept to the two decimals the database stores.
  def self.convert(weight, unit)
    return weight if weight.nil? || unit.nil? || weight[:unit] == unit

    factor = unit == "kg" ? KG_PER_LB : 1 / KG_PER_LB
    { value: (weight[:value] * factor).round(2), unit: }
  end

  # The weight in `unit`, snapped to one of the `allowed` values (in `unit`)
  # when it is within the tolerance of it.
  def self.normalize(weight, unit, allowed = nil)
    converted = convert(weight, unit)
    return converted unless converted && allowed

    owned = allowed.find { (it - converted[:value]).abs <= TOLERANCE.fetch(unit) }
    owned ? { value: owned.to_f, unit: } : converted
  end

  # Whether two weights are the same once in one unit, within the tolerance.
  def self.same?(a, b)
    return a.nil? && b.nil? if a.nil? || b.nil?

    (a[:value] - convert(b, a[:unit])[:value]).abs <= TOLERANCE.fetch(a[:unit])
  end
end
