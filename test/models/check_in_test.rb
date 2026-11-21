# frozen_string_literal: true

require "test_helper"

describe CheckIn do
  # A Saturday.
  before { travel_to Time.utc(2026, 11, 21, 18) }
  after { travel_back }

  let(:today) { Date.new(2026, 11, 21) }

  describe ".write!" do
    it "writes a group whole, signed by the user, and leaves the other empty" do
      check_in = CheckIn.write!("2026-11-21", "night", { sleep: "poor", drinks: "3+", tags: ["late_to_bed"], note: " Birthday " })

      _(check_in.group_json("night"))
        .must_equal({ sleep: "poor", drinks: "3+", tags: ["late_to_bed"], note: "Birthday", logged_by: "manual" })
      _(check_in.group_json("day")).must_be_nil
    end

    it "clears the fields a write leaves out" do
      CheckIn.write!(today, "day", { feeling: "rough", sore: "a_bit", sore_areas: %w[knees knees], ill: true })
      check_in = CheckIn.write!(today, "day", { feeling: "ok" })

      _(check_in.group_json("day"))
        .must_equal({ feeling: "ok", stress: nil, sore: nil, sore_areas: [], ill: false, note: nil, logged_by: "manual" })
    end

    it "deletes the day once both groups are empty" do
      CheckIn.write!(today, "night", { sleep: "good" })
      CheckIn.write!(today, "day", { stress: "high" })

      _(CheckIn.clear!(today, "night").group_json("day")[:stress]).must_equal "high"
      _(CheckIn.clear!(today, "day")).must_be_nil
      _(CheckIn.count).must_equal 0
    end

    it "refuses values it doesn't know, and a day after today" do
      _ { CheckIn.write!(today, "night", { sleep: "terrible" }) }.must_raise Sequel::ValidationFailed
      _ { CheckIn.write!(today, "day", { sore_areas: ["elbows"] }) }.must_raise Sequel::ValidationFailed
      _ { CheckIn.write!(today, "day", { ill: "yes" }) }.must_raise Sequel::ValidationFailed
      _ { CheckIn.write!(today, "day", { note: "x" * 501 }) }.must_raise Sequel::ValidationFailed
      _ { CheckIn.write!(today + 1, "night", { sleep: "good" }) }.must_raise Sequel::ValidationFailed
      _ { CheckIn.write!(today, "night", { feeling: "good" }) }.must_raise CheckIn::Problem
      _ { CheckIn.write!(today, "week", {}) }.must_raise CheckIn::Problem
      _(CheckIn.count).must_equal 0
    end

    it "keeps each user's days to them" do
      CheckIn.write!(today, "night", { sleep: "good" })
      other = create_user("sam")

      Current.set(user: other) do
        _(CheckIn.count).must_equal 0
        CheckIn.write!(today, "night", { sleep: "poor" })
      end

      _(CheckIn.first.sleep).must_equal "good"
      _(CheckIn.everyone.count).must_equal 2
    end
  end

  describe "an agent" do
    def as_agent(&) = Current.set(agent_name: "Coach agent", &)

    it "fills only the empty fields, keeping what the user logged" do
      CheckIn.write!(today, "night", { sleep: "poor" })

      check_in, filled, kept = as_agent { CheckIn.fill!(today, night: { "sleep" => "good", "drinks" => "3+" }, day: { ill: true }) }

      _(filled).must_equal %w[night.drinks day.ill]
      _(kept).must_equal %w[night.sleep]
      _(check_in.group_json("night").values_at(:sleep, :drinks, :logged_by)).must_equal %w[poor 3+ manual]
      _(check_in.group_json("day")[:logged_by]).must_equal "llm"
      _(check_in.agent_name).must_equal "Coach agent"
      _(check_in.agent_at).wont_be_nil
    end

    it "can't change or clear a group the user logged" do
      CheckIn.write!(today, "night", { sleep: "poor" })

      _ { as_agent { CheckIn.write!(today, "night", { sleep: "good" }) } }.must_raise Record::UserOnly
      _ { as_agent { CheckIn.clear!(today, "night") } }.must_raise Record::UserOnly
      _(CheckIn.first.sleep).must_equal "poor"
    end

    it "logs today or up to a week back" do
      _(as_agent { CheckIn.fill!(today - 7, day: { stress: "high" }) }.first.date).must_equal today - 7
      _ { as_agent { CheckIn.fill!(today - 8, day: { stress: "high" }) } }.must_raise CheckIn::Problem
    end
  end
end
