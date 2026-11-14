require "test_helper"

describe WeightSuggestion do
  let(:session) { session_on(Date.today, "in_progress") }

  # Goblet squats start at 40 lb on the kettlebell; give it a lighter and a
  # heavier one to step to.
  before { inventory("kettlebell").update(weights: [30, 40, 50]) }

  def suggestion_for(slug, suggestions)
    suggestions.find { it.exercise.slug == slug }
  end

  it "suggests one step up when every set was made and it felt too easy" do
    log_all(session, "goblet-squat")

    suggestion = suggestion_for("goblet-squat", finish(session, "too_easy"))

    _(suggestion.direction).must_equal "up"
    _(suggestion.weight).must_equal({ value: 50.0, unit: "lb" })
  end

  it "suggests nothing for an exercise remembered as done without a weight" do
    log_all(session, "goblet-squat")
    ExerciseWeight.remember!(exercise("goblet-squat"), nil)

    _(suggestion_for("goblet-squat", finish(session, "too_easy"))).must_be_nil
  end

  it "counts no weight as taking a suggestion down to 0" do
    suggestion = WeightSuggestion.create(exercise: exercise("goblet-squat"), session:, direction: "down", value: 0, unit: "lb", reason: "Felt too hard")

    ExerciseWeight.remember!(exercise("goblet-squat"), 0)

    _(suggestion.refresh.status).must_equal "accepted"
  end

  it "does not step up when a set was skipped" do
    log_all(session, "goblet-squat")
    SetLog.where(session:).first.update(status: "skipped")

    _(suggestion_for("goblet-squat", finish(session, "too_easy"))).must_be_nil
  end

  it "does not step down for a skipped round when every set done was made" do
    log_all(session, "goblet-squat")
    SetLog.where(session:, set_number: 3).update(status: "skipped")

    _(finish(session, "right")).must_be_empty
  end

  it "still steps down for a skipped round that felt too hard" do
    log_all(session, "goblet-squat")
    SetLog.where(session:, set_number: 3).update(status: "skipped")

    _(suggestion_for("goblet-squat", finish(session, "too_hard")).reason).must_equal "Felt too hard at 40 lb"
  end

  it "does not step up when a round was never logged" do
    log_all(session, "goblet-squat")
    SetLog.where(session:, set_number: 3).delete

    _(suggestion_for("goblet-squat", finish(session, "too_easy"))).must_be_nil
  end

  it "suggests one step down when it felt too hard" do
    log_all(session, "goblet-squat")

    _(suggestion_for("goblet-squat", finish(session, "too_hard")).weight).must_equal({ value: 30.0, unit: "lb" })
  end

  it "suggests one step down when reps were missed, whatever the feedback" do
    log_all(session, "goblet-squat")
    SetLog.where(session:).last.update(reps: 6)

    suggestion = suggestion_for("goblet-squat", finish(session, "right"))

    _(suggestion.direction).must_equal "down"
    _(suggestion.reason).must_equal "Missed reps at 40 lb"
  end

  it "judges missed reps against the target the set was logged with" do
    log_all(session, "goblet-squat")
    target = SetLog.where(session:).first.target_reps
    SetLog.where(session:).update(reps: target)
    step_for("cycle-1-workout-1", "goblet-squat").update(reps: target + 4)

    _(finish(session, "right")).must_be_empty
  end

  it "suggests nothing when it felt right" do
    log_all(session, "goblet-squat")

    _(finish(session, "right")).must_be_empty
  end

  it "steps from the weight actually used" do
    log_all(session, "goblet-squat", weight_value: 30)

    _(suggestion_for("goblet-squat", finish(session, "too_easy")).value).must_equal 40
  end

  it "steps to the next dumbbell owned" do
    log_all(session, "reverse-fly")

    _(suggestion_for("reverse-fly", finish(session, "too_easy")).weight).must_equal({ value: 20.0, unit: "lb" })
  end

  it "suggests nothing when nothing lighter is owned" do
    log_all(session, "reverse-fly")

    _(suggestion_for("reverse-fly", finish(session, "too_hard"))).must_be_nil
  end

  it "steps by band for equipment without a list of weights" do
    inventory("kettlebell").update(weights: [])
    inventory("dumbbell").update(weights: [])
    log_all(session, "goblet-squat")

    _(suggestion_for("goblet-squat", finish(session, "too_easy")).weight).must_equal({ value: 45.0, unit: "lb" })
  end

  it "steps from a weight logged in the other unit, in the exercise's unit" do
    log_all(session, "goblet-squat", weight_value: 18, weight_unit: "kg")

    _(suggestion_for("goblet-squat", finish(session, "too_easy")).weight).must_equal({ value: 50.0, unit: "lb" })
  end

  it "skips exercises without a weight" do
    log_all(session, "dead-bug")

    _(suggestion_for("dead-bug", finish(session, "too_easy"))).must_be_nil
  end

  it "replaces an older pending suggestion for the same exercise" do
    log_all(session, "goblet-squat")
    old = suggestion_for("goblet-squat", finish(session, "too_easy"))
    later = session_on(Date.today, "in_progress")
    log_all(later, "goblet-squat")
    finish(later, "right")

    _(old.refresh.status).must_equal "superseded"
    _(WeightSuggestion.pending.where(exercise: exercise("goblet-squat"))).must_be_empty
  end

  it "keeps a newer session's suggestion when an older one completes late" do
    newer = session_on(Date.today, "in_progress")
    older = session_on(Date.today - 1, "in_progress")
    log_all(newer, "goblet-squat")
    log_all(older, "goblet-squat")
    kept = suggestion_for("goblet-squat", finish(newer, "too_easy"))

    _(suggestion_for("goblet-squat", finish(older, "too_hard"))).must_be_nil
    _(kept.refresh.status).must_equal "pending"
    _(WeightSuggestion.first!(session: older).status).must_equal "superseded"
  end

  it "takes the session finished last on a day as the newer one, wherever it was planned" do
    first = session
    log_all(first, "goblet-squat")
    stale = suggestion_for("goblet-squat", finish(first, "too_easy"))
    # Planned at the top of the day once the first was done, which moves the
    # first down to second place.
    second = Session.add!(workout: workout("cycle-1-workout-1"), date: Date.today, position: 1, status: "in_progress", started_at: Time.now)
    _(first.refresh.position).must_equal 2
    log_all(second, "goblet-squat")
    travel 1.minute

    fresh = suggestion_for("goblet-squat", finish(second.refresh, "too_hard"))

    _(fresh.status).must_equal "pending"
    _(stale.refresh.status).must_equal "superseded"
  end

  it "stores a late sync's suggestion as superseded when a newer session did the exercise without one" do
    newer = session_on(Date.today, "in_progress")
    older = session_on(Date.today - 1, "in_progress")
    log_all(newer, "goblet-squat")
    log_all(older, "goblet-squat")
    _(finish(newer, "right")).must_be_empty

    _(suggestion_for("goblet-squat", finish(older, "too_easy"))).must_be_nil
    _(WeightSuggestion.first!(session_id: older.id).superseded_by_id).must_equal newer.id
  end

  it "gives back a late sync's suggestion when the session that outdated it goes" do
    oldest = session_on(Date.today - 2, "in_progress")
    log_all(oldest, "goblet-squat")
    first = suggestion_for("goblet-squat", finish(oldest, "too_easy"))
    newest = session_on(Date.today, "in_progress")
    log_all(newest, "goblet-squat")
    finish(newest, "right")
    middle = session_on(Date.today - 1, "in_progress")
    log_all(middle, "goblet-squat")
    finish(middle, "too_hard")
    late = WeightSuggestion.first!(session_id: middle.id)

    newest.erase!

    _(late.refresh.status).must_equal "pending"
    _(first.refresh.status).must_equal "superseded"
  end

  describe "a finish taken back" do
    let(:later) { session_on(Date.today, "in_progress") }

    def supersede
      log_all(session, "goblet-squat")
      old = suggestion_for("goblet-squat", finish(session, "too_easy"))
      log_all(later, "goblet-squat")
      travel 1.minute
      finish(later, "right")
      _(old.refresh.status).must_equal "superseded"
      old
    end

    it "gives back what the session superseded when it is picked up again" do
      old = supersede
      later.completion.update(ended_early: true)

      later.update(status: "in_progress")

      _(old.refresh.status).must_equal "pending"
      _(old.superseded_by_id).must_be_nil
    end

    it "gives back what the session superseded when it is deleted" do
      old = supersede

      later.erase!

      _(old.refresh.status).must_equal "pending"
    end

    it "leaves it superseded once the exercise's weight has been set since" do
      old = supersede
      travel 1.minute
      ExerciseWeight.remember!(exercise("goblet-squat"), 45, "lb")

      later.erase!

      _(old.refresh.status).must_equal "superseded"
    end

    it "leaves it superseded when a newer session has a suggestion pending" do
      old = supersede
      newest = session_on(Date.today, "in_progress")
      log_all(newest, "goblet-squat")
      travel 1.minute
      kept = suggestion_for("goblet-squat", finish(newest, "too_hard"))

      later.erase!

      _(old.refresh.status).must_equal "superseded"
      _(kept.refresh.status).must_equal "pending"
    end
  end

  it "gives a swapped-in exercise a suggestion of its own" do
    log_all(session, "goblet-squat", exercise: exercise("straight-leg-deadlift"), weight_value: 10)

    suggestions = finish(session, "too_easy")

    _(suggestion_for("goblet-squat", suggestions)).must_be_nil
    _(suggestion_for("straight-leg-deadlift", suggestions).weight).must_equal({ value: 20.0, unit: "lb" })
  end
end
