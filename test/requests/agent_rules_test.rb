# frozen_string_literal: true

require "test_helper"

# What an agent may do is the models' to say (Record.user_only!,
# Record::AgentSigned), so an API token with REST access is held to the
# rules the MCP tools keep: it writes as an agent, proposes goals rather than
# setting them, and leaves the user's history and words alone.
describe "an agent on the REST API" do
  include RequestHelpers

  # A Wednesday.
  before { travel_to Time.utc(2026, 11, 11, 12) }
  after { travel_back }

  let(:token) { ApiToken.issue!(user, "Coach agent", scope: "api").last }

  def as_agent(method, path, body = nil)
    @signed_out = true
    @fetch_site = nil
    header "Authorization", "Bearer #{token}"
    body.nil? ? send(method, path) : send(:"#{method}_json", path, body)
    last_response
  end

  let(:own_workout) do
    Workout.create_with!({ kind: "workout", title: "Mine",
                           blocks: [{ label: "A", steps: [{ exercise_id: exercise("plank").id, duration_seconds: 30 }] }] })
  end

  def proposal
    Current.set(agent_name: "Coach agent") { Goal.propose!(title: "Run a half marathon", reason: "You asked for a race") }
  end

  describe "goals" do
    it "can't accept or dismiss what it proposed" do
      goal = proposal

      _(as_agent(:post, "/api/goals/#{goal.id}/accept", {}).status).must_equal 403
      _(json["error"]).must_equal({ "code" => "forbidden", "message" => "only the user accepts a proposed goal, in the app" })
      _(as_agent(:post, "/api/goals/#{goal.id}/dismiss", {}).status).must_equal 403
      _(goal.refresh.status).must_equal "proposed"
    end

    it "can't add, change or delete one" do
      goal = Goal.add!(title: "Strong knees for ski season")

      _(as_agent(:post, "/api/goals", { title: "Mine now" }).status).must_equal 403
      _(as_agent(:patch, "/api/goals/#{goal.id}", { title: "Weak knees" }).status).must_equal 403
      _(as_agent(:delete, "/api/goals/#{goal.id}").status).must_equal 403
      _(Goal.select_map(:title)).must_equal ["Strong knees for ski season"]
    end

    it "is held to proposals in the model too" do
      Current.set(agent_name: "Coach agent") do
        _ { Goal.create(title: "Sneaked in", status: "active", created_by: "user", position: 1) }.must_raise Sequel::ValidationFailed
        _ { Goal.add!(title: "Sneaked in") }.must_raise Record::UserOnly
      end
      _([proposal.status, proposal.created_by, proposal.agent_name]).must_equal ["proposed", "llm", "Coach agent"]
    end
  end

  describe "sessions" do
    it "plans as itself, whatever the request says" do
      as_agent(:post, "/api/sessions", { workout_id: workout("cycle-1-workout-1").id, date: "2026-11-12", created_by: "manual" })

      _(last_response.status).must_equal 201
      _(json.values_at("created_by", "agent_name")).must_equal ["llm", "Coach agent"]
    end

    it "takes a planned session off, but can't erase one started, skipped or done" do
      planned = session_on("2026-11-12", "planned")
      %w[done skipped in_progress].each do |status|
        settled = session_on("2026-11-10", status)
        _(as_agent(:delete, "/api/sessions/#{settled.id}").status).must_equal 403
        _(json["error"]["message"]).must_include "only the user erases one started, skipped or done"
        _(Session.with_pk(settled.id)).wont_be_nil
      end

      _(as_agent(:delete, "/api/sessions/#{planned.id}").status).must_equal 204
      _(Session.with_pk(planned.id)).must_be_nil
    end

    it "leaves a session's history as it is, and skipping to the user" do
      skipped = session_on("2026-11-10", "skipped")
      _(as_agent(:patch, "/api/sessions/#{skipped.id}", { status: "planned", date: "2026-11-12" }).status).must_equal 403
      _(as_agent(:delete, "/api/sessions/#{skipped.id}").status).must_equal 403
      _(skipped.refresh.status).must_equal "skipped"

      planned = session_on("2026-11-12", "planned")
      _(as_agent(:patch, "/api/sessions/#{planned.id}", { status: "skipped" }).status).must_equal 403

      ended = session_on("2026-11-10", "done")
      Completion.create(session_id: ended.id, finished_at: Time.now, ended_early: true, rpe: 7)
      _(as_agent(:patch, "/api/sessions/#{ended.id}", { status: "in_progress" }).status).must_equal 403
      _(ended.refresh.completion.rpe).must_equal 7
    end

    it "can't add a session already skipped" do
      as_agent(:post, "/api/sessions", { workout_id: workout("cycle-1-workout-1").id, date: "2026-11-11", status: "skipped" })

      _(last_response.status).must_equal 403
      _(json["error"]["message"]).must_equal "only the user skips a session"
      _(Session.count).must_equal 0
    end

    it "starts and finishes a planned session, as a script logging one would" do
      planned = session_on("2026-11-11", "planned")
      step = step_for("cycle-1-workout-1", "goblet-squat")

      _(as_agent(:post, "/api/sessions/#{planned.id}/sets", { step_id: step.id, set_number: 1, reps: 8 }).status).must_equal 201
      _(as_agent(:post, "/api/sessions/#{planned.id}/complete", { rpe: 6 }).status).must_equal 200
      _(planned.refresh.status).must_equal "done"
    end

    it "leaves the user free to erase their history" do
      done = session_on("2026-11-10", "done")
      delete "/api/sessions/#{done.id}"

      _(last_response.status).must_equal 204
    end
  end

  describe "the coach board" do
    it "writes notes as itself, signed with the token's name" do
      as_agent(:post, "/api/coach/notes", { kind: "note", body: "Easy week ahead", author_kind: "human", author_name: "Your coach" })

      _(last_response.status).must_equal 201
      _(json.values_at("author_kind", "author_name")).must_equal ["llm", "Coach agent"]
    end

    it "changes its own notes, still signed as its own" do
      own = Current.set(agent_name: "Coach agent") { CoachNote.create(kind: "note", body: "Easy week", author_kind: "llm") }

      as_agent(:patch, "/api/coach/notes/#{own.id}", { body: "Easy week, then a long run" })
      _(last_response.status).must_equal 200
      _(json.values_at("body", "author_kind", "author_name")).must_equal ["Easy week, then a long run", "llm", "Coach agent"]

      _(as_agent(:patch, "/api/coach/notes/#{own.id}", { author_kind: "human", author_name: "Your coach" }).status).must_equal 403
      _(own.refresh.values.values_at(:author_kind, :author_name)).must_equal ["llm", "Coach agent"]
    end

    it "leaves a note the user replied to, and stops at its daily limit" do
      own = Current.set(agent_name: "Coach agent") { CoachNote.create(kind: "note", body: "How are the knees?", author_kind: "llm") }
      CoachNote.create(kind: "note", body: "Fine", author_kind: "user", reply_to_id: own.id)
      _(as_agent(:delete, "/api/coach/notes/#{own.id}").status).must_equal 403
      _(CoachNote.count).must_equal 2

      (CoachNote::AGENT_DAILY_LIMIT - 1).times { |i| as_agent(:post, "/api/coach/notes", { kind: "note", body: "Note #{i}" }) }
      _(last_response.status).must_equal 201
      _(as_agent(:post, "/api/coach/notes", { kind: "note", body: "One too many" }).status).must_equal 409
      _(CoachNote.by_agent.count).must_equal CoachNote::AGENT_DAILY_LIMIT
    end

    it "leaves the user's notes as they wrote them" do
      mine = CoachNote.create(kind: "concern", title: "Left knee", body: "Twinges on stairs", author_kind: "user")

      _(as_agent(:patch, "/api/coach/notes/#{mine.id}", { body: "All better" }).status).must_equal 403
      _(as_agent(:patch, "/api/coach/notes/#{mine.id}", { resolved: true }).status).must_equal 403
      _(as_agent(:delete, "/api/coach/notes/#{mine.id}").status).must_equal 403
      _([mine.refresh.body, mine.resolved_at]).must_equal ["Twinges on stairs", nil]
    end
  end

  it "leaves what the user logged as it is: activities, sets and finishes" do
    mine = Activity.log!({ date: "2026-11-10", sport: "run", moving_seconds: 1800 }).first
    _(as_agent(:patch, "/api/activities/#{mine.id}", { title: "Not mine" }).status).must_equal 403
    _(as_agent(:delete, "/api/activities/#{mine.id}").status).must_equal 403
    _(mine.refresh.title).must_be_nil

    done = session_on("2026-11-10", "done").tap { Completion.create(session_id: it.id, finished_at: Time.now, rpe: 7, note: "Heavy legs") }
    _(as_agent(:patch, "/api/sessions/#{done.id}/completion", { rpe: 3 }).status).must_equal 403
    _(as_agent(:post, "/api/sessions/#{done.id}/complete", { note: "Easy" }).status).must_equal 403
    step = step_for("cycle-1-workout-1", "goblet-squat")
    _(as_agent(:post, "/api/sessions/#{done.id}/sets", { step_id: step.id, set_number: 1, reps: 1 }).status).must_equal 403
    _(done.refresh.completion.values.values_at(:rpe, :note)).must_equal [7, "Heavy legs"]

    as_agent(:post, "/api/activities", { date: "2026-11-10", sport: "ride", moving_seconds: 3600 })
    _(as_agent(:patch, "/api/activities/#{json["id"]}", { title: "Its own" }).status).must_equal 200
  end

  it "resends a list over one the user logged, leaving theirs as it is and logging the rest" do
    synced = { date: "2026-11-10", sport: "run", source: "garmin", external_id: "17" }
    mine = Activity.log!(synced.merge(title: "Morning run")).first

    as_agent(:post, "/api/activities",
             { activities: [synced.merge(title: "Renamed"), { date: "2026-11-10", sport: "ride", source: "garmin", external_id: "18" }] })

    _(last_response.status).must_equal 200, last_response.body
    _(json["activities"].map { it["external_id"] }).must_equal %w[17 18]
    _(mine.refresh.values.values_at(:title, :created_by)).must_equal ["Morning run", "manual"]
    _(Activity.where(external_id: "18").get(:created_by)).must_equal "llm"
  end

  it "archives a workout the user's routine runs, which ends the routine" do
    Routine.plan!({ workout_id: own_workout.id, weekdays: [6] })
    as_agent(:delete, "/api/workouts/#{own_workout.id}")

    _(last_response.status).must_be :<, 300, last_response.body
    _(Routine.count).must_equal 0
  end

  it "logs activities and plans routines as itself" do
    as_agent(:post, "/api/activities", { date: "2026-11-10", sport: "run", moving_seconds: 1800 })
    _(last_response.status).must_equal 201
    _(json.values_at("created_by", "agent_name")).must_equal ["llm", "Coach agent"]

    as_agent(:post, "/api/routines", { sport: "run", weekdays: [6] })
    _(last_response.status).must_equal 201
    _(json.values_at("created_by", "agent_name")).must_equal ["llm", "Coach agent"]
  end

  describe "routines" do
    let(:theirs) { Routine.plan!({ sport: "run", weekdays: [6] }) }

    it "changes and ends only the routines it planned" do
      _(as_agent(:patch, "/api/routines/#{theirs.id}", { weekdays: [7] }).status).must_equal 403
      _(as_agent(:delete, "/api/routines/#{theirs.id}").status).must_equal 403
      _(theirs.refresh.weekdays).must_equal [6]

      as_agent(:post, "/api/routines", { sport: "ride", weekdays: [3] })
      own = json["id"]
      _(as_agent(:patch, "/api/routines/#{own}", { weekdays: [4] }).status).must_equal 200
    end

    it "leaves confirming, skipping and moving a day to the user" do
      _(as_agent(:put, "/api/routines/#{theirs.id}/days/2026-11-14", { status: "confirmed" }).status).must_equal 403
      _(as_agent(:put, "/api/routines/#{theirs.id}/days/2026-11-14", { status: "skipped" }).status).must_equal 403
      _(as_agent(:post, "/api/routines", { sport: "run", weekdays: [], starts_on: "2026-11-12", confirmed: true }).status).must_equal 403
      _(Routine.count).must_equal 1
    end
  end

  it "can't take a change back or mark its news seen" do
    as_agent(:post, "/api/sessions", { workout_id: workout("cycle-1-workout-1").id, date: "2026-11-12" })
    change = PlanChange.first!

    _(as_agent(:post, "/api/plan_changes/#{change.id}/undo", {}).status).must_equal 403
    _(as_agent(:post, "/api/coach/seen", {}).status).must_equal 403
  end
end
