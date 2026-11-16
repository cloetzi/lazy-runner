# frozen_string_literal: true

require "test_helper"

# Dates and date ranges as the API and the MCP tools read them.
describe DateRange do
  let(:today) { Date.new(2026, 10, 20) }

  def resolve(from = nil, to = nil, **defaults)
    range = DateRange.resolve(from, to, **defaults, today:)
    [range.begin.iso8601, range.end.iso8601]
  end

  it "runs the 28 days up to today, or from today on when looking ahead" do
    _(resolve).must_equal %w[2026-09-23 2026-10-20]
    _(resolve(back: 0)).must_equal %w[2026-10-20 2026-11-16]
  end

  it "starts a range without dates some days back when asked" do
    _(resolve(back: 7)).must_equal %w[2026-10-13 2026-11-09]
    _(resolve("2026-11-02", back: 7)).must_equal %w[2026-11-02 2026-11-29]
  end

  it "runs 28 days on from a first day, or back from a last one" do
    _(resolve("2026-11-02")).must_equal %w[2026-11-02 2026-11-29]
    _(resolve(nil, "2026-10-07")).must_equal %w[2026-09-10 2026-10-07]
    _(resolve("2026-10-01", "2026-10-03")).must_equal %w[2026-10-01 2026-10-03]
  end

  it "takes Dates as well as text" do
    _(resolve(Date.new(2026, 10, 1), Date.new(2026, 10, 1))).must_equal %w[2026-10-01 2026-10-01]
  end

  it "says which end is wrong" do
    error = _ { resolve("2026-10-10", "2026-10-01") }.must_raise DateRange::Invalid
    _([error.field, error.message]).must_equal [:from, "from must not be after to"]

    error = _ { resolve("next week") }.must_raise DateRange::Invalid
    _([error.field, error.problem]).must_equal [:from, "must be a date as YYYY-MM-DD"]
  end

  it "reads YYYY-MM-DD only, not the other ISO 8601 forms" do
    _(DateRange.date("2026-11-01", :date)).must_equal Date.new(2026, 11, 1)
    %w[2026-305 20261101 2026-W44-7 2026-11-1].each do |given|
      _ { DateRange.date(given, :date) }.must_raise DateRange::Invalid
    end
  end

  it "runs at most 366 days" do
    _(resolve("2026-01-01", "2027-01-01")).must_equal %w[2026-01-01 2027-01-01]

    error = _ { resolve("2026-01-01", "2027-01-02") }.must_raise DateRange::Invalid
    _([error.field, error.message]).must_equal [:to, "a range is at most 366 days"]
  end
end
