# frozen_string_literal: true

# What a workout edit changed, for the record of plan changes: the
# workout as it was and is (`snapshot`, in the form Workout#revise! takes,
# so undo can write it back), and a short line a person reads ("Block B: 3
# rounds (was 2); Split squat instead of Goblet squat in Main").
module WorkoutChange
  # How many changes the line names before "and N more".
  SHOWN = 4

  # Its fields and whole structure, as Workout#revise! takes them.
  def self.snapshot(workout)
    blocks = workout.blocks_dataset.eager(steps: [:equipment, { exercise: :equipment }]).all
    {
      "title" => workout.title, "subtitle" => workout.subtitle,
      "warmup" => workout.frame_choice("warmup"), "cooldown" => workout.frame_choice("cooldown"),
      "blocks" => blocks.map do |block|
        {
          "id" => block.id, "label" => block.label, "rounds" => block.rounds, "rest_seconds" => block.rest_seconds,
          "steps" => block.steps.map do |step|
            {
              "id" => step.id, "exercise_id" => step.exercise_id, "reps" => step.reps, "duration_seconds" => step.duration_seconds,
              "tempo" => step.tempo, "weight" => step.weight&.transform_keys(&:to_s), "weights_held" => step.weights_held,
              "per_side" => step.per_side, "note" => step.note, "equipment" => step.own_equipment
            }
          end
        }
      end
    }
  end

  # The snapshot `was` as revise! can write it now: blocks and steps since
  # deleted come back as new ones (their logged sets stay unlinked).
  def self.restorable(was, workout)
    blocks = workout.blocks_dataset.select_map(:id).to_set
    steps = Step.where(block_id: blocks.to_a).select_map(:id).to_set
    was.merge("blocks" => was["blocks"].map do |block|
      block = block.except("id") unless blocks.include?(block["id"])
      block.merge("steps" => block["steps"].map { steps.include?(it["id"]) ? it : it.except("id") })
    end)
  end

  # The line saying what changed from `was` to `now`, nil when nothing did.
  def self.summary(was, now)
    ids = [was, now].flat_map { |shot| shot["blocks"].flat_map { |block| block["steps"].map { it["exercise_id"] } } }
    names = Exercise.where(id: ids.uniq).select_hash(:id, :name)
    parts = Differ.new(was, now, names).parts
    return if parts.empty?

    shown = parts.first(SHOWN)
    shown << "and #{parts.size - SHOWN} more #{parts.size - SHOWN == 1 ? "change" : "changes"}" if parts.size > SHOWN
    shown.join("; ")
  end

  class Differ
    STEP_FIELDS = { "reps" => "reps", "duration_seconds" => "s", "tempo" => "tempo", "weights_held" => "held" }.freeze

    def initialize(was, now, names)
      @was = was
      @now = now
      @names = names
    end

    def parts
      [*fields, *frames, *blocks].compact
    end

    private

    def fields
      [
        ("renamed to #{@now["title"]}" if @was["title"] != @now["title"]),
        ("a new subtitle" if @was["subtitle"] != @now["subtitle"])
      ]
    end

    def frames
      { "warmup" => "warm-up", "cooldown" => "cool-down" }.map do |part, name|
        next if @was[part] == @now[part]

        @now[part] == "none" ? "no #{name}" : "another #{name}"
      end
    end

    # Blocks are matched by id, else (one sent again without it) by label.
    def blocks
      pairs, added, removed = match(@was["blocks"], @now["blocks"]) { |was, now| was["label"] == now["label"] }
      order = ("blocks in another order" if pairs.map(&:first) != @was["blocks"].select { |block| pairs.any? { it.first.equal?(block) } })
      changed = pairs.flat_map { |was, now| block(was, now) }
      [*changed, *added.map { "added #{name(it)}" }, *removed.map { "took out #{name(it)}" }, order]
    end

    # The items of `was` and `now` that are the same one, in `now`'s order:
    # by id, else by `same`. Answers the pairs, those only in `now` and
    # those only in `was`.
    def match(was, now, &)
      left = was.dup
      # One whose id is still sent is that one, never another's match.
      sent = now.filter_map { it["id"] }
      pairs = []
      added = []
      now.each do |item|
        found = (left.find { it["id"] && it["id"] == item["id"] } if item["id"])
        found ||= left.find { !sent.include?(it["id"]) && yield(it, item) } unless item["id"] && was.any? { it["id"] == item["id"] }
        found ? (pairs << [left.delete_at(left.index { it.equal?(found) }), item]) : added << item
      end
      [pairs, added, left]
    end

    def block(was, now)
      where = name(now)
      parts = []
      parts << "#{rounds(now["rounds"])} in #{where} (was #{was["rounds"]})" if was["rounds"] != now["rounds"]
      parts << "#{now["rest_seconds"]} s rest in #{where} (was #{was["rest_seconds"]} s)" if was["rest_seconds"] != now["rest_seconds"]
      parts << "#{where} renamed from #{name(was)}" if was["label"] != now["label"]
      parts + steps(was["steps"], now["steps"], where)
    end

    # Steps are matched by id, else (one sent again without it) by exercise.
    def steps(was, now, where)
      pairs, added, removed = match(was, now) { |old, new| old["exercise_id"] == new["exercise_id"] }
      parts = pairs.flat_map { |old, new| step(old, new) }
      # A step whose exercise changed is a new step in the same place.
      swaps = added.filter_map do |step|
        gone = removed.find { was.index(it) == now.index(step) }
        [step, gone] if gone
      end
      swapped = swaps.map do |step, gone|
        added.delete(step)
        removed.delete(gone)
        "#{exercise(step)} instead of #{exercise(gone)} in #{where}"
      end
      kept = pairs.map(&:first)
      order = ("steps in another order in #{where}" if kept != was.select { |step| kept.any? { it.equal?(step) } })
      [*parts, *swapped, *added.map { "added #{exercise(it)} to #{where}" }, *removed.map { "took #{exercise(it)} out of #{where}" }, order]
    end

    def step(was, now)
      changes = STEP_FIELDS.filter_map do |field, unit|
        next if was[field] == now[field]

        if now[field].nil?
          "no #{unit == "s" ? "time" : unit}"
        else
          amount(field, now[field], unit, was[field])
        end
      end
      changes << "weight #{weight(now["weight"])} (was #{weight(was["weight"])})" if was["weight"] != now["weight"]
      changes << "another note" if was["note"] != now["note"]
      changes << "other gear" if was["equipment"] != now["equipment"]
      changes << (now["per_side"] ? "each side" : "both sides together") if was["per_side"] != now["per_side"]
      changes.empty? ? [] : ["#{exercise(now)}: #{changes.join(", ")}"]
    end

    def amount(field, value, unit, was)
      shown = if field == "tempo"
                "tempo #{value}"
              else
                field == "duration_seconds" ? "#{value} s" : "#{value} #{unit}"
              end
      if was.nil?
        shown
      else
        "#{shown} (was #{field == "duration_seconds" ? "#{was} s" : was})"
      end
    end

    def weight(weight)
      return "none" unless weight

      value = weight["value"].to_f
      "#{(value % 1).zero? ? value.to_i : value} #{weight["unit"]}"
    end

    def rounds(count) = count == 1 ? "1 round" : "#{count} rounds"
    def exercise(step) = @names[step["exercise_id"]] || "an exercise"
    # "block B" for a lettered block, as the workout view names it.
    def name(block) = block["label"].to_s.match?(/\A[A-Z]\z/) ? "block #{block["label"]}" : block["label"].to_s
  end
end
