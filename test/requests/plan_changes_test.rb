require "test_helper"

describe "plan changes API" do
  include RequestHelpers

  # A Wednesday.
  before { travel_to Time.utc(2026, 11, 11, 12) }
  after { travel_back }

  let(:strength) { workout("cycle-1-workout-1") }
  let(:token) { ApiToken.issue!(user, "Coach agent").last }

  def d(text) = Date.iso8601(text)

  # A request as the agent: with the API token, as a script or MCP call has it.
  def as_agent(method, path, body = {})
    send(method, path, JSON.generate(body), RequestHelpers::JSON_ENV.merge("HTTP_AUTHORIZATION" => "Bearer #{token}"))
    _(last_response.status).must_be :<, 300, last_response.body
  end

  def plan(date, **body)
    post_json "/api/sessions", { workout_id: strength.id, date:, **body }
    _(last_response.status).must_equal 201
    json
  end

  def calendar(from = "2026-11-09", to = "2026-11-15")
    get "/api/calendar", { from:, to:, today: "2026-11-11" }
    _(last_response.status).must_equal 200
    json
  end

  def changes(**query)
    get "/api/plan_changes", query
    _(last_response.status).must_equal 200, last_response.body
    json["changes"]
  end

  describe "GET /api/plan_changes" do
    it "lists the changes newest first, by the user or an agent, with what changed and whether it can be taken back" do
      session = plan("2026-11-12", note: "Legs")
      as_agent(:patch, "/api/sessions/#{session["id"]}", date: "2026-11-14")

      listed = changes
      _(listed.map { it.values_at("action", "changed_by", "agent_name", "session_id", "from_date", "to_date", "undoable") }).must_equal [
        ["moved", "llm", "Coach agent", session["id"], "2026-11-12", "2026-11-14", true],
        ["planned", "manual", nil, session["id"], nil, "2026-11-12", false]
      ]
      _(listed.first.values_at("was", "now")).must_equal [{ "date" => "2026-11-12", "position" => 1 }, { "date" => "2026-11-14", "position" => 1 }]
      _(changes(by: "manual").map { it["action"] }).must_equal ["planned"]
      _(changes(from: "2026-11-01", to: "2026-11-10")).must_equal []
    end

    it "refuses an unknown author" do
      get "/api/plan_changes", by: "coach"
      _(last_response.status).must_equal 400
      _(json["error"]["fields"]).must_equal("by" => ["must be manual or llm"])
    end
  end

  describe "POST /api/plan_changes/:id/undo" do
    it "moves a session back, recorded as the user's change, and keeps the user's note" do
      session = plan("2026-11-12", note: "Mine")
      as_agent(:patch, "/api/sessions/#{session["id"]}", date: "2026-11-14")
      moved = changes.first

      post_json "/api/plan_changes/#{moved["id"]}/undo", today: "2026-11-11"

      _(last_response.status).must_equal 200
      _(json["change"].values_at("action", "changed_by", "undoes_id", "to_date")).must_equal ["moved", "manual", moved["id"], "2026-11-12"]
      _(json["undone"].values_at("undone_by_id", "undoable")).must_equal [json["change"]["id"], false]
      _(Session.with_pk(session["id"]).values.values_at(:date, :note)).must_equal [d("2026-11-12"), "Mine"]
    end

    it "puts a removed session back" do
      session = plan("2026-11-13")
      as_agent(:delete, "/api/sessions/#{session["id"]}?only=planned")
      removed = changes.first
      _(removed.values_at("action", "session_id", "from_date", "title")).must_equal ["removed", nil, "2026-11-13", strength.title]

      post_json "/api/plan_changes/#{removed["id"]}/undo"

      _(last_response.status).must_equal 200
      _(calendar["sessions"].map { it.values_at("date", "workout") }.map { [it[0], it[1]["id"]] }).must_equal [["2026-11-13", strength.id]]
    end

    it "answers 409 with why for a change that can't be taken back, and 404 for another user's" do
      session = plan("2026-11-12")
      planned = changes.first

      post_json "/api/plan_changes/#{planned["id"]}/undo"
      _(last_response.status).must_equal 409
      _(json["error"]["message"]).must_equal "take a planned session off the calendar instead"

      as_agent(:patch, "/api/sessions/#{session["id"]}", date: "2026-11-14")
      send(:post, "/api/plan_changes/#{changes.first["id"]}/undo", "{}", RequestHelpers::JSON_ENV.merge("HTTP_AUTHORIZATION" => "Bearer #{token}"))
      _(last_response.status).must_equal 403
      _(json["error"]["message"]).must_equal "only the user takes a change back, in the app"

      other = create_user("other")
      theirs = Current.set(user: other) { Session.plan!(workout: Workout.first!(example_slug: "cycle-1-workout-1"), date: d("2026-11-12")) && PlanChange.last }
      post_json "/api/plan_changes/#{theirs.id}/undo"
      _(last_response.status).must_equal 404
      _(session).wont_be_nil
    end
  end

  describe "GET /api/calendar" do
    it "carries the latest change an agent made to each item, and a line for each session it moved away or removed" do
      moved = plan("2026-11-12")
      plan("2026-11-13").then { as_agent(:delete, "/api/sessions/#{it["id"]}?only=planned") }
      mine = plan("2026-11-14")
      as_agent(:patch, "/api/sessions/#{moved["id"]}", date: "2026-11-15")

      shown = calendar
      by_id = shown["sessions"].to_h { [it["id"], it["change"]] }
      _(by_id[moved["id"]].values_at("action", "agent_name", "undoable")).must_equal ["moved", "Coach agent", true]
      _(by_id[mine["id"]]).must_be_nil
      _(shown["plan_changes"].map { it.values_at("action", "from_date") }).must_equal [["moved", "2026-11-12"], ["removed", "2026-11-13"]]

      post_json "/api/plan_changes/#{by_id[moved["id"]]["id"]}/undo"
      shown = calendar
      _(shown["sessions"].find { it["id"] == moved["id"] }["change"]).must_be_nil
      _(shown["plan_changes"].map { it["action"] }).must_equal ["removed"]
    end

    it "drops an item's change once the user changed it since" do
      session = plan("2026-11-12")
      as_agent(:patch, "/api/sessions/#{session["id"]}", date: "2026-11-14")
      patch_json "/api/sessions/#{session["id"]}", date: "2026-11-13"

      _(calendar["sessions"].find { it["id"] == session["id"] }["change"]).must_be_nil
    end

    it "drops a move's line once the user moved the session again" do
      session = plan("2026-11-12")
      as_agent(:patch, "/api/sessions/#{session["id"]}", date: "2026-11-14")
      patch_json "/api/sessions/#{session["id"]}", date: "2026-11-12"

      _(calendar["plan_changes"]).must_equal []
    end

    it "leaves out the lines of weeks gone by" do
      session = plan("2026-11-12")
      as_agent(:delete, "/api/sessions/#{session["id"]}?only=planned")
      travel_to Time.utc(2026, 11, 17, 12)

      get "/api/calendar", { from: "2026-11-09", to: "2026-11-22", today: "2026-11-17" }
      _(json["plan_changes"]).must_equal []
    end
  end

  describe "workout edits and remembered weights (#290)" do
    let(:squat) { exercise("goblet-squat") }

    def blocks
      get "/api/workouts/#{strength.id}"
      json["blocks"]
    end

    def edit_as_agent
      sent = blocks
      sent.first["rounds"] += 1
      as_agent(:put, "/api/workouts/#{strength.id}", blocks: sent)
      sent.first["rounds"]
    end

    it "shows an agent's edit on the workout and on Get ready until it is trained, and changes it back" do
      rounds = edit_as_agent

      get "/api/workouts/#{strength.id}", today: "2026-11-11"
      shown = json["changes"]
      _(shown.map { it.values_at("item_kind", "action", "changed_by", "workout_id", "undoable") }).must_equal [["workout", "changed", "llm", strength.id, true]]
      _(shown.first["summary"]).must_equal "#{rounds} rounds in block #{json["blocks"].first["label"]} (was #{rounds - 1})"
      get "/api/today", workout_id: strength.id, date: "2026-11-11"
      _(json["changes"].map { it["id"] }).must_equal [shown.first["id"]]

      post_json "/api/plan_changes/#{shown.first["id"]}/undo", today: "2026-11-11"

      _(last_response.status).must_equal 200, last_response.body
      _(json["change"].values_at("item_kind", "changed_by", "undoes_id")).must_equal ["workout", "manual", shown.first["id"]]
      _(blocks.first["rounds"]).must_equal rounds - 1
      get "/api/workouts/#{strength.id}"
      _(json["changes"]).must_equal []
    end

    it "shows a weight an agent set on Get ready, not the user's own, and takes it back" do
      put_json "/api/exercises/#{squat.id}/weight", value: 20
      get "/api/today", workout_id: strength.id, date: "2026-11-11"
      _(json["changes"]).must_equal []

      as_agent(:put, "/api/exercises/#{squat.id}/weight", value: 25)
      get "/api/today", workout_id: strength.id, date: "2026-11-11"
      set = json["changes"].first
      _(set.values_at("item_kind", "exercise_id", "title", "was", "now", "undoable"))
        .must_equal ["weight", squat.id, squat.name, { "value" => 20.0, "unit" => "lb" }, { "value" => 25.0, "unit" => "lb" }, true]

      post_json "/api/plan_changes/#{set["id"]}/undo", today: "2026-11-11"

      _(last_response.status).must_equal 200, last_response.body
      get "/api/exercises/#{squat.id}/weight"
      _(json.values_at("value", "unit")).must_equal [20.0, "lb"]
    end

    it "refuses an edit that changed again since, and an archive" do
      edit_as_agent
      edited = changes.first
      patch_json "/api/workouts/#{strength.id}", title: "Mine now"
      _(last_response.status).must_equal 200

      post_json "/api/plan_changes/#{edited["id"]}/undo"
      _(last_response.status).must_equal 409
      _(json["error"]["message"]).must_include "changed again"

      as_agent(:delete, "/api/workouts/#{strength.id}")
      archived = changes.find { it["action"] == "archived" }
      _(archived.values_at("item_kind", "workout_id", "undoable")).must_equal ["workout", strength.id, false]
    end
  end
end
