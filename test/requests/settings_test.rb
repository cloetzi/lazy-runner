# frozen_string_literal: true

require "test_helper"

describe "settings API" do
  include RequestHelpers

  describe "GET /api/settings" do
    it "shows weights in lb until it is changed" do
      get "/api/settings"

      _(last_response.status).must_equal 200
      _(json["unit"]).must_equal "lb"
      _(json["distance_unit"]).must_equal "km"
    end
  end

  describe "PATCH /api/settings" do
    it "keeps the unit for every client" do
      patch_json "/api/settings", unit: "kg"

      _(last_response.status).must_equal 200
      _(json["unit"]).must_equal "kg"
      get "/api/settings"
      _(json["unit"]).must_equal "kg"
    end

    it "keeps what it is not sent" do
      patch_json "/api/settings", unit: "kg"
      patch_json "/api/settings", {}

      _(json["unit"]).must_equal "kg"
    end

    it "keeps the distance unit apart from the weight unit" do
      patch_json "/api/settings", distance_unit: "mi"

      _(json.slice("unit", "distance_unit")).must_equal({ "unit" => "lb", "distance_unit" => "mi" })
      patch_json "/api/settings", distance_unit: "furlong"
      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal({ "distance_unit" => ["is not included in the list"] })
    end

    it "rejects a unit it does not know" do
      patch_json "/api/settings", unit: "stone"

      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal({ "unit" => ["is not included in the list"] })
      _(Setting.unit).must_equal "lb"
    end
  end

  it "goes with today and the workout view, so the player needs no extra call" do
    Setting.current.update(unit: "kg")

    get "/api/today"
    _(json["unit"]).must_equal "kg"

    get "/api/workouts/#{workout("cycle-1-workout-1").id}"
    _(json["unit"]).must_equal "kg"
  end
end
