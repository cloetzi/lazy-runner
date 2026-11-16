# frozen_string_literal: true

require "yaml"

# An example program, read from db/examples/<slug>.yml: a user imports one
# to have its workouts as their own (#183). Nothing of it is stored until
# then, and an imported copy is an ordinary program of the user's
# (`source: user`, or `llm` through MCP), editable like any workout of
# theirs; `example_slug` notes where it came from.
class Example
  DIR = Rage.root.join("db/examples")
  STEP_KEYS = %w[exercise reps seconds tempo weight unit per_side equipment note weights_held].freeze

  # The example is broken: a bug in db/examples, named in the message.
  class Error < StandardError; end
  # Imported before, and a second copy wasn't asked for.
  class AlreadyImported < StandardError; end

  # What an import or the list reads of the library, loaded once for all
  # the steps: exercises and equipment by slug, and the user's fixed-weight gear.
  Library = Data.define(:exercises, :equipment, :fixed)

  attr_reader :slug, :name, :description, :workouts

  # Read once: the files change only with a release.
  def self.all
    @all ||= Dir[DIR.join("*.yml")].map { new(File.basename(it, ".yml"), YAML.safe_load_file(it)) }.freeze
  end

  # Imports every example for a stand-in account, then rolls it all back:
  # run on boot, after the seeds, so an example the library or the model
  # rules no longer fit stops the server rather than a user's import.
  def self.check_all!
    DB.transaction(savepoint: true, rollback: :always) do
      user = User.create(username: "lazy-runner:example-check")
      Current.set(user:, gear_units: nil) { all.each(&:import!) }
    end
  end

  # The library as an import or the list reads it, loaded once: every
  # exercise and piece of equipment by slug, and with `fixed` the signed-in
  # user's fixed-weight gear.
  def self.library(fixed: false)
    Library.new(
      exercises: Exercise.current.eager(:equipment).all.index_by(&:slug),
      equipment: Equipment.current.all.index_by(&:slug),
      fixed: fixed ? Equipment.fixed : {}
    )
  end

  def self.find!(slug)
    all.find { it.slug == slug } || raise(Record::NotFound.new(self, slug, "no example program #{slug}"))
  end

  def initialize(slug, attrs)
    @slug = slug
    @name = attrs.fetch("name")
    @description = attrs["description"]
    @workouts = attrs.fetch("workouts")
  end

  # The signed-in user's copies of it with a workout left: one whose
  # workouts were all archived no longer counts.
  def imports = Program.where(example_slug: slug, id: Workout.active.select(:program_id))

  # Raises Error unless every step names exercises and equipment in the
  # library, with keys it knows.
  def check!(library)
    workouts.each do |workout|
      workout.fetch("blocks", []).each do |block|
        where = "#{slug}: #{workout["slug"]} #{block["label"]}"
        block.fetch("steps", []).each { check_step(it, where, library) }
      end
    end
  end

  # What the examples list shows: each workout with its minutes (a main
  # workout's own, without its warm-up and cool-down) and its exercises, the
  # gear it needs and whether the user has imported it. `gear` marks each
  # piece the user owns (`owned`, slugs), and `missing_exercises` counts the
  # exercises that need gear they don't have, so the best fit can go first.
  # Lists pass `owned` in, read once for all the examples.
  def as_json(library = Example.library, owned: Equipment.owned.select_map(:slug))
    needs = workouts.flat_map { steps_of(it) }.map { [it["exercise"], gear_of(it, library)] }
    slugs = needs.flat_map(&:last).uniq
    {
      slug:, name:, description:,
      workouts: workouts.map do |w|
        {
          slug: w.fetch("slug"), kind: w.fetch("kind"), title: w.fetch("title"), subtitle: w["subtitle"],
          estimated_minutes: minutes(w, library),
          exercises: steps_of(w).map { library.exercises.fetch(it["exercise"]).name }.uniq
        }
      end,
      equipment: slugs,
      gear: slugs.map { { slug: it, name: library.equipment.fetch(it).name, owned: owned.include?(it) } },
      missing_exercises: needs.reject { |_, gear| (gear - owned).empty? }.map(&:first).uniq.size,
      imported: !imports.empty?
    }
  end

  # Copies it into the signed-in user's programs and returns the program.
  # A second import raises AlreadyImported unless `copy`, which adds another
  # ("... (copy)", "... (copy 2)"). Each step's weight snaps to the nearest
  # one the user owns of its gear, and is left out when they own none of it;
  # a step needing gear they lack is kept, for the swap picker.
  def import!(copy: false, source: "user")
    library = Example.library(fixed: true)
    check!(library)
    Program.db.transaction do
      # Counted inside the transaction, so two imports at once can't both see none.
      before = imports.count
      raise AlreadyImported, "#{name} is already imported; import it again with copy to add another" if before.positive? && !copy

      copy_name = { 0 => name, 1 => "#{name} (copy)" }.fetch(before) { "#{name} (copy #{before})" }
      program = save!(name) { Program.create(example_slug: slug, name: copy_name, description:, source:) }
      workouts.each_with_index { |attrs, index| import_workout(program, attrs, index + 1, source, library) }
      program
    end
  end

  private

  def steps_of(workout) = workout.fetch("blocks", []).flat_map { it.fetch("steps", []) }

  # The gear a step needs: its own, else its exercise's.
  def gear_of(step, library) = step["equipment"].presence || library.exercises.fetch(step["exercise"]).equipment_slugs

  def check_step(attrs, where, library)
    unknown = attrs.keys - STEP_KEYS
    raise Error, "#{where}: unknown step keys #{unknown.join(", ")}" if unknown.any?
    raise Error, "#{where}: a unit needs a weight" if attrs["unit"] && !attrs["weight"]
    raise Error, "#{where}: unknown exercise '#{attrs["exercise"]}'" unless library.exercises.key?(attrs["exercise"])

    missing = attrs.fetch("equipment", []).reject { library.equipment.key?(it) }
    raise Error, "#{where}: unknown equipment '#{missing.join(", ")}'" if missing.any?
  end

  # As Workout#estimated_minutes works it out, on unsaved records.
  def minutes(workout, library)
    blocks = workout.fetch("blocks", []).map do |attrs|
      Block.new(rounds: attrs.fetch("rounds", 1), rest_seconds: attrs.fetch("rest_seconds", 0)).tap do |block|
        block.associations[:steps] = attrs.fetch("steps", []).map { step_from(it, library.exercises.fetch(it["exercise"])) }
      end
    end
    Workout.new.tap { it.associations[:blocks] = blocks }.estimated_minutes
  end

  def import_workout(program, attrs, position, source, library)
    slug = attrs.fetch("slug")
    workout = save!(slug) do
      Workout.create(
        program_id: program.id, example_slug: slug, position:, source:,
        kind: attrs.fetch("kind"), title: attrs.fetch("title"), subtitle: attrs["subtitle"]
      )
    end
    attrs.fetch("blocks", []).each_with_index do |block_attrs, index|
      block = save!("#{slug} #{block_attrs["label"]}") do
        Block.create(
          workout_id: workout.id, label: block_attrs.fetch("label").to_s, position: index + 1,
          rounds: block_attrs.fetch("rounds", 1), rest_seconds: block_attrs.fetch("rest_seconds", 0)
        )
      end
      block_attrs.fetch("steps", []).each_with_index do |step_attrs, step_index|
        import_step(block, step_attrs, step_index + 1, "#{slug} #{block.label}", library)
      end
    end
    save!(slug) { workout.refresh.validate!(:publish) }
  end

  def import_step(block, attrs, position, where, library)
    exercise = library.exercises.fetch(attrs["exercise"])
    gear = attrs.fetch("equipment", [])
    step = step_from(attrs, exercise)
    step.set(block_id: block.id, position:, equipment_pks: gear.uniq.map { library.equipment.fetch(it).id })
    weight = snapped(step, attrs, gear.presence || exercise.equipment_slugs, library)
    step.set(weight_value: weight&.dig(:value), weight_unit: weight&.dig(:unit))
    save!("#{where} step #{position} (#{exercise.slug})") { step.save }
  end

  # A step as the YAML gives it, unsaved.
  def step_from(attrs, exercise)
    Step.new(
      reps: attrs["reps"], duration_seconds: attrs["seconds"], tempo: attrs["tempo"]&.to_s,
      per_side: attrs.fetch("per_side", exercise.unilateral), note: attrs["note"], weights_held: attrs["weights_held"]
    ).tap { it.exercise = exercise }
  end

  # The step's weight in the unit of the gear it is done with (Step.unit_for),
  # snapped to the nearest owned weight for gear that comes in set weights;
  # nil with none of it owned.
  def snapped(step, attrs, gear, library)
    return unless attrs["weight"]

    unit = Step.unit_for(gear.filter_map { library.equipment[it] }, step.exercise) || Setting.unit
    weight = Weights.convert({ value: attrs["weight"].to_f, unit: attrs["unit"] || "lb" }, unit)
    return weight unless gear.any? { library.equipment[it]&.unit }

    allowed = Equipment.allowed_for(gear, weight[:unit], library.fixed)
    nearest = allowed&.min_by { [(it - weight[:value]).abs, it] }
    nearest && { value: nearest.to_f, unit: weight[:unit] }
  end

  # Runs a save, turning a failed validation into an error naming the record.
  def save!(name)
    yield
  rescue Sequel::ValidationFailed => error
    raise Error, "#{slug}: #{name}: #{error.errors.full_messages.join(", ")}"
  end
end
