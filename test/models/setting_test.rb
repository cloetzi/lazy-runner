require "test_helper"

describe Setting do
  it "is one row, made on first use" do
    _(Setting.current).must_equal Setting.current
    _(Setting.count).must_equal 1
  end

  it "is the unit for an exercise whose equipment has none" do
    plank = exercise("plank")
    _(plank.weight_unit).must_equal "lb"

    Setting.current.update(unit: "kg")

    _(plank.weight_unit).must_equal "kg"
    _(exercise("goblet-squat").weight_unit).must_equal equipment("kettlebell").unit
  end
end
