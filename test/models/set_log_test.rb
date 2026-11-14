require "test_helper"

describe SetLog do
  let(:session) { session_on(Date.today, "in_progress") }
  let(:squat) { step_for("cycle-1-workout-1", "goblet-squat") }
  let(:deadlift) { step_for("cycle-1-workout-1", "single-leg-deadlift") }

  it "refuses a second log of the same set without a side" do
    SetLog.create(session:, step: squat, set_number: 1, reps: 6)

    _ { SetLog.create(session:, step: squat, set_number: 1, reps: 7) }.must_raise Sequel::UniqueConstraintViolation
  end

  it "refuses a second log of the same side" do
    SetLog.create(session:, step: deadlift, set_number: 1, side: "left", reps: 8)

    _ { SetLog.create(session:, step: deadlift, set_number: 1, side: "left", reps: 9) }.must_raise Sequel::UniqueConstraintViolation
  end

  it "names a set by its step's id after the step has gone" do
    log = SetLog.create(session:, step: squat, set_number: 1, reps: 6)
    log.update_columns(step_id: nil)

    _(log.refresh.step_ref).must_equal squat.id
    _ { SetLog.create(session:, step: squat, set_number: 1, reps: 7) }.must_raise Sequel::UniqueConstraintViolation
  end

  it "keeps history logged before sets named their step" do
    2.times { SetLog.create(session:, step: squat, set_number: 1, reps: 6).update_columns(step_id: nil, step_ref: nil) }

    _(SetLog.where(session:, step_id: nil).count).must_equal 2
  end

end
