# frozen_string_literal: true

require "test_helper"

describe Current do
  include ActiveSupport::Testing::TimeHelpers

  before { travel_to Time.utc(2026, 11, 16, 12) }
  after { travel_back }

  describe ".today" do
    it "is the server's day unless the request gave one" do
      Current.set(client_today: nil) { _(Current.today).must_equal Date.new(2026, 11, 16) }
      Current.set(client_today: Date.new(2026, 11, 17)) { _(Current.today).must_equal Date.new(2026, 11, 17) }
    end
  end

  describe ".within_a_day" do
    it "takes a day either side of the server's, and nothing further" do
      _(Current.within_a_day(Date.new(2026, 11, 15))).must_equal Date.new(2026, 11, 15)
      _(Current.within_a_day(Date.new(2026, 11, 17))).must_equal Date.new(2026, 11, 17)
      _(Current.within_a_day(Date.new(2026, 11, 14))).must_be_nil
      _(Current.within_a_day(Date.new(2026, 11, 18))).must_be_nil
    end
  end
end
