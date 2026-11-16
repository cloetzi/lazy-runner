# frozen_string_literal: true

# A circuit of a workout, whose user's it is.
class Block < Record
  # A workout is something a person does in one go: these bound what one
  # block can ask for (the builder's own steppers stay well inside them),
  # so no workout makes the player plan do unbounded work.
  MAX_ROUNDS = 20
  MAX_REST_SECONDS = 600
  MAX_LABEL = 60

  # The signed-in user's: those of their workouts (see Record.per_user).
  per_user(:workout_id) { Workout.select(:id) }
  many_to_one :workout
  one_to_many :steps, order: :position

  def estimated_seconds
    (rounds * steps.sum(&:estimated_seconds)) + ((rounds - 1) * rest_seconds)
  end

  def as_json(*)
    { id:, label:, position:, rounds:, rest_seconds:, steps: steps.map(&:as_json) }
  end

  def validate
    super
    validates_presence :label
    validates_max_length MAX_LABEL, :label, allow_nil: true, message: "is longer than #{MAX_LABEL} characters"
    validates_number :rounds, only_integer: true, at_least: 1, at_most: MAX_ROUNDS
    validates_number :rest_seconds, only_integer: true, at_least: 0, at_most: MAX_REST_SECONDS
    # Ready to run, as a workout checks before it is saved for good.
    errors.add(:base, "needs at least one step") if validation_context == :publish && steps.empty?
  end
end
