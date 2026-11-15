require "test_helper"

describe "equipment API" do
  include RequestHelpers

  describe "GET /api/equipment" do
    it "lists the catalogue in seed order, with what the user owns" do
      get "/api/equipment"

      _(last_response.status).must_equal 200
      _(json.map { it["slug"] }).must_equal %w[mat bench stability_ball weight dumbbell kettlebell hangboard step]
      _(json.find { it["slug"] == "dumbbell" }).must_equal(
        "id" => equipment("dumbbell").id, "slug" => "dumbbell", "name" => "Dumbbells",
        "owned" => true, "weights" => [10, 20], "unit" => "lb", "any_weight" => false
      )
    end

    it "shows each user what they own" do
      someone = create_user("someone")
      Current.set(user: someone) { inventory("dumbbell").update(weights: [5]) }
      inventory("stability_ball").update(owned: false)

      sign_in(someone)
      get "/api/equipment"

      _(json.find { it["slug"] == "dumbbell" }["weights"]).must_equal [5]
      _(json.find { it["slug"] == "stability_ball" }["owned"]).must_equal true
    end

    it "lists an item the user has no row for as not owned, and leaves retired ones out" do
      UserEquipment.where(equipment: equipment("hangboard")).delete
      equipment("step").update(retired: true)
      get "/api/equipment"

      _(json.find { it["slug"] == "hangboard" }.slice("owned", "weights")).must_equal("owned" => false, "weights" => [])
      _(json.map { it["slug"] }).wont_include "step"
    end

    it "lists the generic weight as owned with the gear in set weights, with all their weights" do
      get "/api/equipment"
      _(json.find { it["slug"] == "weight" }.slice("owned", "weights", "unit", "any_weight")).must_equal(
        "owned" => true, "weights" => [10, 20, 40], "unit" => "lb", "any_weight" => true
      )

      Equipment.weighted.all.each { inventory(it.slug).update(owned: false) }
      get "/api/equipment"
      _(json.find { it["slug"] == "weight" }.slice("owned", "weights")).must_equal("owned" => false, "weights" => [])
    end
  end

  describe "PATCH /api/equipment/:id" do
    it "refuses to change the generic weight" do
      patch_json "/api/equipment/#{equipment("weight").id}", owned: false

      _(last_response.status).must_equal 422
      _(UserEquipment.where(equipment_id: equipment("weight").id).count).must_equal 0
    end

    it "marks an item as not owned" do
      patch_json "/api/equipment/#{equipment("stability_ball").id}", owned: false

      _(last_response.status).must_equal 200
      _(json["owned"]).must_equal false
      _(inventory("stability_ball").owned).must_equal false
    end

    it "changes only the user's own" do
      someone = create_user("someone")
      patch_json "/api/equipment/#{equipment("dumbbell").id}", weights: [5]

      _(Current.set(user: someone) { inventory("dumbbell").weights }).must_equal [10, 20]
    end

    it "adds an item the user had no row for" do
      UserEquipment.where(equipment: equipment("hangboard")).delete
      patch_json "/api/equipment/#{equipment("hangboard").id}", owned: true

      _(last_response.status).must_equal 200
      _(inventory("hangboard").owned).must_equal true
    end

    it "reads owned sent as text" do
      { "off" => false, "0" => false, "yes" => true }.each do |sent, owned|
        patch_json "/api/equipment/#{equipment("stability_ball").id}", owned: sent

        _(json["owned"]).must_equal owned, sent
      end
    end

    it "changes the weights owned and keeps what is left out" do
      put_json "/api/equipment/#{equipment("dumbbell").id}", weights: [5, 10, 20]

      _(json["weights"]).must_equal [5, 10, 20]
      _(json["unit"]).must_equal "lb"
      _(json["owned"]).must_equal true
    end

    it "rejects weights that are not positive numbers" do
      patch_json "/api/equipment/#{equipment("kettlebell").id}", weights: [0, "heavy"]

      _(last_response.status).must_equal 422
      _(json["error"]["message"]).must_include "Weights must be positive numbers"
      _(inventory("kettlebell").weights).must_equal [40]
    end

    it "takes weights only for equipment with a unit" do
      patch_json "/api/equipment/#{equipment("mat").id}", weights: [5]

      _(last_response.status).must_equal 422
      _(json["error"]["message"]).must_include "Weights can only be listed for equipment with a unit"
    end

    it "takes the user's unit for an item, keeping the numbers" do
      someone = create_user("someone")
      patch_json "/api/equipment/#{equipment("kettlebell").id}", unit: "kg", weights: [16, 24]

      _(last_response.status).must_equal 200
      _(json.slice("weights", "unit")).must_equal("weights" => [16, 24], "unit" => "kg")
      _(equipment("kettlebell").unit).must_equal "lb"
      _(Current.set(user: someone) { inventory("kettlebell").unit }).must_equal "lb"

      patch_json "/api/equipment/#{equipment("kettlebell").id}", unit: "lb"
      _(json.slice("weights", "unit")).must_equal("weights" => [16, 24], "unit" => "lb")
    end

    it "relabels the weights that were owned ones of an item when its unit changes" do
      fly = exercise("reverse-fly")
      ExerciseWeight.remember!(fly, 20, "lb")
      step = step_for("cycle-1-workout-1", "reverse-fly")

      patch_json "/api/equipment/#{equipment("dumbbell").id}", unit: "kg"

      _(last_response.status).must_equal 200
      _(step.refresh.weight).must_equal({ value: 10.0, unit: "kg" })
      _(ExerciseWeight.first!(exercise_id: fly.id).weight).must_equal({ value: 20.0, unit: "kg" })
      get "/api/workouts/#{step.block.workout_id}"
      shown = json["blocks"].flat_map { it["steps"] }.find { it["id"] == step.id }
      _(shown["target"]["weight"]).must_equal({ "value" => 20.0, "unit" => "kg" })
    end

    it "follows the user's unit until weights are listed, then keeps theirs" do
      UserEquipment.where(equipment: equipment("kettlebell")).delete
      Setting.current.update(unit: "kg")

      get "/api/equipment"
      _(json.find { it["slug"] == "kettlebell" }["unit"]).must_equal "kg"

      patch_json "/api/equipment/#{equipment("kettlebell").id}", owned: true, weights: [16]
      _(inventory("kettlebell").unit).must_equal "kg"

      Setting.current.update(unit: "lb")
      get "/api/equipment"
      _(json.find { it["slug"] == "kettlebell" }["unit"]).must_equal "kg"
      _(json.find { it["slug"] == "mat" }["unit"]).must_be_nil
    end

    it "takes a unit only for equipment with weights, and only lb or kg" do
      patch_json "/api/equipment/#{equipment("mat").id}", unit: "kg"
      _(last_response.status).must_equal 422
      _(json["error"]["message"]).must_include "Unit can only be set for equipment with weights"

      patch_json "/api/equipment/#{equipment("kettlebell").id}", unit: "stone"
      _(last_response.status).must_equal 422
      _(inventory("kettlebell").unit).must_equal "lb"
    end

    it "can't change a retired item" do
      equipment("step").update(retired: true)
      patch_json "/api/equipment/#{equipment("step").id}", owned: false

      _(last_response.status).must_equal 404
    end
  end

  describe "GET /api/exercises?equipment=" do
    def slugs = json.map { it["slug"] }

    it "keeps to what is owned" do
      inventory("stability_ball").update(owned: false)

      get "/api/exercises?equipment=owned"

      _(slugs).wont_include "swiss-ball-hamstring-curl"
      _(slugs).must_include "goblet-squat"
      _(slugs).must_include "plank"
    end

    it "keeps to a given list of equipment" do
      get "/api/exercises?equipment=dumbbell"

      _(slugs).must_include "goblet-squat"
      _(slugs).must_include "plank"
      _(slugs).wont_include "rear-foot-elevated-split-squat"
      _(slugs).wont_include "swiss-ball-hamstring-curl"
    end

    it "keeps to bodyweight when the list is empty" do
      get "/api/exercises?equipment="

      _(json).wont_be_empty
      _(json.flat_map { it["equipment"] }).must_be_empty
    end

    it "lists everything when everything is owned" do
      get "/api/exercises?equipment=owned"

      _(json.size).must_equal Exercise.count
    end

    it "rejects unknown equipment" do
      get "/api/exercises?equipment=dumbbell,rowing_machine"

      _(last_response.status).must_equal 400
      _(json["error"]["message"]).must_equal "unknown equipment: rowing_machine"
    end
  end
end
