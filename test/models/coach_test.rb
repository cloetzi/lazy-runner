require "test_helper"

describe Coach do
  describe ".step_weight" do
    it "steps 5 lb or 2.5 kg by default" do
      _(Coach.step_weight(40, "lb", ["band"], "up")).must_equal 45
      _(Coach.step_weight(20, "kg", ["band"], "down")).must_equal 17.5
    end

    it "steps light dumbbells in smaller increments" do
      _(Coach.step_weight(10, "lb", ["dumbbell"], "up")).must_equal 12.5
      _(Coach.step_weight(12.5, "lb", ["dumbbell"], "up")).must_equal 15
      _(Coach.step_weight(15, "lb", ["dumbbell"], "up")).must_equal 20
      _(Coach.step_weight(20, "lb", ["dumbbell"], "down")).must_equal 15
      _(Coach.step_weight(15, "lb", ["dumbbell"], "down")).must_equal 12.5
      _(Coach.step_weight(5, "kg", ["dumbbell"], "up")).must_equal 6
    end

    it "never goes below zero" do
      _(Coach.step_weight(2.5, "lb", ["dumbbell"], "down")).must_equal 0
      _(Coach.step_weight(1, "lb", ["band"], "down")).must_equal 0
    end

    describe "with owned weights" do
      it "moves to the next weight owned" do
        _(Coach.step_weight(10, "lb", ["dumbbell"], "up", allowed: [10, 20])).must_equal 20
        _(Coach.step_weight(20, "lb", ["dumbbell"], "down", allowed: [10, 20])).must_equal 10
      end

      it "stays put with nothing further owned" do
        _(Coach.step_weight(10, "lb", ["dumbbell"], "down", allowed: [10, 20])).must_equal 10
        _(Coach.step_weight(20, "lb", ["dumbbell"], "up", allowed: [10, 20])).must_equal 20
        _(Coach.step_weight(40, "lb", ["kettlebell"], "up", allowed: [40])).must_equal 40
      end

      it "goes from a weight not owned to the nearest owned one that way" do
        _(Coach.step_weight(15, "lb", ["dumbbell"], "up", allowed: [10, 20])).must_equal 20
        _(Coach.step_weight(15, "lb", ["dumbbell"], "down", allowed: [10, 20])).must_equal 10
      end

      it "steps by band when nothing is owned" do
        _(Coach.step_weight(10, "lb", ["dumbbell"], "up", allowed: [])).must_equal 12.5
      end
    end

    it "rejects an unknown direction" do
      _ { Coach.step_weight(10, "lb", [], "sideways") }.must_raise ArgumentError
    end
  end
end
