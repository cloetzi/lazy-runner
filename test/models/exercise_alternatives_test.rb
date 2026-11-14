require "test_helper"

describe "Exercise#alternatives" do
  it "offers squat or lunge patterns first for a goblet squat" do
    _(exercise("goblet-squat").alternatives.first(2).map(&:pattern)).must_equal %w[squat lunge]
  end

  it "rates how closely another exercise trains the same movement" do
    squat = exercise("goblet-squat")

    _(squat.match(exercise("rear-foot-elevated-split-squat"))).must_equal "similar"
    _(exercise("single-leg-deadlift").match(exercise("straight-leg-deadlift"))).must_equal "same"
    _(squat.match(exercise("push-up"))).must_equal "other"
    _(squat.match(Exercise.new(pattern: nil))).must_equal "other"
  end
end
