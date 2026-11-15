require "test_helper"

describe "API errors" do
  include RequestHelpers

  let(:session) { session_on("2026-10-19", "planned") }

  # [method, path, body, status, code], one or more per controller.
  let(:cases) do
    squat = exercise("goblet-squat")
    seeded = workout("cycle-1-workout-1")
    archived = workout("cycle-1-workout-2").tap { it.update(archived_at: Time.now) }
    [
      [:get, "/api/today?date=tomorrow", nil, 400, "bad_request"],
      [:get, "/api/today?workout_id=0", nil, 404, "not_found"],
      [:get, "/api/exercises/0", nil, 404, "not_found"],
      [:get, "/api/exercises?equipment=rowing_machine", nil, 400, "bad_request"],
      [:get, "/api/exercises/0/alternatives", nil, 404, "not_found"],
      [:patch, "/api/equipment/0", { owned: true }, 404, "not_found"],
      [:patch, "/api/equipment/#{Equipment.first.id}", { weights: [-5] }, 422, "invalid"],
      [:get, "/api/exercises/0/weight", nil, 404, "not_found"],
      [:patch, "/api/exercises/#{squat.id}/weight", { value: -1 }, 422, "invalid"],
      [:patch, "/api/exercises/#{squat.id}/weight", { reps: 8 }, 400, "bad_request"],
      [:get, "/api/workouts/0", nil, 404, "not_found"],
      [:patch, "/api/workouts/#{archived.id}", { title: "Mine" }, 403, "forbidden"],
      [:post, "/api/examples/cycle-1/import", {}, 409, "already_imported"],
      [:post, "/api/examples/marathon/import", {}, 404, "not_found"],
      [:patch, "/api/workouts/0", { title: "Mine" }, 404, "not_found"],
      [:delete, "/api/workouts/0", nil, 404, "not_found"],
      [:post, "/api/workouts/0/duplicate", {}, 404, "not_found"],
      [:post, "/api/sessions", { workout_id: seeded.id, status: "done" }, 400, "bad_request"],
      [:post, "/api/sessions", { date: "2026-10-19" }, 400, "bad_request"],
      [:patch, "/api/sessions/0", { status: "skipped" }, 404, "not_found"],
      [:delete, "/api/sessions/0", nil, 404, "not_found"],
      [:post, "/api/sessions/0/sets", { step_id: step_for("cycle-1-workout-1", "goblet-squat").id, set_number: 1 }, 404, "not_found"],
      [:post, "/api/sessions/#{session.id}/sets", { set_number: 1 }, 400, "bad_request"],
      [:post, "/api/sessions/0/complete", {}, 404, "not_found"],
      [:post, "/api/sessions", { workout_id: seeded.id, date: "2020-01-01" }, 422, "invalid"],
      [:patch, "/api/sessions/#{session_on("2026-10-19", "in_progress").id}", { date: "2099-01-01" }, 409, "conflict"],
      [:get, "/api/sessions?status=someday", nil, 400, "bad_request"],
      [:get, "/api/sessions/0", nil, 404, "not_found"],
      [:post, "/api/sessions/#{session.id}/sets", { step_id: step_for("cycle-1-workout-1", "goblet-squat").id, set_number: 0 }, 422, "invalid"],
      [:post, "/api/sessions/#{session.id}/complete", { feedback: "meh" }, 422, "invalid"],
      [:post, "/api/sessions/#{session.id}/complete", { note: "x" * 2001 }, 422, "invalid"],
      [:patch, "/api/sessions/#{session.id}", { note: "x" * 2001 }, 422, "invalid"],
      [:post, "/api/sessions", { workout_id: seeded.id, date: "2099-01-01", note: "x" * 2001 }, 422, "invalid"],
      [:patch, "/api/sessions/#{session.id}/completion", { note: "later" }, 404, "not_found"],
      [:get, "/api/history?days=0", nil, 400, "bad_request"],
      [:get, "/api/exercises/0/history", nil, 404, "not_found"]
    ]
  end

  it "has one shape everywhere: a code and a message" do
    cases.each do |method, path, body, status, code|
      body.nil? ? send(method, path) : send(:"#{method}_json", path, body)

      _([method, path, last_response.status]).must_equal [method, path, status]
      _(json["error"]["code"]).must_equal code
      _(json["error"]["message"]).must_be_kind_of String
    end
  end

  it "names the resource and id that was not found" do
    get "/api/sessions/0"

    _(json["error"]).must_equal({ "code" => "not_found", "message" => "Session 0 not found", "resource" => "session", "id" => "0" })
  end

  it "says which fields are invalid and why" do
    post_json "/api/sessions/#{session.id}/complete", feedback: "meh", rpe: 11

    _(json["error"]["fields"]).must_equal({ "rpe" => ["must be in 1..10"], "feedback" => ["is not included in the list"] })
  end

  it "says a missing id is required rather than not found" do
    post_json "/api/sessions/#{session.id}/sets", set_number: 1

    _(json["error"]).must_equal({ "code" => "bad_request", "message" => "step_id is required", "fields" => { "step_id" => ["is required"] } })
  end

  it "names the parameter that can't be read" do
    get "/api/today?date=tomorrow"

    _(json["error"]).must_equal({ "code" => "bad_request", "message" => "date must be a date as YYYY-MM-DD", "fields" => { "date" => ["must be a date as YYYY-MM-DD"] } })
  end

  # Nothing along the way keeps a copy of the user's data, and no browser
  # reads it as anything but JSON.
  it "marks every API answer no-store and nosniff, the sign-in gate's too" do
    get "/api/today"
    _(last_response.headers.values_at("cache-control", "x-content-type-options")).must_equal %w[no-store nosniff]

    sign_out!
    get "/api/today"
    _(last_response.status).must_equal 401
    _(last_response.headers.values_at("cache-control", "x-content-type-options")).must_equal %w[no-store nosniff]

    # The reference page says how it is cached.
    get "/api/openapi", {}, { "rack.input" => StringIO.new }
    _(last_response.headers["cache-control"]).must_equal "no-cache"
  end
end
