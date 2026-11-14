# A next-time weight change worked out from a finished session. It is only a
# suggestion: it shows until the user sets that exercise's weight, either
# accepting it or keeping what they had.
class WeightSuggestion < Record
  DIRECTIONS = %w[up down].freeze
  STATUSES = %w[pending accepted dismissed superseded].freeze

  per_user
  many_to_one :exercise
  many_to_one :session, key: %i[user_id session_id], primary_key: %i[user_id id]
  # The session whose finish superseded this one.
  many_to_one :superseded_by, class: :Session, key: %i[user_id superseded_by_id], primary_key: %i[user_id id]

  dataset_module do
    where :pending, status: "pending"
  end

  # Works out one suggestion per weighted exercise done in a finished session:
  # one step up when every set was done at target reps and it felt too easy,
  # one step down when it felt too hard or reps were missed. A skipped or
  # unlogged set only rules out a step up. A step is to the next weight owned
  # for fixed-weight equipment, so with nothing heavier (or lighter) owned there
  # is no suggestion. Sets are judged by the exercise actually done, so a swap
  # says nothing about the planned exercise and gets a suggestion of its own,
  # and against the target each set was logged with.
  #
  # A newer session wins: a suggestion from a session older (a late sync)
  # than the last one to do the exercise is stored as superseded by it
  # straight away.
  def self.generate_for(session)
    rules = Coach.suggestions
    feedback = session.completion&.feedback
    weights = ExerciseWeight.as_hash(:exercise_id)
    fixed = Equipment.fixed
    planned = session.parts.flat_map(&:blocks).flat_map { |block| block.steps.map { [it.id, [block, it]] } }.to_h
    logs = session.set_logs_dataset.eager(exercise: :equipment).all.select { planned.key?(it.step_id) }

    where(session_id: session.id).delete
    logs.group_by(&:exercise).filter_map do |exercise, sets|
      done = sets.select { it.status == "done" }
      # Done without a weight from now on: nothing to step up or down.
      next if done.empty? || weights[exercise.id]&.none?

      # Done again since: the older suggestion is stale, unless this session
      # is the older one.
      newer = done_since(session, exercise.id)
      pending.where(exercise_id: exercise.id).update(status: "superseded", superseded_by_id: session.id, updated_at: Time.now) unless newer

      swap = sets.all?(&:swapped?)
      pairs = planned.values_at(*sets.map(&:step_id).uniq)
      equipment = swap ? exercise.equipment_slugs : pairs.flat_map { |_, step| step.equipment_needed }
      unit = swap ? exercise.weight_unit : pairs.first.last.gear_unit
      allowed = swap ? Equipment.allowed_for(equipment, unit, fixed) : pairs.first.last.allowed_weights(fixed)
      last = done.select(&:weight_value).max_by(&:id)
      start = swap ? weights[exercise.id]&.weight : pairs.first.last.target(weights[exercise.id])[:weight]
      base = Weights.normalize(last&.weight || start, unit, allowed)
      next unless base

      missed = done.any? do |set|
        target = set.target_reps || planned[set.step_id].last.reps
        target && set.reps && set.reps < target - rules.fetch("missed_reps_tolerance")
      end
      skipped = rules.fetch("skip_blocks_up") && sets.any? { it.status == "skipped" }
      expected = pairs.sum { |block, step| block.rounds * step.sides }

      direction, reason =
        if missed then ["down", "Missed reps at #{format_weight(base)}"]
        elsif rules.fetch("down_feedback").include?(feedback) then ["down", "Felt too hard at #{format_weight(base)}"]
        elsif rules.fetch("up_feedback").include?(feedback) && !skipped && done.size >= expected then ["up", "Felt too easy at #{format_weight(base)}"]
        end
      next unless direction

      value = Coach.step_weight(base[:value], base[:unit], equipment, direction, allowed:)
      next if value == base[:value]

      create(exercise_id: exercise.id, session_id: session.id, direction:, value:, unit: base[:unit], reason:, status: newer ? "superseded" : "pending", superseded_by_id: newer&.id)
    end.select(&:pending?)
  end

  # Undoes what a session's finish superseded, when the session is reopened
  # or deleted: per exercise, the newest suggestion it superseded is pending
  # again, unless another session's suggestion is pending for it by now, the
  # exercise's weight has been set since, or another session did it since.
  def self.give_back(session)
    table = Sequel[:weight_suggestions]
    superseded = where(table[:status] => "superseded", table[:superseded_by_id] => session.id)
    superseded.distinct.select_map(:exercise_id).each do |exercise_id|
      latest = superseded.where(table[:exercise_id] => exercise_id).join(:sessions, id: :session_id).select_all(:weight_suggestions).order(*Session::LATEST_FIRST).first
      next unless pending.where(exercise_id:).exclude(session_id: session.id).empty?
      next if answered_since?(exercise_id, latest.updated_at) || done_since(latest.session, exercise_id, except: session)

      latest.update(status: "pending")
    end
    where(superseded_by_id: session.id).update(superseded_by_id: nil)
  end

  # The newest session of its user's after `session` (but `except`) with a
  # set of the exercise done, or nil.
  def self.done_since(session, exercise_id, except: nil)
    later = Session.after(session).where(id: SetLog.done.where(exercise_id:).select(:session_id))
    later = later.exclude(id: except.id) if except
    later.latest_first.first
  end

  # Whether the user set the exercise's weight, or answered a suggestion for
  # it, after `time`.
  def self.answered_since?(exercise_id, time)
    !ExerciseWeight.where(exercise_id:).where { updated_at > time }.empty? ||
      !where(exercise_id:, status: %w[accepted dismissed]).where { updated_at > time }.empty?
  end

  def pending? = status == "pending"

  def self.format_weight(weight)
    value = weight[:value]
    "#{value == value.to_i ? value.to_i : value} #{weight[:unit]}"
  end

  def weight
    { value: value.to_f, unit: }
  end

  def as_json(*)
    { id:, exercise_id:, direction:, value: value.to_f, unit:, reason: }
  end

  def validate
    super
    validates_includes DIRECTIONS, :direction
    validates_includes STATUSES, :status
    validates_includes ExerciseWeight::UNITS, :unit
  end
end
