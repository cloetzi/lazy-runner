# frozen_string_literal: true

require "yaml"

# Tunable rules from config/coach.yml: the weight stepper's increments, which
# the app hands to the PWA (`weight_steps`); public/js/weights.js steps by them.
module Coach
  def self.config
    @config ||= YAML.safe_load_file(Rage.root.join("config/coach.yml"), aliases: true).freeze
  end

  def self.weight_steps = config.fetch("weight_steps")
end
