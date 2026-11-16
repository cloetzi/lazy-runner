# frozen_string_literal: true

require "test_helper"

describe "exercise weight API" do
  include RequestHelpers

  let(:squat) { exercise("goblet-squat") }

  describe "GET /api/exercises/:id/weight" do
    it "is empty until a weight is remembered" do
      get "/api/exercises/#{squat.id}/weight"

      _(last_response.status).must_equal 200
      _(json["exercise_id"]).must_equal squat.id
      _(json["value"]).must_be_nil
      _(json.keys).wont_include "suggestion"
    end

    it "returns the remembered weight" do
      ExerciseWeight.create(exercise: squat, value: 45, unit: "lb")

      get "/api/exercises/#{squat.id}/weight"

      _(json["value"]).must_equal 45.0
      _(json["unit"]).must_equal "lb"
    end
  end

  describe "PATCH /api/exercises/:id/weight" do
    it "takes the weight in the exercise's unit when no unit is sent" do
      patch_json "/api/exercises/#{squat.id}/weight", value: 40

      _(last_response.status).must_equal 200
      _(json.slice("value", "unit")).must_equal({ "value" => 40.0, "unit" => squat.weight_unit })
    end

    it "needs a value" do
      patch_json "/api/exercises/#{squat.id}/weight", unit: "kg"

      _(last_response.status).must_equal 400
      _(json["error"]["fields"]).must_equal({ "value" => ["is required"] })
    end
  end

  describe "PUT /api/exercises/:id/weight" do
    it "remembers no weight, which wins over the weight a workout step sets" do
      ExerciseWeight.create(exercise: squat, value: 20, unit: "lb")

      put_json "/api/exercises/#{squat.id}/weight", value: nil

      _(last_response.status).must_equal 200
      _(json.slice("value", "unit")).must_equal({ "value" => nil, "unit" => "lb" })

      get "/api/workouts/#{workout("cycle-1-workout-1").id}"
      step = json["blocks"].flat_map { it["steps"] }.find { it["exercise"]["id"] == squat.id }
      _(step["weight"]).must_equal({ "value" => 40.0, "unit" => "lb" })
      _(step["target"]["weight"]).must_be_nil
      _(step["weight_unit"]).must_equal "lb"

      get "/api/exercises/#{squat.id}/weight"
      _(json.values_at("value", "unit")).must_equal [nil, "lb"]
      _(json["updated_at"]).wont_be_nil
    end

    it "takes a weight of 0 as no weight" do
      put_json "/api/exercises/#{squat.id}/weight", value: 0, unit: "lb"

      _(json["value"]).must_be_nil
    end

    it "refuses an empty value rather than taking it for no weight" do
      ExerciseWeight.create(exercise: squat, value: 20, unit: "lb")

      put_json "/api/exercises/#{squat.id}/weight", value: ""

      _(last_response.status).must_equal 422
      _(ExerciseWeight.first!(exercise_id: squat.id).value).must_equal 20
    end

    it "shows no weight in the exercise's history" do
      put_json "/api/exercises/#{squat.id}/weight", value: nil
      get "/api/exercises/#{squat.id}/history"

      _(last_response.status).must_equal 200
      _(json["remembered"].values_at("value", "unit")).must_equal [nil, "lb"]
    end

    it "remembers a weight" do
      put_json "/api/exercises/#{squat.id}/weight", value: 42.5, unit: "lb"

      _(last_response.status).must_equal 200
      _(json["value"]).must_equal 42.5
      _(json.keys).wont_include "reps"
      _(ExerciseWeight.first!(exercise: squat).value).must_equal 42.5
    end

    it "keeps the weight as it was when it is sent again unchanged" do
      put_json "/api/exercises/#{squat.id}/weight", value: 42.5, unit: "lb"
      updated = json["updated_at"]

      travel_to(Time.now + 60) { put_json "/api/exercises/#{squat.id}/weight", value: 42.5, unit: "lb" }

      _(json["updated_at"]).must_equal updated
    end

    it "rejects reps and seconds" do
      put_json "/api/exercises/#{squat.id}/weight", value: 40, unit: "lb", reps: 10

      _(last_response.status).must_equal 400
      _(json["error"]["message"]).must_include "reps and seconds are set per workout step"

      put_json "/api/exercises/#{squat.id}/weight", value: 40, unit: "lb", reps: nil, seconds: 30

      _(last_response.status).must_equal 400
      _(json["error"]["message"]).must_include "reps and seconds can't be remembered"
      _(ExerciseWeight.where(exercise: squat).empty?).must_equal true
    end

    it "replaces the remembered weight" do
      put_json "/api/exercises/#{squat.id}/weight", value: 45, unit: "lb"
      put_json "/api/exercises/#{squat.id}/weight", value: 50, unit: "lb"

      _(ExerciseWeight.where(exercise: squat).count).must_equal 1
      _(json["value"]).must_equal 50.0
    end

    it "keeps a weight given in kg in the exercise's unit" do
      put_json "/api/exercises/#{squat.id}/weight", value: 25, unit: "kg"

      _(json.slice("value", "unit")).must_equal({ "value" => 55.12, "unit" => "lb" })
      _(ExerciseWeight.first!(exercise: squat).weight).must_equal({ value: 55.12, unit: "lb" })
    end

    it "snaps a converted weight to the owned weight it rounds from" do
      put_json "/api/exercises/#{squat.id}/weight", value: 9, unit: "kg"

      _(json.slice("value", "unit")).must_equal({ "value" => 20.0, "unit" => "lb" })
    end

    it "rejects a negative weight or an unknown unit" do
      put_json "/api/exercises/#{squat.id}/weight", value: -5, unit: "stone"

      _(last_response.status).must_equal 422
      _(json["error"]["message"]).must_include "Unit"
    end
  end

  it "makes the remembered weight win over the seed in every plan" do
    put_json "/api/exercises/#{squat.id}/weight", value: 45, unit: "lb"

    get "/api/workouts/#{workout("cycle-1-workout-1").id}"
    item = json["plan"]["items"].find { it["exercise"]["slug"] == "goblet-squat" }

    _(item["weight"]).must_equal({ "value" => 45.0, "unit" => "lb" })
    _(item["seed_weight"]).must_equal({ "value" => 40.0, "unit" => "lb" })
  end

  it "keeps each workout's own reps and gives both the remembered weight" do
    step_for("cycle-1-workout-1", "goblet-squat").update(reps: 5)
    step_for("home-strength-a", "goblet-squat").update(reps: 15)

    put_json "/api/exercises/#{squat.id}/weight", value: 45, unit: "lb"

    targets = %w[cycle-1-workout-1 home-strength-a].map do |slug|
      get "/api/workouts/#{workout(slug).id}"
      json["blocks"].flat_map { it["steps"] }.find { it["exercise"]["slug"] == "goblet-squat" }["target"]
    end
    _(targets.map { it["reps"] }).must_equal [5, 15]
    _(targets.map { it["weight"] }).must_equal [{ "value" => 45.0, "unit" => "lb" }] * 2
  end
end
