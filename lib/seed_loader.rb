require "yaml"

# Loads the equipment catalogue and the exercise library from db/seeds/*.yml,
# shared by every user, and checks that the example programs (db/examples,
# Example) name only what is in it. Programs are not seeded: a user imports
# the examples.
#
# Idempotent: records are matched by slug and updated in place, so ids stay
# stable across loads. An exercise dropped from the seeds leaves the library,
# or is retired while steps or logged sets still name it; equipment dropped
# from the seeds is retired, so what users owned of it comes back with it.
class SeedLoader
  class Error < StandardError; end

  def self.load!(dir = Rage.root.join("db/seeds"))
    new(dir).tap(&:load!)
  end

  def initialize(dir)
    @dir = Pathname(dir)
  end

  def load!
    DB.transaction do
      equipment = load_equipment
      exercises = load_exercises(equipment)
      prune_exercises(exercises.keys)
      prune_equipment(equipment.keys)
      # The examples name the library by slug: one it no longer fits stops the boot.
      Example.check_all!
    end
  end

  private

  def read(name)
    YAML.safe_load_file(@dir.join(name)) || []
  end

  def load_equipment
    read("equipment.yml").each_with_index.to_h do |attrs, index|
      item = Equipment.find_or_new(slug: attrs.fetch("slug"))
      save!(item.slug) { item.update(name: attrs.fetch("name"), position: index + 1, unit: attrs["unit"], any_weight: attrs.fetch("any_weight", false), retired: false) }
      [item.slug, item]
    end
  end

  def load_exercises(equipment)
    read("exercises.yml").to_h do |attrs|
      exercise = Exercise.find_or_new(slug: attrs.fetch("slug"))
      needs = attrs.fetch("equipment", []).map do |slug|
        equipment.fetch(slug) { raise Error, "#{exercise.slug}: unknown equipment '#{slug}'" }
      end
      save!(exercise.slug) do
        exercise.update(
          name: attrs.fetch("name"),
          category: attrs.fetch("category"),
          areas: attrs.fetch("areas", []),
          pattern: attrs["pattern"],
          cues: attrs.fetch("cues", []),
          mistakes: attrs.fetch("mistakes", []),
          equipment_pks: needs.map(&:id),
          unilateral: attrs.fetch("unilateral", false),
          alternating: attrs.fetch("alternating", false),
          weights_held: attrs.fetch("weights_held", 1),
          default_reps: attrs["default_reps"],
          default_seconds: attrs["default_seconds"],
          instructions: attrs.fetch("instructions", []),
          animation: attrs["animation"],
          retired: false
        )
      end
      [exercise.slug, exercise]
    end
  end

  # Runs a save, turning a failed validation into an error that names the record.
  def save!(name)
    yield
  rescue Sequel::ValidationFailed => e
    raise Error, "#{name}: #{e.errors.full_messages.join(", ")}"
  end

  # An exercise dropped from the seeds leaves the library, with every user's
  # remembered weight and suggestions. One still used by a step is kept; one
  # with logged sets is retired, so its history stays.
  def prune_exercises(slugs)
    Exercise.exclude(slug: slugs).exclude(id: Step.everyone.select(:exercise_id)).all.each do |exercise|
      ExerciseWeight.everyone.where(exercise_id: exercise.id).delete
      WeightSuggestion.everyone.pending.where(exercise_id: exercise.id).delete
      if SetLog.everyone.where(Sequel.|({ exercise_id: exercise.id }, { planned_exercise_id: exercise.id })).empty?
        WeightSuggestion.everyone.where(exercise_id: exercise.id).delete
        exercise.destroy
      else
        exercise.update(retired: true)
      end
    end
  end

  # Equipment dropped from the seeds leaves the catalogue and every exercise
  # and step, users' own workouts included. It is retired rather than
  # deleted, so whether users owned it, and which weights, comes back with
  # it (its place in their steps does not).
  def prune_equipment(slugs)
    gone = Equipment.current.exclude(slug: slugs).select(:id)
    DB[:exercise_equipment].where(equipment_id: gone).delete
    DB[:step_equipment].where(equipment_id: gone).delete
    Equipment.where(id: gone).update(retired: true, updated_at: Time.now)
  end
end
