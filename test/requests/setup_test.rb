# frozen_string_literal: true

require "test_helper"

# GET /api/account/setup: what Today's "Getting set up" card ticks off.
describe "GET /api/account/setup" do
  include RequestHelpers
  include SeedHelpers

  it "says what the owner has set up" do
    get "/api/account/setup?today=#{Date.today.iso8601}"

    _(last_response.status).must_equal 200
    _(json).must_equal({ "gear" => true, "workouts" => true, "planned" => false, "assistant" => false, "invited" => false })
  end

  it "ticks off a planned week, an assistant and someone invited" do
    Routine.plan!({ workout_id: workout("cycle-1-workout-2").id, weekdays: [1, 4] }, today: Date.today)
    ApiToken.issue!(user, "Coach agent")
    Invite.issue!
    get "/api/account/setup"

    _(json.values_at("planned", "assistant", "invited")).must_equal [true, true, true]
  end

  it "counts a session planned ahead as planning" do
    Session.create(workout: workout("cycle-1-workout-2"), date: Date.today + 3, status: "planned", created_by: "manual")
    get "/api/account/setup"

    _(json["planned"]).must_equal true
  end

  it "leaves inviting to the owner, and a new account has nothing" do
    other = create_user("bea", bare: true)
    sign_out!
    sign_in other
    get "/api/account/setup"

    _(json).must_equal({ "gear" => false, "workouts" => false, "planned" => false, "assistant" => false, "invited" => nil })
  end

  it "counts only gear that is owned" do
    UserEquipment.where(owned: true).update(owned: false)
    get "/api/account/setup"

    _(json["gear"]).must_equal false
  end
end
