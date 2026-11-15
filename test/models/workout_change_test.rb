require "test_helper"

# Workout edits and remembered weights in the record of plan changes (#290).
describe WorkoutChange do
  let(:today) { Date.new(2026, 11, 11) }
  let(:strength) { workout("cycle-1-workout-1") }
  let(:squat) { exercise("goblet-squat") }

  before { travel_to Time.utc(2026, 11, 11, 12) }
  after { travel_back }

  def as_agent(name = "Coach agent", &) = Current.set(agent_name: name, &)

  def latest = PlanChange.order(:id).last

  def blocks = WorkoutChange.snapshot(strength.refresh)["blocks"]

  # The workout's structure with `change` made to a copy of it.
  def edited(&change) = blocks.tap(&change)

  def revise(&) = strength.revise!("blocks" => edited(&))

  def exercise_name(step) = Exercise.with_pk!(step["exercise_id"]).name

  describe "what a workout edit records" do
    it "records an edit with the workout as it was and is, a line saying what changed, and the agent's reason" do
      before = WorkoutChange.snapshot(strength)
      as_agent { PlanChange.because("The last two weeks felt easy") { revise { it[0]["rounds"] += 1 } } }

      change = latest
      label = before["blocks"][0]["label"]
      _([change.item_kind, change.action, change.workout_id, change.title, change.changed_by, change.agent_name, change.reason])
        .must_equal ["workout", "changed", strength.id, strength.title, "llm", "Coach agent", "The last two weeks felt easy"]
      _(change.was).must_equal before
      _(change.now["blocks"][0]["rounds"]).must_equal before["blocks"][0]["rounds"] + 1
      _(change.summary).must_equal "#{before["blocks"][0]["rounds"] + 1} rounds in block #{label} (was #{before["blocks"][0]["rounds"]})"
    end

    it "says what changed in each step: an exercise swapped, reps, a weight, a step added or taken out" do
      original = blocks
      first, second = original[0]["steps"]
      lunge = exercise("curtsy-lunge")
      revise do |shot|
        shot[0]["steps"][0] = first.except("id", "per_side").merge("exercise_id" => lunge.id)
        shot[0]["steps"][1]["reps"] = 15
        shot[0]["steps"][1]["weight"] = { "value" => 20.0, "unit" => "lb" }
        shot[1]["steps"].pop
      end

      block_a = "block #{original[0]["label"]}"
      gone = original[1]["steps"].last
      _(latest.summary).must_equal [
        "#{exercise_name(second)}: 15 reps (was #{second["reps"]}), weight 20 lb (was #{second["weight"] ? "#{second["weight"]["value"].to_i} lb" : "none"})",
        "#{lunge.name} instead of #{exercise_name(first)} in #{block_a}",
        "took #{exercise_name(gone)} out of block #{original[1]["label"]}"
      ].join("; ")
    end

    it "reports two neighbouring swaps, and a step sent again without its id by what changed in it" do
      original = blocks
      first, second = original[0]["steps"]
      lunge = exercise("curtsy-lunge")
      push = exercise("push-up")
      shot = ->(list) { WorkoutChange.snapshot(strength).merge("blocks" => list) }
      summary = WorkoutChange.summary(shot.(original), shot.(edited do |list|
        list[0]["steps"][0] = first.except("id", "per_side").merge("exercise_id" => lunge.id)
        list[0]["steps"][1] = second.except("id", "per_side").merge("exercise_id" => push.id)
      end))
      _(summary).must_equal "#{lunge.name} instead of #{exercise_name(first)} in block #{original[0]["label"]}; " \
                            "#{push.name} instead of #{exercise_name(second)} in block #{original[0]["label"]}"

      resent = edited { |list| list.each { |block| block.delete("id"); block["steps"].each { it.delete("id") } } }
      resent[0]["steps"][0]["reps"] = 15
      _(WorkoutChange.summary(shot.(original), shot.(resent))).must_equal "#{exercise_name(first)}: 15 reps (was #{first["reps"]})"
    end

    it "keeps a kind of item to its own link, as the table's checks do" do
      row = { user_id: user.id, changed_by: "manual", action: "changed", batch: "b", created_at: Time.now, updated_at: Time.now }
      _ { DB[:plan_changes].insert(row.merge(item_kind: "workout", exercise_id: exercise("goblet-squat").id)) }.must_raise Sequel::CheckConstraintViolation
      _ { DB[:plan_changes].insert(row.merge(item_kind: "habit")) }.must_raise Sequel::CheckConstraintViolation
    end

    it "names the first few changes and counts the rest" do
      revise { |shot| shot.each { |block| block["rounds"] += 1; block["rest_seconds"] += 15 } }

      shown = latest.summary.split("; ")
      _(shown.size).must_equal WorkoutChange::SHOWN + 1
      _(shown.last).must_match(/\Aand \d+ more changes?\z/)
    end

    it "records the user's edits too, and nothing for a save that changes nothing or a new workout" do
      revise { it[0]["rest_seconds"] = 75 }
      _([latest.changed_by, latest.agent_name]).must_equal ["manual", nil]

      count = PlanChange.count
      strength.revise!("blocks" => blocks, "title" => strength.title)
      Workout.create_with!({ kind: "workout", title: "New", blocks: [{ label: "A", steps: [{ exercise: "goblet-squat", reps: 8 }] }] })
      _(PlanChange.count).must_equal count
    end

    it "records an archive with the reason given, and its sessions with their own" do
      Session.plan!(workout: strength, date: today + 1)
      as_agent { PlanChange.because("Replaced by Strength B") { strength.archive! } }

      archive, removal = PlanChange.where(action: %w[archived removed]).order(:id).all
      _([archive.item_kind, archive.workout_id, archive.reason]).must_equal ["workout", strength.id, "Replaced by Strength B"]
      _([removal.item_kind, removal.reason]).must_equal ["session", "its workout was archived"]
      _(archive.undo_problem(PlanChange::Lookup.new([archive], today:))).must_match(/stays archived/)
    end
  end

  describe "taking a workout edit back" do
    it "puts the workout back as it was, steps taken out coming back as new ones, recorded as the user's undo" do
      before = WorkoutChange.snapshot(strength)
      as_agent { revise { it[1]["steps"].pop } }
      change = latest

      undo = change.refresh.undo!(today:)

      after = WorkoutChange.snapshot(strength.refresh)
      _(after["blocks"].map { |block| block["steps"].map { it["exercise_id"] } }).must_equal(before["blocks"].map { |block| block["steps"].map { it["exercise_id"] } })
      _(after["blocks"][0]).must_equal before["blocks"][0]
      _([undo.item_kind, undo.changed_by, undo.undoes_id]).must_equal ["workout", "manual", change.id]
      _(change.refresh.undone?).must_equal true
    end

    it "takes back only the latest edit, and not while the workout is archived" do
      as_agent { revise { it[0]["rounds"] += 1 } }
      older = latest
      revise { it[0]["rest_seconds"] = 90 }
      newer = latest

      _(_ { older.refresh.undo!(today:) }.must_raise(PlanChange::NotUndoable).message).must_match(/changed again/)
      Session.plan!(workout: strength, date: today).update(status: "in_progress")
      _(newer.refresh.undo_problem(PlanChange::Lookup.new([newer], today:))).must_match(/being trained right now/)
      Session.where(workout_id: strength.id).delete
      strength.archive!
      _(_ { newer.refresh.undo!(today:) }.must_raise(PlanChange::NotUndoable).message).must_match(/archived/)
    end
  end

  describe "what a remembered weight records" do
    it "records a weight set, from what was remembered (nothing at first) to what is, and nothing when it stays" do
      as_agent { PlanChange.because("RPE 6 on every set") { ExerciseWeight.remember!(squat, 25, "lb") } }

      change = latest
      _([change.item_kind, change.exercise_id, change.title, change.changed_by, change.reason]).must_equal ["weight", squat.id, squat.name, "llm", "RPE 6 on every set"]
      _(change.was).must_equal({ "value" => nil, "unit" => nil })
      _(change.now).must_equal({ "value" => 25.0, "unit" => "lb" })

      ExerciseWeight.remember!(squat, 30, "lb")
      _([latest.changed_by, latest.was, latest.now]).must_equal ["manual", { "value" => 25.0, "unit" => "lb" }, { "value" => 30.0, "unit" => "lb" }]

      count = PlanChange.count
      ExerciseWeight.remember!(squat, 30, "lb")
      _(PlanChange.count).must_equal count
    end

    it "takes a weight back to what was remembered, or to nothing remembered" do
      ExerciseWeight.remember!(squat, 20, "lb")
      as_agent { ExerciseWeight.remember!(squat, 30, "lb") }
      latest.undo!(today:)
      _(ExerciseWeight.first(exercise_id: squat.id).weight).must_equal({ value: 20.0, unit: "lb" })

      as_agent { ExerciseWeight.remember!(squat, 30, "lb") }
      changed = latest
      ExerciseWeight.where(exercise_id: squat.id).update(value: 25)
      _(changed.undo_problem(PlanChange::Lookup.new([changed], today:))).must_match(/changed since/)
      _(PlanChange.standing(exercise_ids: [squat.id], today:)).must_equal []

      ExerciseWeight.where(exercise_id: squat.id).delete
      as_agent { ExerciseWeight.remember!(squat, 0) }
      latest.undo!(today:)
      _(ExerciseWeight.first(exercise_id: squat.id)).must_be_nil
      _(latest.now).must_equal({ "value" => nil, "unit" => nil })
    end
  end

  describe "what still stands" do
    it "gives an item's latest change while it is an agent's, not taken back, and on Get ready until it is trained" do
      as_agent { revise { it[0]["rounds"] += 1 } }
      as_agent { ExerciseWeight.remember!(squat, 25, "lb") }
      standing = ->(**options) { PlanChange.standing(workout_ids: [strength.id], exercise_ids: [squat.id], today:, **options).map { it[:item_kind] } }

      _(standing.(untrained: true)).must_equal %w[workout weight]

      session = Session.plan!(workout: strength, date: today)
      step = strength.refresh.blocks.first.steps.first
      SetLog.create(session_id: session.id, step_id: step.id, step_ref: step.id, exercise_id: squat.id, planned_exercise_id: squat.id,
                    block_label: "A", set_number: 1, status: "done", created_at: Time.now + 60)
      _(standing.(untrained: true)).must_equal []
      _(standing.()).must_equal %w[workout weight]

      ExerciseWeight.remember!(squat, 30, "lb")
      _(standing.()).must_equal %w[workout]
    end

    it "counts a warm-up as trained when its main workout's session logs a set of it" do
      warmup = Workout.with_pk!(strength.frame_id("warmup"))
      as_agent { warmup.revise!("blocks" => WorkoutChange.snapshot(warmup)["blocks"].tap { it[0]["rounds"] += 1 }) }
      _(PlanChange.standing(workout_ids: [warmup.id], today:, untrained: true).size).must_equal 1

      session = Session.plan!(workout: strength, date: today)
      step = warmup.refresh.blocks.first.steps.first
      SetLog.create(session_id: session.id, step_id: step.id, step_ref: step.id, exercise_id: step.exercise_id, planned_exercise_id: step.exercise_id,
                    block_label: "A", set_number: 1, status: "done", created_at: Time.now + 60)
      _(PlanChange.standing(workout_ids: [warmup.id], today:, untrained: true)).must_equal []
    end
  end
end
