require "test_helper"

describe Weights do
  def lb(value) = { value:, unit: "lb" }
  def kg(value) = { value:, unit: "kg" }

  describe ".convert" do
    it "converts to two decimals" do
      _(Weights.convert(kg(20), "lb")).must_equal lb(44.09)
      _(Weights.convert(lb(40), "kg")).must_equal kg(18.14)
    end

    it "leaves a weight already in the unit, or none, alone" do
      _(Weights.convert(lb(12.5), "lb")).must_equal lb(12.5)
      _(Weights.convert(nil, "lb")).must_be_nil
    end
  end

  describe ".normalize" do
    it "snaps to an owned weight the converted value rounds from" do
      _(Weights.normalize(kg(9), "lb", [10.0, 20.0])).must_equal lb(20.0)
      _(Weights.normalize(kg(4.5), "lb", [10.0, 20.0])).must_equal lb(10.0)
    end

    it "keeps the converted value when no owned weight is that close" do
      _(Weights.normalize(kg(25), "lb", [10.0, 20.0])).must_equal lb(55.12)
    end
  end

  describe ".same?" do
    it "matches a weight shown rounded in the other unit" do
      _(Weights.same?(lb(45), kg(20.5))).must_equal true
      _(Weights.same?(lb(40), kg(18))).must_equal true
      _(Weights.same?(lb(45), lb(45.0))).must_equal true
    end

    it "tells weights apart by more than the rounding" do
      _(Weights.same?(lb(45), kg(21))).must_equal false
      _(Weights.same?(lb(45), lb(50))).must_equal false
      _(Weights.same?(lb(45), nil)).must_equal false
    end
  end
end
