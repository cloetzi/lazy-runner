# frozen_string_literal: true

require "test_helper"

describe "check-ins API" do
  include RequestHelpers

  # A Saturday.
  before { travel_to Time.utc(2026, 11, 21, 18) }
  after { travel_back }

  let(:night) { { sleep: "poor", drinks: "3+", tags: %w[late_to_bed], note: "Birthday dinner" } }

  describe "PUT /api/check_ins/:date/:group" do
    it "writes last night, and answers the day" do
      put_json "/api/check_ins/2026-11-21/night", night

      _(last_response.status).must_equal 200
      _(json["date"]).must_equal "2026-11-21"
      _(json["night"]).must_equal({ "sleep" => "poor", "drinks" => "3+", "tags" => ["late_to_bed"], "note" => "Birthday dinner",
                                    "logged_by" => "manual" })
      _(json["day"]).must_be_nil
    end

    it "writes how the day felt beside the night" do
      put_json "/api/check_ins/2026-11-21/night", night
      put_json "/api/check_ins/2026-11-21/day", feeling: "ok", sore: "a_bit", sore_areas: %w[knees], ill: false

      _(json["night"]["drinks"]).must_equal "3+"
      _(json["day"].slice("feeling", "sore", "sore_areas")).must_equal({ "feeling" => "ok", "sore" => "a_bit", "sore_areas" => ["knees"] })
    end

    it "answers 204 when a write leaves the day empty" do
      put_json "/api/check_ins/2026-11-21/night", night
      put_json "/api/check_ins/2026-11-21/night", {}

      _(last_response.status).must_equal 204
      _(CheckIn.count).must_equal 0
    end

    it "takes the device's today, and refuses a day after it" do
      put_json "/api/check_ins/2026-11-22/night", night.merge(today: "2026-11-22")
      _(last_response.status).must_equal 200

      put_json "/api/check_ins/2026-11-24/night", night
      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal({ "date" => ["must not be after today"] })
    end

    it "refuses an unknown value, group or date" do
      put_json "/api/check_ins/2026-11-21/night", sleep: "dreadful"
      _(last_response.status).must_equal 422
      _(json["error"]["fields"].keys).must_equal ["sleep"]

      put_json "/api/check_ins/2026-11-21/week", night
      _(last_response.status).must_equal 422

      put_json "/api/check_ins/21-11-2026/night", night
      _(last_response.status).must_equal 422
    end
  end

  describe "DELETE /api/check_ins/:date/:group" do
    it "clears one group and answers what is left" do
      put_json "/api/check_ins/2026-11-21/night", night
      put_json "/api/check_ins/2026-11-21/day", stress: "high"

      delete "/api/check_ins/2026-11-21/night"
      _(last_response.status).must_equal 200
      _(json["night"]).must_be_nil
      _(json["day"]["stress"]).must_equal "high"

      delete "/api/check_ins/2026-11-21/day"
      _(last_response.status).must_equal 204
    end
  end

  describe "GET /api/check_ins" do
    it "lists the days with a check-in in the range, by day" do
      put_json "/api/check_ins/2026-11-21/night", night
      put_json "/api/check_ins/2026-11-19/day", stress: "high"
      put_json "/api/check_ins/2026-10-01/day", stress: "low"

      get "/api/check_ins", from: "2026-11-15", to: "2026-11-21"

      _(json["check_ins"].map { it["date"] }).must_equal %w[2026-11-19 2026-11-21]
    end

    it "shows another user none of them" do
      put_json "/api/check_ins/2026-11-21/night", night
      sam = create_user("sam")
      sign_out!
      sign_in sam

      get "/api/check_ins"

      _(json["check_ins"]).must_equal []
    end
  end

  it "puts the check-ins on the calendar, the Coach board and, from an agent, the news" do
    put_json "/api/check_ins/2026-11-20/day", feeling: "good"
    Current.set(agent_name: "Coach agent") { CheckIn.fill!(Date.new(2026, 11, 21), night: { drinks: "3+" }) }

    get "/api/calendar", from: "2026-11-16", to: "2026-11-22"
    _(json["check_ins"].map { it["date"] }).must_equal %w[2026-11-20 2026-11-21]

    get "/api/coach"
    _(json["week"]["check_ins"].map { it["date"] }).must_equal %w[2026-11-20 2026-11-21]

    get "/api/coach/news"
    _(json["check_ins"].map { [it["date"], it["agent_name"]] }).must_equal [["2026-11-21", "Coach agent"]]
  end
end
