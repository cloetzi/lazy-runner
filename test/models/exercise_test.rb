require "test_helper"

describe Exercise do
  it "is either done one side at a time or alternates sides, not both" do
    bug = Exercise.first!(slug: "dead-bug")
    _(bug.alternating).must_equal true
    bug.unilateral = true

    _(bug.valid?).must_equal false
    _(bug.errors.full_messages).must_include "is either done one side at a time or alternates sides, not both"
  end

  describe ".doable_with" do
    it "leaves only bodyweight exercises with no equipment" do
      doable = Exercise.doable_with([])

      _(doable.count).must_be :>, 0
      _(doable.eager(:equipment).all? { it.equipment.empty? }).must_equal true
      _(doable.count).must_equal Exercise.exclude(id: DB[:exercise_equipment].select(:exercise_id)).count
    end

    it "takes exercises that need only what is given" do
      doable = Exercise.doable_with(Equipment.where(slug: "dumbbell"))

      _(doable.where(slug: "plank").empty?).must_equal false
      _(doable.eager(:equipment).flat_map(&:equipment_slugs).uniq).must_equal %w[dumbbell]
      _(doable.where(slug: "rear-foot-elevated-split-squat").empty?).must_equal true
    end
  end
end
