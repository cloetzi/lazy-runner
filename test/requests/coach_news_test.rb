# frozen_string_literal: true

require "test_helper"

describe "since you last looked" do
  include RequestHelpers

  # A Wednesday.
  before { travel_to Time.utc(2026, 11, 11, 12) }
  after { travel_back }

  let(:strength) { workout("cycle-1-workout-1") }
  let(:token) { ApiToken.issue!(user, "Coach agent", scope: "api").last }

  # A request as the agent, with its API token.
  def as_agent(method, path, body = {})
    send(method, path, JSON.generate(body), RequestHelpers::JSON_ENV.merge("HTTP_AUTHORIZATION" => "Bearer #{token}"))
    _(last_response.status).must_be :<, 300, last_response.body
    json
  end

  def news
    get "/api/coach/news", { today: "2026-11-11" }
    _(last_response.status).must_equal 200, last_response.body
    json
  end

  def unseen
    get "/api/me"
    _(last_response.status).must_equal 200
    json["coach_unseen"]
  end

  def agent_did_things
    mine = post_json("/api/sessions", { workout_id: strength.id, date: "2026-11-13" }).then { json }
    as_agent(:patch, "/api/sessions/#{mine["id"]}", date: "2026-11-14")
    as_agent(:post, "/api/sessions", workout_id: strength.id, date: "2026-11-16")
    CoachNote.create(kind: "note", body: "Planned next week", author_kind: "llm", author_name: "Coach agent")
    CoachNote.create(kind: "note", body: "Mine", author_kind: "user")
    Goal.propose!(title: "Run a 10k", reason: "You run more than you lift")
    Activity.log!({ date: "2026-11-09", sport: "run", source: "Garmin", external_id: "1" }, created_by: "llm")
    Activity.log!({ date: "2026-11-10", sport: "run", source: "Garmin", external_id: "2" }, created_by: "llm")
    Activity.log!({ date: "2026-11-10", sport: "ride" })
    mine
  end

  it "lists what agents did, not what the user did, and counts it for the Coach tab" do
    mine = agent_did_things

    shown = news
    _(shown["changes"].map { it.values_at("action", "session_id") })
      .must_equal [["planned", shown["changes"][0]["session_id"]], ["moved", mine["id"]]]
    _(shown["changes"][1].values_at("agent_name", "undoable")).must_equal ["Coach agent", true]
    _(shown["notes"].map { it["body"] }).must_equal ["Planned next week"]
    _(shown["goals"].map { it["title"] }).must_equal ["Run a 10k"]
    _(shown["activities"]).must_equal [{ "agent_name" => nil, "count" => 2, "from" => "2026-11-09", "to" => "2026-11-10",
                                         "sources" => ["Garmin"], "created_at" => shown["activities"][0]["created_at"] }]
    _(Time.iso8601(shown["since"])).must_equal Time.utc(2026, 10, 28).in_time_zone.to_time
    _(shown["latest"]).wont_be_nil
    _(unseen).must_equal 6
  end

  it "leaves out a change the user took back" do
    session = post_json("/api/sessions", { workout_id: strength.id, date: "2026-11-13" }).then { json }
    moved = as_agent(:patch, "/api/sessions/#{session["id"]}", date: "2026-11-14")
    change = news["changes"].first
    post_json "/api/plan_changes/#{change["id"]}/undo", today: "2026-11-11"
    _(last_response.status).must_equal 200

    _(moved["id"]).must_equal session["id"]
    _(news["changes"]).must_equal []
    _(unseen).must_equal 0
  end

  it "marks it seen up to what was read, so what came after stays news" do
    agent_did_things
    latest = news["latest"]
    travel_to Time.utc(2026, 11, 11, 13)
    CoachNote.create(kind: "note", body: "Written while you read", author_kind: "llm")

    post_json "/api/coach/seen", until: latest
    _(last_response.status).must_equal 200
    _(json["count"]).must_equal 1
    _(news["notes"].map { it["body"] }).must_equal ["Written while you read"]

    post_json "/api/coach/seen", until: "2026-11-01T00:00:00Z"
    _(news["notes"].size).must_equal 1

    post_json "/api/coach/seen", {}
    _(json["count"]).must_equal 0
    _(unseen).must_equal 0
    _(news.values_at("changes", "notes", "goals", "latest")).must_equal [[], [], [], nil]
    _(news["activities"]).must_equal []
  end

  it "marks the newest thing seen, made within a second" do
    note = CoachNote.create(kind: "note", body: "Just now", author_kind: "llm")
    note.update_columns(created_at: Time.utc(2026, 11, 11, 11, 59, Rational(239, 4)))
    latest = news["latest"]
    _(Time.iso8601(latest).subsec).must_equal Rational(3, 4)

    post_json "/api/coach/seen", until: latest
    _(json["count"]).must_equal 0
  end

  it "never marks it seen later than now, refuses a bad time, and only the user marks it" do
    post_json "/api/coach/seen", until: "2027-01-01T00:00:00Z"
    _(Time.iso8601(json["coach_seen_at"])).must_equal Time.now

    post_json "/api/coach/seen", until: "yesterday"
    _(last_response.status).must_equal 400

    send(:post, "/api/coach/seen", "{}", RequestHelpers::JSON_ENV.merge("HTTP_AUTHORIZATION" => "Bearer #{token}"))
    _(last_response.status).must_equal 403
  end

  it "keeps one user's news from another" do
    someone = create_user("someone")
    Current.set(user: someone) { CoachNote.create(kind: "note", body: "Theirs", author_kind: "llm") }

    _(news["notes"]).must_equal []
    _(unseen).must_equal 0
  end
end
