# frozen_string_literal: true

# A user's program: one imported from an example (Example, db/examples),
# whose slug `example_slug` keeps.
class Program < Record
  per_user
  # Its workouts in order, archived ones left out.
  one_to_many :workouts, key: %i[user_id program_id], primary_key: %i[user_id id], order: :position, conditions: { archived_at: nil }

  def as_json(*)
    { id:, example_slug:, name:, description:, workouts: workouts.map(&:summary) }
  end

  def validate
    super
    validates_presence :name
    validates_includes Workout::SOURCES, :source
  end
end
