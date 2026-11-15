require "securerandom"

# A workout's whole structure, its blocks and their steps, written in one go
# from a plain description: what the builder sends (POST and PUT
# /api/workouts) and what the MCP tools send.
#
#   [{ "id"?, "label", "rounds"?, "rest_seconds"?, "steps" => [{
#      "id"?, "exercise_id" (or "exercise", its slug), "reps"? or
#      "duration_seconds"?, "tempo"?,
#      "weight"? => { "value", "unit"? } (or the value alone), "weights_held"?, "per_side"?,
#      "note"?, "equipment"? => [slug] }] }]
#
# The description replaces what is there, in its order. Blocks and steps that
# name their `id` are updated in place, so the sets logged against a step keep
# their link; a step given another exercise becomes a new step, as in the seed
# loader. Blocks and steps left out are deleted, and their logged sets stay,
# unlinked, since each carries what history needs. Fields left out take their
# defaults: one round, no rest, no weight, the exercise's own equipment and
# sides; a weight without a unit is in the exercise's unit.
#
# Everything is checked before anything is written. With one problem anywhere
# nothing changes, and `Invalid` names each block and step at fault.
class WorkoutStructure
  BLOCK_KEYS = %w[id label rounds rest_seconds steps].freeze
  STEP_KEYS = %w[id exercise_id reps duration_seconds tempo weight weights_held per_side note equipment].freeze
  # What GET /api/workouts/:id adds to each, ignored here, so a workout read
  # can be edited and sent back as it is. `suggestion` is what an older GET
  # gave (until #264), for a page still on that release.
  BLOCK_EXTRAS = %w[position].freeze
  STEP_EXTRAS = %w[position exercise equipment_needed target weight_unit allowed_weights suggestion].freeze
  WEIGHT_KEYS = %w[value unit].freeze
  # How big one workout can be: the player walks every round of every step,
  # so rounds x steps is bounded as well as each part (#204).
  MAX_BLOCKS = 12
  MAX_STEPS = 30
  MAX_STEP_ROUNDS = 300
  # Model attributes by the name the description gives them.
  FIELDS = { weight_value: "weight.value", weight_unit: "weight.unit" }.freeze

  # What is wrong: `fields` has each problem under the path of the value at
  # fault, counted from 0 as in the request ("blocks[1].steps[0].reps"); the
  # message names the block and step counted from 1, as a person reads them.
  class Invalid < StandardError
    attr_reader :fields

    def initialize(problems)
      @fields = problems.group_by(&:first).transform_values { |list| list.map { it[1] } }
      super(problems.map(&:last).join("; "))
    end
  end

  def initialize(workout, blocks)
    @workout = workout
    @input = blocks
    @problems = []
  end

  # Checks the description, and the workout's own fields with it; raises
  # Invalid, listing every problem, when anything is wrong. Writes nothing.
  def check!
    load_records
    @plan = read
    collect(@workout, nil, nil)
    raise Invalid, @problems if @problems.any?
  end

  # Writes what check! passed. Run both in a transaction, saving the workout
  # in between.
  def write!
    save(@plan)
  end

  private

  def load_records
    @blocks = @workout.new? ? {} : @workout.blocks.index_by(&:id)
    @steps = Step.where(block_id: @blocks.keys).eager(:equipment).all.index_by(&:id)
    steps = Array(@input).grep(Hash).flat_map { Array(it.transform_keys(&:to_s)["steps"]).grep(Hash) }.map { it.transform_keys(&:to_s) }
    refs = steps.filter_map { exercise_ref(it) }
    found = Exercise.eager(:equipment).where(Sequel.|({ id: refs.filter_map { id(it) } }, { slug: refs.map(&:to_s) })).all
    @exercises = found.index_by(&:id).merge(found.index_by(&:slug))
    @equipment = Equipment.current.where(slug: steps.flat_map { Array(it["equipment"]) }.map(&:to_s)).all.index_by(&:slug)
    @seen = {}
  end

  # The blocks to write, each with its steps and their equipment, in order.
  def read
    return add("blocks", "Blocks", "must be a list of blocks") || [] unless @input.is_a?(Array)
    return add("blocks", "Blocks", "needs at least one block") || [] if @input.empty?
    return add("blocks", "Blocks", "can be at most #{MAX_BLOCKS} blocks") || [] if @input.size > MAX_BLOCKS

    labels = {}
    @input.each_with_index.filter_map do |attrs, index|
      path, where = "blocks[#{index}]", "Block #{index + 1}"
      next add(path, where, "must be an object") unless attrs.is_a?(Hash)

      attrs = attrs.transform_keys(&:to_s)
      label = attrs["label"]&.to_s&.strip
      where = "#{where} (#{label})" if label.present?
      unknown_keys(attrs.except(*BLOCK_EXTRAS), BLOCK_KEYS, path, where)

      block = kept(@blocks, attrs["id"], path, where, "block") || Block.new
      block.set(label:, position: index + 1, rounds: attrs["rounds"] || 1, rest_seconds: attrs["rest_seconds"] || 0)
      collect(block, path, where)
      if label.present? && labels.key?(label)
        add("#{path}.label", where, "is already the label of block #{labels[label] + 1}", "Label #{label} is already the label of block #{labels[label] + 1}")
      end
      labels[label] ||= index

      [block, read_steps(block, attrs["steps"], path, where)]
    end.tap { too_long(it) }
  end

  # Every round of every step is a screen of the player, one a side for a
  # step done one side at a time: refused past MAX_STEP_ROUNDS in all, even
  # when each block is within its own bounds (a block out of them says so
  # itself).
  def too_long(plan)
    return unless plan.all? { |block, _| block.rounds.is_a?(Integer) && block.rounds.between?(1, Block::MAX_ROUNDS) }

    total = plan.sum { |block, steps| block.rounds * steps.sum { |step, _| step.sides } }
    return if total <= MAX_STEP_ROUNDS

    add("blocks", "Blocks", "add up to #{total} steps across their rounds and sides; a workout can have at most #{MAX_STEP_ROUNDS}")
  end

  def read_steps(block, list, path, where)
    unless list.is_a?(Array) && list.any?
      add("#{path}.steps", where, list.nil? || list.is_a?(Array) ? "needs at least one step" : "must be a list of steps")
      return []
    end
    return add("#{path}.steps", where, "can be at most #{MAX_STEPS} steps") || [] if list.size > MAX_STEPS

    list.each_with_index.filter_map do |attrs, index|
      read_step(block, attrs, index + 1, "#{path}.steps[#{index}]", "#{where}, step #{index + 1}")
    end
  end

  def read_step(block, attrs, position, path, where)
    return add(path, where, "must be an object") unless attrs.is_a?(Hash)

    attrs = attrs.transform_keys(&:to_s)
    exercise = exercise_for(attrs, @steps[id(attrs["id"])], path, where)
    where = "#{where} (#{exercise.slug})" if exercise
    unknown_keys(attrs.except(*STEP_EXTRAS), STEP_KEYS, path, where)

    step = kept(@steps, attrs["id"], path, where, "step")
    # Another exercise is another step: the sets logged for the old one keep
    # their link only while the step still means the same exercise.
    step = nil if step && exercise && step.exercise_id != exercise.id
    step ||= Step.new
    value, unit = weight(attrs["weight"], exercise, path, where)
    step.set(
      exercise:, position:,
      reps: attrs["reps"], duration_seconds: attrs["duration_seconds"],
      tempo: attrs["tempo"].to_s.strip.presence, weight_value: value, weight_unit: unit,
      weights_held: attrs["weights_held"], per_side: attrs["per_side"],
      note: attrs["note"].to_s.strip.presence
    )
    collect(step, path, where)
    [step, equipment(attrs["equipment"], exercise, path, where)]
  end

  # The step's exercise id, its slug as `exercise`, or the id of the
  # exercise GET gives it.
  def exercise_ref(attrs)
    given = attrs["exercise"]
    attrs["exercise_id"] || (given.is_a?(Hash) ? given.transform_keys(&:to_s)["id"] : given)
  end

  # The step's exercise: one in the library, or a retired one a step of
  # this workout already has, so the workout still saves as it is.
  def exercise_for(attrs, kept, path, where)
    value = exercise_ref(attrs)
    return add("#{path}.exercise_id", where, "is required", "Exercise is required: its exercise_id, or its slug as exercise") if value.nil?

    exercise = @exercises[id(value) || value.to_s]
    return exercise if exercise && (!exercise.retired || kept&.exercise_id == exercise.id)

    key = attrs.key?("exercise_id") ? "exercise_id" : "exercise"
    add("#{path}.#{key}", where, "names no exercise in the library", "Exercise #{value} is not in the library")
  end

  # The step's weight as value and unit, kept in the exercise's unit as
  # every weight of it is: one sent in the other unit is converted and
  # snapped to an owned weight. Without a unit, it is in the exercise's.
  # A number alone is the value, in the exercise's unit.
  def weight(value, exercise, path, where)
    return [nil, nil] if value.nil?

    value = { "value" => value } if value.is_a?(Numeric)
    return add("#{path}.weight", where, "must be a number, or an object with its value", "Weight must be a number such as 20, or an object such as {\"value\": 20, \"unit\": \"lb\"}") || [nil, nil] unless value.is_a?(Hash)

    value = value.transform_keys(&:to_s)
    unknown_keys(value, WEIGHT_KEYS, "#{path}.weight", where)
    if value["value"].nil? && value["unit"]
      sent = JSON.generate(value)
      return add("#{path}.weight.value", where, "is required", "Weight #{sent} has no value: send {\"value\": 20, \"unit\": \"lb\"} with the number, or leave weight out for none") || [nil, nil]
    end
    return [value["value"], value["unit"]] if value["value"].nil? || exercise.nil?

    weight = exercise.in_weight_unit(value["value"], value["unit"] || exercise.weight_unit)
    weight.values_at(:value, :unit)
  end

  # The step's own gear; none (null or left out) follows the exercise. What
  # its exercise names anyway is no gear of its own either.
  def equipment(slugs, exercise, path, where)
    return [] if slugs.nil?
    return add("#{path}.equipment", where, "must be a list of equipment slugs", "Equipment must be a list of equipment slugs") || [] unless slugs.is_a?(Array)

    slugs = slugs.map(&:to_s).uniq
    unknown = slugs - @equipment.keys
    add("#{path}.equipment", where, "names unknown equipment: #{unknown.join(", ")}", "Equipment #{unknown.join(", ")} is unknown: no equipment has that slug") if unknown.any?
    return [] if exercise&.same_gear?(slugs)

    @equipment.values_at(*slugs).compact
  end

  # The block or step of this workout an `id` names, once only; nil for a new one.
  def kept(records, value, path, where, noun)
    return if value.nil?

    record = records[id(value)]
    return add("#{path}.id", where, "is not a #{noun} of this workout", "Id #{value} is not a #{noun} of this workout") unless record

    key = [noun, record.id]
    return add("#{path}.id", where, "names the same #{noun} as #{@seen[key]}", "Id #{value} is named twice") if @seen.key?(key)

    @seen[key] = path
    record
  end

  def id(value) = Record.id(value)

  def unknown_keys(attrs, known, path, where)
    (attrs.keys - known).each do |key|
      add("#{path}.#{key}", where, "is not a field here (use #{known.join(", ")})", "#{key} is not a field here (use #{known.join(", ")})")
    end
  end

  def collect(record, path, where)
    return if record.valid?

    record.errors.each do |attribute, messages|
      field = FIELDS.fetch(attribute, attribute).to_s unless attribute == :base
      messages.each do |message|
        add([path, field].compact.join(".").presence || "base", where, message, record.errors.full_message(attribute, message))
      end
    end
  end

  # Notes a problem and returns nil. Without a `where`, it is the workout's own.
  def add(path, where, problem, full = problem)
    @problems << [path, problem, where ? "#{where}: #{full}" : full]
    nil
  end

  # Writes the plan. Positions and labels are unique within their block and
  # workout, so what stays is first moved out of the way: kept steps to a
  # negative position, every existing block to a label no request can name.
  def save(plan)
    kept_steps = plan.flat_map(&:last).map(&:first).reject(&:new?)
    Step.remove!(@steps.keys - kept_steps.map(&:id))
    Step.where(id: kept_steps.map(&:id)).update(position: Sequel[:id] * -1)
    Block.where(id: @blocks.keys).update(label: Sequel.join(["moving-#{SecureRandom.hex(8)}-", :id]))

    # A plain save writes every column, so the labels and positions moved
    # aside above are written back from these records. Keep it plain:
    # save_changes would leave them moved aside.
    plan.each do |block, steps|
      block.set(workout_id: @workout.id).save
      steps.each do |step, equipment|
        step.set(block_id: block.id, equipment_pks: equipment.map(&:id)).save
      end
    end
    Block.where(id: @blocks.keys - plan.map { it.first.id }).delete
    @workout.associations.delete(:blocks)
  end
end
