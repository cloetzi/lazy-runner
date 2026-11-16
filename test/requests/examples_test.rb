# frozen_string_literal: true

require "test_helper"

describe "example programs API" do
  include RequestHelpers

  def bare_user = create_user("someone", bare: true)

  describe "GET /api/examples" do
    it "lists each example with its workouts, minutes, gear and whether it is imported" do
      sign_in(bare_user)
      get "/api/examples"

      _(last_response.status).must_equal 200
      _(json.map { it["slug"] }).must_equal %w[cycle-1 home-strength no-gear]
      cycle = json.first
      _(cycle.slice("name", "imported")).must_equal({ "name" => "Cycle 1", "imported" => false })
      _(cycle["workouts"].map { it.slice("slug", "kind") }.first).must_equal({ "slug" => "cycle-1-warmup", "kind" => "warmup" })
      _(cycle["workouts"].map { it["estimated_minutes"] }).must_be(:all?, Integer)
      _(cycle["equipment"]).must_include "kettlebell"
      session_a = json.find { it["slug"] == "home-strength" }["workouts"].first
      _(session_a["exercises"].first(2))
        .must_equal [exercise("glute-bridge-single-leg-lift").name, exercise("side-plank-knee-leg-raise").name]
      _(session_a["exercises"]).must_equal session_a["exercises"].uniq
    end

    it "marks the gear the user owns, and counts the exercises that need gear they lack" do
      owner = user
      someone = bare_user
      Current.set(user: someone) { UserEquipment.create(equipment: equipment("dumbbell"), owned: true, weights: [10, 20]) }
      sign_in(someone)
      get "/api/examples"

      fit = json.to_h { [it["slug"], it] }
      _(fit["no-gear"]["missing_exercises"]).must_equal 0
      _(fit["no-gear"]["gear"].select { it["owned"] == false }).must_be_empty
      cycle = fit["cycle-1"]
      _(cycle["missing_exercises"]).must_be :>, 0
      _(cycle["gear"].find { it["slug"] == "dumbbell" })
        .must_equal({ "slug" => "dumbbell", "name" => equipment("dumbbell").name, "owned" => true })
      _(cycle["gear"].find { it["slug"] == "kettlebell" }["owned"]).must_equal false
      # Any dumbbell will do for an exercise that needs just a weight.
      _(cycle["gear"].find { it["slug"] == "weight" }["owned"]).must_equal true

      sign_out!
      sign_in(owner)
      get "/api/examples"
      _(json.map { it["missing_exercises"] }).must_equal [0, 0, 0]
    end

    it "marks what the user imported" do
      get "/api/examples"

      _(json.map { it["imported"] }).must_equal [true, true, true]
    end
  end

  describe "POST /api/examples/:slug/import" do
    before { sign_in(@someone = bare_user) }

    it "copies the program and its workouts into the user's own" do
      post_json "/api/examples/cycle-1/import"

      _(last_response.status).must_equal 201
      _(json.slice("example_slug", "name")).must_equal({ "example_slug" => "cycle-1", "name" => "Cycle 1" })
      _(json["workouts"].map { it["example_slug"] }).must_equal %w[cycle-1-warmup cycle-1-workout-1 cycle-1-workout-2 cycle-1-cooldown]
      _(json["workouts"].map { it["source"] }.uniq).must_equal ["user"]

      get "/api/today"
      _(json["workout_id"]).must_equal Current.set(user: @someone) { workout("cycle-1-workout-1").id }
    end

    it "is a 409 the second time, unless a copy is asked for" do
      post_json "/api/examples/cycle-1/import"
      post_json "/api/examples/cycle-1/import"

      _(last_response.status).must_equal 409
      _(json["error"])
        .must_equal({ "code" => "already_imported", "message" => "Cycle 1 is already imported; import it again with copy to add another" })

      post_json "/api/examples/cycle-1/import", copy: true
      _(last_response.status).must_equal 201
      _(json["name"]).must_equal "Cycle 1 (copy)"
    end

    it "snaps weights to the gear the user owns, and keeps steps needing gear they lack" do
      patch_json "/api/equipment/#{equipment("dumbbell").id}", owned: true, weights: [12]
      post_json "/api/examples/cycle-1/import"

      get "/api/workouts/#{json["workouts"][1]["id"]}"
      steps = json["blocks"].flat_map { it["steps"] }.index_by { it["exercise"]["slug"] }
      _(steps["reverse-fly"]["weight"]).must_equal({ "value" => 12.0, "unit" => "lb" })
      _(steps["straight-leg-deadlift"]["weight"]).must_be_nil
      _(steps["straight-leg-deadlift"]["equipment_needed"]).must_equal ["kettlebell"]
      _(steps["goblet-squat"]["weight"]).must_equal({ "value" => 12.0, "unit" => "lb" })
    end

    it "keeps one user's import apart from another's" do
      post_json "/api/examples/home-strength/import"
      theirs = json["id"]

      _(Program.where(example_slug: "home-strength").count).must_equal 1
      _(Program.where(example_slug: "home-strength").get(:id)).wont_equal theirs
    end

    it "is a 404 for an example that isn't there" do
      post_json "/api/examples/marathon/import"

      _(last_response.status).must_equal 404
      _(json["error"]["message"]).must_equal "no example program marathon"
    end
  end
end
