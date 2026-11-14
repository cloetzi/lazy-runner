require "yaml"

# Tunable coaching rules from config/coach.yml: weight increments and the
# next-time suggestion thresholds.
module Coach
  def self.config
    @config ||= YAML.safe_load_file(Rage.root.join("config/coach.yml"), aliases: true).freeze
  end

  def self.weight_steps = config.fetch("weight_steps")

  def self.suggestions = config.fetch("suggestions")

  # One stepper increment up or down from a weight. With `allowed` weights
  # (fixed-weight equipment the user owns, in `unit`) it moves to the next one
  # owned, and stays put when there is none further. Otherwise it steps by
  # band: bands are by weight, so light weights move in smaller steps;
  # stepping down uses the band just below the weight, so 15 lb goes down to
  # 12.5 and back up to 15.
  def self.step_weight(value, unit, equipment, direction, allowed: nil)
    raise ArgumentError, "unknown direction #{direction}" unless %w[up down].include?(direction)
    return step_owned(value, allowed, direction) if allowed.present?

    bands = weight_bands(unit, equipment)
    if direction == "up"
      value + bands.find { it["below"].nil? || value < it["below"] }.fetch("step")
    else
      [value - bands.find { it["below"].nil? || value <= it["below"] }.fetch("step"), 0].max
    end
  end

  def self.step_owned(value, allowed, direction)
    tolerance = 0.01
    if direction == "up"
      allowed.select { it > value + tolerance }.min || value
    else
      allowed.select { it < value - tolerance }.max || value
    end
  end

  def self.weight_bands(unit, equipment)
    kind = Array(equipment).find { weight_steps.key?(it) } || "default"
    weight_steps.fetch(kind)[unit] || weight_steps.fetch("default").fetch(unit)
  end
end
