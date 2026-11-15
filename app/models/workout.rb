# A warm-up, main workout or cool-down, of one user: in a program (one
# imported from an example, db/examples) or standing alone, the user's own
# or an assistant's (`llm`). Any of them can be edited, and they are archived
# rather than deleted so their sessions keep them. Class-level lookups are
# the signed-in user's (Current.user!).
class Workout < Record
  KINDS = %w[warmup workout cooldown].freeze
  FRAMES = %w[warmup cooldown].freeze
  SOURCES = %w[user llm].freeze
  # What the user can change in a workout of their own, besides its blocks.
  FIELDS = %w[title subtitle warmup cooldown].freeze
  MAX_LENGTHS = { title: 100, subtitle: 200 }.freeze

  # Raised for a change to an archived workout; the message says why.
  class ReadOnly < StandardError; end
  # Raised for a change to the blocks and steps of a workout a session is
  # running, which would pull them from under the player.
  class Running < StandardError; end

  per_user
  many_to_one :program, key: %i[user_id program_id], primary_key: %i[user_id id]
  many_to_one :warmup, class: self, key: %i[user_id warmup_id], primary_key: %i[user_id id]
  many_to_one :cooldown, class: self, key: %i[user_id cooldown_id], primary_key: %i[user_id id]
  one_to_many :blocks, order: :position

  dataset_module do
    where :active, archived_at: nil

    # The signed-in user's workouts, archived ones left out, with a step of
    # the exercise.
    def with_exercise(exercise)
      blocks = Block.where(id: Step.where(exercise_id: exercise.id).select(:block_id))
      active.where(id: blocks.select(:workout_id)).order(:id)
    end

    # With everything the player and the workout view read.
    def expanded = eager(blocks: { steps: [:equipment, { exercise: :equipment }] })
  end

  # What to train when nothing is planned: the next main workout of the
  # user's first program with one not archived, else of their own; nil when
  # there is none.
  def self.suggested
    Program.order(:id).all.lazy.filter_map { next_up(it) }.first ||
      next_of(active.where(kind: "workout", program_id: nil).order(:position, :id).all)
  end

  # The program's main workout after the last one done, in program order;
  # nil when the program has none.
  def self.next_up(program)
    next_of(program.workouts_dataset.where(kind: "workout").all)
  end

  # The workout after the last one of them done, round in order.
  def self.next_of(mains)
    last = Session.where(status: "done", workout_id: mains.map(&:id)).latest_first.first
    return mains.first unless last

    mains[(mains.index { it.id == last.workout_id } + 1) % mains.size]
  end

  # A new workout of the user's own (or, through MCP, an assistant's: `llm`),
  # standing alone, with its whole structure: `kind`, `title`, optional
  # `subtitle`, `warmup` and `cooldown`, and `blocks` as WorkoutStructure
  # reads them. Raises Sequel::ValidationFailed or WorkoutStructure::Invalid,
  # leaving nothing behind.
  def self.create_with!(attrs, source: "user")
    attrs = attrs.to_h.transform_keys(&:to_s)
    workout = new(source:, kind: attrs["kind"], position: next_own_position)
    # Blocks always: a new workout can't do without them.
    workout.revise!(attrs.slice(*FIELDS).merge("blocks" => attrs["blocks"]))
  end

  # Where a new workout of the user's goes: after their others.
  def self.next_own_position
    (where(program_id: nil).max(:position) || 0) + 1
  end

  # Every workout not archived, by program, as cards: the user's own (no
  # program) last, under "My workouts" (`id: nil`). `up_next` marks what
  # Today offers when nothing is planned.
  def self.catalog
    last_done = Session.where(status: "done").group(:workout_id).select_hash(:workout_id, Sequel.function(:max, :date).as(:last_done))
    up_next = suggested
    cards = ->(workouts) { workouts.map { it.card(up_next: it.id == up_next&.id, last_done: last_done[it.id]&.then { Date.iso8601(it.to_s) }) } }
    programs = Program.eager(workouts: { blocks: { steps: [:equipment, { exercise: :equipment }] } }).order(:id).all.map do |program|
      { id: program.id, name: program.name, workouts: cards.(program.workouts) }
    end
    # A program whose workouts were all archived has nothing to show.
    programs.reject! { it[:workouts].empty? }
    own = active.where(program_id: nil).eager(blocks: { steps: [:equipment, { exercise: :equipment }] }).order(:position, :id).all
    own.any? ? programs << { id: nil, name: "My workouts", workouts: cards.(own) } : programs
  end

  # The kinds named in a "warmup,cooldown" list (or array), or nil for all.
  def self.part_kinds(list)
    return nil if list.nil? || list == ""

    kinds = list.is_a?(Array) ? list.map(&:to_s) : list.to_s.split(",").map(&:strip)
    unknown = kinds - KINDS
    raise ArgumentError, "unknown parts: #{unknown.join(", ")}" if unknown.any?

    kinds
  end

  def archived? = !archived_at.nil?

  # Takes it out of the lists, and off the calendar from today on: its
  # sessions still planned from today go (nothing is logged in them), while
  # missed, skipped and done ones stay and show it as archived, and the
  # routines that run it end (Routine#end!). A warm-up or
  # cool-down also leaves the main workouts that pick it (`picked_by`), which
  # run without one from now on; while a session runs it, or a workout that
  # picks it, that raises Running. Returns the sessions taken off.
  def archive!
    db.transaction do
      if FRAMES.include?(kind)
        archiving = "it can be archived once that session is finished or skipped"
        refuse_while_running(archiving)
        # Nor may it leave a workout whose session leaves it out: that
        # workout's framing doesn't change while it runs.
        picked_by.all.each { it.refuse_while_running(archiving) }
      end
      update(archived_at: Time.now)
      picked_by.update("#{kind}_id": nil, "no_#{kind}": true, updated_at: Time.now) if FRAMES.include?(kind)
      removed = Session.where(workout_id: id, status: "planned", date: Time.zone.today..).in_order.all.each(&:destroy)
      # Its routines end too: their days could never be confirmed.
      Routine.where(workout_id: id).all.each { it.end! unless it.ended? }
      removed
    end
  end

  # The main workouts, archived ones left out, that run with this warm-up or
  # cool-down: those that pick it, and, when it is their program's, those of
  # the program that pick nothing; none for a main workout.
  def picked_by
    return Workout.where(false) unless FRAMES.include?(kind)

    picks = { "#{kind}_id": id }
    if program_id && program.workouts.find { it.kind == kind }&.id == id
      picks = Sequel.|(picks, { program_id:, kind: "workout", "#{kind}_id": nil, "no_#{kind}": false })
    end
    Workout.active.where(picks).order(:id)
  end

  # What the player runs for this workout: a main workout comes with its
  # warm-up and cool-down, or the ones of them `kinds` names (nil for both).
  # The workout itself is always there.
  def framed(kinds = nil)
    ids = framed_ids(kinds)
    found = Workout.expanded.where(id: ids).all.index_by(&:id)
    ids.map { found.fetch(it) }
  end

  # The ids of what `framed` gives, in order.
  def framed_ids(kinds = nil)
    [frame_id("warmup"), id, frame_id("cooldown")]
      .zip(%w[warmup workout cooldown])
      .filter_map { |part, kind| part if part && (kind == "workout" || kinds.nil? || kinds.include?(kind)) }
  end

  # The warm-up or cool-down a main workout runs with: its own, none when it
  # says so, else its program's.
  def frame_id(part)
    return unless kind == "workout" && !public_send("no_#{part}")

    public_send("#{part}_id") || program&.workouts&.find { it.kind == part }&.id
  end

  # How a main workout picks a warm-up or cool-down: a workout id, "none", or
  # nil for its program's.
  def frame_choice(part)
    public_send("no_#{part}") ? "none" : public_send("#{part}_id")
  end

  def choose_frame(part, choice)
    choice = nil if choice == ""
    set("no_#{part}" => choice == "none", "#{part}_id" => (choice unless choice == "none"))
  end

  # "<title> (copy)", the title cut short to leave room for it.
  def copy_title
    suffix = " (copy)"
    "#{title[0, MAX_LENGTHS[:title] - suffix.size].rstrip}#{suffix}"
  end

  # An editable copy, standing on its own: same blocks and steps, the same
  # warm-up and cool-down as it runs with now. The user's, or through MCP an
  # assistant's (`llm`).
  def duplicate!(title: nil, source: "user")
    db.transaction do
      copy = Workout.create(
        user_id:, source:, kind:, title: title.presence || copy_title, subtitle:,
        position: Workout.next_own_position,
        warmup_id: frame_id("warmup"), cooldown_id: frame_id("cooldown"),
        no_warmup: kind == "workout" && frame_id("warmup").nil?, no_cooldown: kind == "workout" && frame_id("cooldown").nil?
      )
      blocks_dataset.eager(steps: :equipment).all.each do |block|
        new_block = Block.create(workout_id: copy.id, **block.values.slice(:label, :position, :rounds, :rest_seconds))
        block.steps.each do |step|
          Step.create(
            block_id: new_block.id, equipment_pks: step.equipment.map(&:id),
            **step.values.slice(:exercise_id, :position, :reps, :duration_seconds, :tempo, :weight_value, :weight_unit, :per_side, :note, :weights_held)
          )
        end
      end
      copy.validate!(:publish)
    end
  end

  # Changes what `attrs` names and keeps the rest: `title`, `subtitle`,
  # `warmup` and `cooldown` (see choose_frame), and `blocks`, which replaces
  # the whole structure (see WorkoutStructure) and is refused while a session
  # runs the workout. All or nothing: raises ReadOnly, Running,
  # Sequel::ValidationFailed or WorkoutStructure::Invalid, changing nothing.
  def revise!(attrs)
    attrs = attrs.to_h.transform_keys(&:to_s)
    reason = read_only_reason
    raise ReadOnly, reason if reason

    db.transaction do
      self.title = attrs["title"] if attrs.key?("title")
      self.subtitle = attrs["subtitle"].presence if attrs.key?("subtitle")
      FRAMES.each { |part| choose_frame(part, attrs[part]) if attrs.key?(part) }
      structure = WorkoutStructure.new(self, attrs["blocks"]) if attrs.key?("blocks")
      refuse_while_running if structure || reframed?
      next save_changes unless structure

      # The workout's own problems and its structure's, reported together.
      structure.check!
      save_changes
      structure.write!
      validate!(:publish)
    end
    self
  end

  # Changing what a running session runs would pull its steps from under the
  # player, and the sets it still sends would no longer fit. `later` says
  # what can be done once the session is over.
  def refuse_while_running(later = nil)
    running = running_session
    return unless running

    later ||= "its blocks, steps, warm-up and cool-down can change once that session is finished or skipped, " \
              "or set back to planned while no set is logged in it"
    raise Running, "#{initial_value(:title)} is being trained right now (session #{running.id}); #{later}"
  end

  def reframed?
    FRAMES.any? { column_changed?(:"#{it}_id") || column_changed?(:"no_#{it}") }
  end

  # How long a session under way holds its workouts with nothing happening
  # in it, once its day has gone by.
  RUN_IDLE = 1.day

  # The session under way that runs this workout, as its main part or as the
  # warm-up or cool-down of another; nil when there is none. A run counts on
  # its day and the next (a late run, or a device a time zone ahead), and
  # after that while it was started, picked up again (PATCH in_progress
  # touches it) or had a set logged in the last RUN_IDLE. One left longer is
  # abandoned and no longer holds the workout as it was.
  def running_session
    return if new?

    since = Time.now - RUN_IDLE
    logged = SetLog.where(Sequel[:set_logs][:session_id] => Sequel[:sessions][:id]).where { created_at >= since }
    live = Session.where(status: "in_progress")
      .where(Sequel.|(Sequel[:date] >= Time.zone.yesterday, Sequel[:updated_at] >= since, logged.exists))
    live.eager(workout: { program: :workouts }).order(:id).all
      .find { it.workout.framed_ids(it.part_kinds).include?(id) }
  end

  # Why it can't be changed, or nil when it can.
  def read_only_reason
    "#{title} is archived and can't be changed" if archived?
  end

  # A workout in a list: what it holds, how long it runs with its warm-up
  # and cool-down (`framed_minutes`), and when it was last done.
  def card(up_next: false, last_done: nil)
    steps = blocks.flat_map(&:steps)
    summary.merge(
      exercises: steps.map { it.exercise.name }.uniq,
      exercise_ids: steps.map(&:exercise_id).uniq,
      equipment: steps.flat_map(&:equipment_needed).uniq,
      up_next:,
      framed_minutes: framed.sum(&:estimated_minutes),
      last_done: last_done&.iso8601
    )
  end

  # The whole workout, blocks and steps expanded (load it with `expanded`):
  # each step with its target (the remembered weight winning over the
  # seed's) and the owned weights to step through, plus the parts a session runs and the player's plan.
  def detail
    weights = ExerciseWeight.as_hash(:exercise_id)
    fixed = Equipment.fixed

    expanded_blocks = blocks.map do |block|
      steps = block.steps.map do |step|
        target = step.target(weights[step.exercise_id])
        unit = step.target_unit(target[:weight], weights[step.exercise_id])
        step.as_json.merge(
          target:, weight_unit: unit, allowed_weights: (step.allowed_weights(fixed) if unit)
        )
      end
      block.as_json.merge(steps:)
    end

    as_json.merge(
      blocks: expanded_blocks,
      # The warm-up, workout and cool-down a session of it runs.
      framed: framed.map(&:summary),
      plan: PlayerPlan.new([self], weights:, fixed:),
      weight_steps: Coach.weight_steps,
      # The unit weights are shown in.
      unit: Setting.unit
    )
  end

  def summary
    { id:, example_slug:, kind:, title:, subtitle:, position:, source:, archived: archived?, estimated_minutes: }
  end

  def estimated_minutes
    (blocks.sum(&:estimated_seconds) / 60.0).ceil
  end

  def as_json(*)
    summary.merge(
      program_id:, editable: read_only_reason.nil?,
      warmup: frame_choice("warmup"), cooldown: frame_choice("cooldown"),
      blocks: blocks.map(&:as_json)
    )
  end

  def validate
    super
    validates_presence :title
    MAX_LENGTHS.each { |column, length| validates_max_length length, column, allow_nil: true, message: "is longer than #{length} characters" }
    validates_includes KINDS, :kind
    validates_includes SOURCES, :source
    frames_fit
    # Ready to run: checked once its blocks and steps are written, since they
    # are saved after the workout.
    runnable if validation_context == :publish
  end

  private

  # A warm-up or cool-down picked by a main workout is one of that kind.
  def frames_fit
    FRAMES.each do |part|
      chosen = public_send(part)
      picked = public_send("#{part}_id")
      next unless picked || public_send("no_#{part}")

      name = part == "warmup" ? "warm-up" : "cool-down"
      if kind != "workout" then errors.add(part.to_sym, "can only be picked for a main workout")
      elsif picked && (chosen.nil? || chosen.kind != part) then errors.add(part.to_sym, "must be a #{name}")
      elsif chosen&.archived? && column_changed?(:"#{part}_id") then errors.add(part.to_sym, "is archived")
      end
    end
  end

  def runnable
    errors.add(:base, "needs at least one block") if blocks.empty?
    blocks.reject { it.valid?(validation_context: :publish) }.each do |block|
      block.errors.full_messages.each { errors.add(:base, "block #{block.label}: #{it}") }
    end
  end
end
