# frozen_string_literal: true

require "test_helper"

describe "coach API" do
  include RequestHelpers

  before { travel_to Time.utc(2026, 11, 4, 12) }
  after { travel_back }

  def note(kind = "note", body = "Easy week", **fields)
    CoachNote.create(kind:, body:, author_kind: "user", title: (body if kind == "concern"), **fields)
  end

  describe "goals" do
    it "adds goals in order, and lists active, proposed and past ones apart" do
      post_json "/api/goals", title: "Ski season with quiet knees", target_date: "2026-12-15", why: "Sore knees on descents"
      _(last_response.status).must_equal 201
      _(json.slice("title", "status", "position", "created_by"))
        .must_equal({ "title" => "Ski season with quiet knees", "status" => "active", "position" => 1, "created_by" => "user" })
      post_json "/api/goals", title: "Half marathon under 1:50"
      post_json "/api/goals", title: "Core twice a week", position: 1
      Goal.propose!(title: "Run a 10k", reason: "You run more than you lift")

      get "/api/goals"

      _(json["goals"].map { [it["title"], it["position"]] })
        .must_equal [["Core twice a week", 1], ["Ski season with quiet knees", 2], ["Half marathon under 1:50", 3]]
      _(json["proposals"].map { it["title"] }).must_equal ["Run a 10k"]
      _(json["past"]).must_be_empty
    end

    it "changes a goal, moves it and marks it achieved" do
      first = Goal.add!(title: "One")
      second = Goal.add!(title: "Two")

      patch_json "/api/goals/#{second.id}", position: 1, why: "Because"
      _(json.slice("position", "why")).must_equal({ "position" => 1, "why" => "Because" })
      _(Goal.active.in_order.select_map(:id)).must_equal [second.id, first.id]

      patch_json "/api/goals/#{second.id}", status: "achieved"
      _(json.slice("status", "position")).must_equal({ "status" => "achieved", "position" => nil })
      _(json["decided_at"]).wont_be_nil
      _(first.refresh.position).must_equal 1

      get "/api/goals"
      _(json["past"].map { it["id"] }).must_equal [second.id]
    end

    it "refuses a status only a proposal reaches, and a blank title" do
      goal = Goal.add!(title: "One")

      patch_json "/api/goals/#{goal.id}", status: "proposed"
      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal({ "status" => ["must be one of active, achieved, dropped"] })

      post_json "/api/goals", title: " "
      _(json["error"]["fields"]).must_equal({ "title" => ["can't be blank"] })
    end

    it "accepts a proposal in the place of the goal it replaces" do
      Goal.add!(title: "Core")
      old = Goal.add!(title: "Half marathon under 1:55")
      Goal.add!(title: "Ski")
      proposal = Goal.propose!(title: "Half marathon under 1:50", reason: "Your long runs got faster", replaces: old.id)

      post_json "/api/goals/#{proposal.id}/accept"

      _(json.slice("status", "position")).must_equal({ "status" => "active", "position" => 2 })
      _(old.refresh.status).must_equal "dropped"
      _(Goal.active.in_order.select_map(:title)).must_equal ["Core", "Half marathon under 1:50", "Ski"]

      post_json "/api/goals/#{proposal.id}/accept"
      _(last_response.status).must_equal 409
    end

    it "keeps a dismissed proposal, and won't take it again" do
      proposal = Goal.propose!(title: "Run a 10k", reason: "You like racing")

      post_json "/api/goals/#{proposal.id}/dismiss"

      _(json["status"]).must_equal "dismissed"
      _(_ { Goal.propose!(title: " run a 10K", reason: "Again") }.must_raise(Goal::NotProposed).message).must_include "dismissed"
    end

    it "doesn't let a proposal be edited, only accepted or dismissed" do
      proposal = Goal.propose!(title: "Run a 10k", reason: "You like racing")

      patch_json "/api/goals/#{proposal.id}", title: "Run a marathon"

      _(last_response.status).must_equal 409
      _(proposal.refresh.title).must_equal "Run a 10k"
    end

    it "deletes a dropped goal from the past ones" do
      first = Goal.add!(title: "One")
      dropped = Goal.add!(title: "Two").tap { it.revise!(status: "dropped") }

      delete "/api/goals/#{dropped.id}"

      _(last_response.status).must_equal 204
      get "/api/goals"
      _(json["past"]).must_equal []
      _(json["goals"].map { it["id"] }).must_equal [first.id]
    end

    it "closes up the active goals behind one deleted" do
      first, second, third = %w[One Two Three].map { Goal.add!(title: it) }

      delete "/api/goals/#{second.id}"

      _(Goal.active.in_order.select_map(%i[id position])).must_equal [[first.id, 1], [third.id, 2]]
    end

    it "won't take a dismissed title again, whatever its case, accents included" do
      Goal.propose!(title: "Été sans blessure", reason: "Knees").dismiss!

      _ { Goal.propose!(title: "ÉTÉ SANS BLESSURE", reason: "Again") }.must_raise Goal::NotProposed
    end

    it "deletes a goal, keeping a proposal that named it" do
      goal = Goal.add!(title: "One")
      proposal = Goal.propose!(title: "Two", reason: "Better", replaces: goal.id)

      delete "/api/goals/#{goal.id}"

      _(last_response.status).must_equal 204
      _(proposal.refresh.replaces_id).must_be_nil
    end
  end

  describe "notes" do
    it "writes a note as the user, and a human coach's under their name" do
      post_json "/api/coach/notes", kind: "concern", title: "Tight calf", body: "After run club", date: "2026-11-03"
      _(last_response.status).must_equal 201
      _(json.slice("kind", "author_kind", "author_name", "date", "resolved_at")).must_equal(
        { "kind" => "concern", "author_kind" => "user", "author_name" => nil, "date" => "2026-11-03", "resolved_at" => nil }
      )

      post_json "/api/coach/notes", kind: "note", body: "Good pacing", author_kind: "human", author_name: "Mara"
      _(json.slice("author_kind", "author_name")).must_equal({ "author_kind" => "human", "author_name" => "Mara" })

      post_json "/api/coach/notes", kind: "note", body: "Who?", author_kind: "human"
      _(json["error"]["fields"]).must_equal({ "author_name" => ["can't be blank"] })
    end

    it "needs a title for a concern" do
      post_json "/api/coach/notes", kind: "concern", body: "Knee"

      _(json["error"]["fields"]).must_equal({ "title" => ["can't be blank"] })
    end

    it "keeps an agent's note as it wrote it, but lets it be resolved or deleted" do
      concern = CoachNote.create(kind: "concern", title: "Run club", body: "Missed twice", author_kind: "llm")

      patch_json "/api/coach/notes/#{concern.id}", body: "Something else"
      _(last_response.status).must_equal 403
      patch_json "/api/coach/notes/#{concern.id}", author_kind: "user"
      _(last_response.status).must_equal 403
      _(concern.refresh.values.values_at(:body, :author_kind)).must_equal ["Missed twice", "llm"]

      patch_json "/api/coach/notes/#{concern.id}", resolved: true
      _(json["resolved_at"]).wont_be_nil
      delete "/api/coach/notes/#{concern.id}"
      _(last_response.status).must_equal 204
    end

    it "replies to an agent's note, under it everywhere it shows, and deletes the reply with it" do
      session = Session.plan!(workout: Workout.first, date: Date.new(2026, 11, 5))
      asked = CoachNote.create(kind: "note", body: "How did the step-ups feel?", author_kind: "llm", session_id: session.id)

      post_json "/api/coach/notes", kind: "note", body: "Fine on the low step.", reply_to_id: asked.id
      _(last_response.status).must_equal 201
      reply = json
      _(reply.slice("reply_to_id", "author_kind", "date", "session_id", "replies")).must_equal(
        { "reply_to_id" => asked.id, "author_kind" => "user", "date" => nil, "session_id" => nil, "replies" => [] }
      )

      get "/api/coach"
      _(json["notes"].map { it["id"] }).must_equal [asked.id]
      _(json["notes"].first["replies"].map { it["body"] }).must_equal ["Fine on the low step."]
      _(json["week"]["notes"].map { it["id"] }).must_equal [asked.id]
      get "/api/coach/notes"
      _(json["notes"].map { it["id"] }).must_equal [asked.id]
      get "/api/calendar?from=2026-11-02&to=2026-11-08"
      _(json["notes"].map { it["id"] }).must_equal [asked.id]
      _(json["notes"].first["replies"].map { it["id"] }).must_equal [reply["id"]]

      patch_json "/api/coach/notes/#{reply["id"]}", body: "Fine on the low step, sore on the high one."
      _(json["body"]).must_equal "Fine on the low step, sore on the high one."
      delete "/api/coach/notes/#{asked.id}"
      _(CoachNote.with_pk(reply["id"])).must_be_nil
    end

    it "keeps a reply to one level, on a note that isn't the user's, as a plain note of theirs" do
      own = note("note", "Mine")
      coach = CoachNote.create(kind: "note", body: "From Mara", author_kind: "human", author_name: "Mara")
      reply = CoachNote.create(kind: "note", body: "Thanks", author_kind: "user", reply_to_id: coach.id)
      other = Current.set(user: create_user("other")) { CoachNote.create(kind: "note", body: "Theirs", author_kind: "llm") }

      [
        [{ reply_to_id: own.id }, "reply_to_id", "is your own note; edit it instead"],
        [{ reply_to_id: reply.id }, "reply_to_id", "is a reply; answer the note it replies to"],
        [{ reply_to_id: other.id }, "reply_to_id", "is not found"],
        [{ reply_to_id: coach.id, kind: "concern", title: "Hm" }, "kind", "must be note for a reply"],
        [{ reply_to_id: coach.id, author_kind: "human", author_name: "Jo" }, "author_kind", "must be user for a reply"],
        [{ reply_to_id: coach.id, date: "2026-11-03" }, "date", "is the note's, not a reply's"]
      ].each do |fields, field, message|
        post_json "/api/coach/notes", { kind: "note", body: "Hi", **fields }
        _(last_response.status).must_equal 422
        _(json["error"]["fields"][field]).must_include message
      end

      patch_json "/api/coach/notes/#{coach.id}", author_kind: "user"
      _(last_response.status).must_equal 422
      _(json["error"]["fields"]["author_kind"]).must_include "can't be user: you replied to this note"

      patch_json "/api/coach/notes/#{reply.id}", reply_to_id: nil
      _(last_response.status).must_equal 422
      _(json["error"]["fields"]["reply_to_id"]).must_include "can't be changed"
    end

    it "leaves writing as the agent to MCP" do
      post_json "/api/coach/notes", kind: "note", body: "I am a robot", author_kind: "llm"

      _(last_response.status).must_equal 400
      _(CoachNote.count).must_equal 0
    end

    it "ties a note to an activity or session of the user's only" do
      activity, = Activity.log!({ date: "2026-11-03", sport: "run", title: "Run club" })
      session = session_on(Date.new(2026, 11, 2))

      post_json "/api/coach/notes", kind: "note", body: "Felt easy", activity_id: activity.id
      _(json["about"]).must_equal({ "type" => "activity", "id" => activity.id, "date" => "2026-11-03", "label" => "Run club" })
      post_json "/api/coach/notes", kind: "note", body: "Heavy legs", session_id: session.id
      _(json["about"].slice("type", "label")).must_equal({ "type" => "session", "label" => session.workout.title })

      someone = create_user("someone")
      theirs = Current.set(user: someone) { Activity.log!({ date: "2026-11-03", sport: "ride" }).first }
      post_json "/api/coach/notes", kind: "note", body: "Sneaky", activity_id: theirs.id
      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal({ "activity_id" => ["is not found"] })
    end

    it "keeps a note when the activity it was about is deleted" do
      activity, = Activity.log!({ date: "2026-11-03", sport: "run" })
      kept = note(activity_id: activity.id)

      delete "/api/activities/#{activity.id}"

      _(last_response.status).must_equal 204
      _(kept.refresh.activity_id).must_be_nil
    end

    it "resolves a concern and opens it again" do
      concern = note("concern", "Left knee")

      patch_json "/api/coach/notes/#{concern.id}", resolved: true, resolution: "Gone after a week"
      _(json["resolved_at"]).wont_be_nil
      _(json["resolution"]).must_equal "Gone after a week"

      patch_json "/api/coach/notes/#{concern.id}", resolved: false
      _(json.slice("resolved_at", "resolution")).must_equal({ "resolved_at" => nil, "resolution" => nil })

      patch_json "/api/coach/notes/#{note.id}", resolved: true
      _(last_response.status).must_equal 409
    end

    it "keeps when a concern was resolved, and rewrites only how" do
      concern = note("concern", "Left knee")
      patch_json "/api/coach/notes/#{concern.id}", resolved: true, resolution: "Easy week"
      resolved_at = json["resolved_at"]

      travel_to Time.utc(2026, 11, 6, 12)
      patch_json "/api/coach/notes/#{concern.id}", resolved: true
      _(json.slice("resolved_at", "resolution")).must_equal({ "resolved_at" => resolved_at, "resolution" => "Easy week" })
      patch_json "/api/coach/notes/#{concern.id}", resolution: "New shoes"
      _(json["resolution"]).must_equal "New shoes"

      patch_json "/api/coach/notes/#{concern.id}", resolved: nil
      _(last_response.status).must_equal 400
      patch_json "/api/coach/notes/#{note("concern", "Calf").id}", resolution: "Gone"
      _(last_response.status).must_equal 400
    end

    it "edits and deletes a note" do
      written = note

      patch_json "/api/coach/notes/#{written.id}", body: "Hard week", title: "Week 3"
      _(json.slice("body", "title")).must_equal({ "body" => "Hard week", "title" => "Week 3" })

      delete "/api/coach/notes/#{written.id}"
      _(last_response.status).must_equal 204
      _(CoachNote.count).must_equal 0
    end

    it "pages through the journal, newest first, by kind" do
      notes = Array.new(5) { note("note", "Note #{it}") }
      note("status", "Base block")

      get "/api/coach/notes?kind=note&limit=2"
      _(json["notes"].map { it["id"] }).must_equal notes.last(2).reverse.map(&:id)
      _(json["next_before"]).must_equal notes[3].id

      get "/api/coach/notes?kind=note&limit=2&before=#{notes[1].id}"
      _(json["notes"].map { it["id"] }).must_equal [notes[0].id]
      _(json["next_before"]).must_be_nil

      get "/api/coach/notes"
      _(json["notes"].size).must_equal 6

      get "/api/coach/notes?journal=true&limit=3"
      _(json["notes"].map { it["id"] }).must_equal notes.last(3).reverse.map(&:id)

      get "/api/coach/notes?kind=mood"
      _(last_response.status).must_equal 400
      get "/api/coach/notes?kind=note,mood"
      _(last_response.status).must_equal 400
      get "/api/coach/notes?limit=0"
      _(last_response.status).must_equal 400
    end

    it "keeps several kinds, and the notes of some authors" do
      mine = note("note", "Knee fine")
      physio = note("note", "Ease the hills", author_kind: "human", author_name: "Sam")
      agent = CoachNote.create(kind: "note", body: "Copied 9 runs", author_kind: "llm")
      concern = note("concern", "Left knee")
      note("status", "Base block")

      get "/api/coach/notes?kind=note,concern"
      _(json["notes"].map { it["id"] }).must_equal [concern.id, agent.id, physio.id, mine.id]
      get "/api/coach/notes?kind=note&author=human,llm"
      _(json["notes"].map { it["id"] }).must_equal [agent.id, physio.id]
      get "/api/coach/notes?author=user,robot"
      _(last_response.status).must_equal 400
      _(json["error"]["fields"].keys).must_equal ["author"]
    end
  end

  describe "tidy up" do
    def agent(kind, body, **fields) = CoachNote.create(kind:, body:, author_kind: "llm", title: (body if kind == "concern"), **fields)

    it "counts and deletes the agent's notes written before a day, but what still says where things stand" do
      travel_to Time.utc(2026, 10, 20, 12)
      old = agent("note", "Copied 9 runs")
      answered = agent("note", "How are the knees?")
      reply = CoachNote.create(kind: "note", body: "Fine", author_kind: "user", reply_to_id: answered.id)
      old_status = agent("status", "Base block")
      resolved = agent("concern", "Shin").tap(&:resolve!)
      open_concern = agent("concern", "Left knee")
      current_focus = agent("focus", "Hills")
      yours = note("note", "Knee fine")
      travel_to Time.utc(2026, 11, 4, 12)
      current_status = agent("status", "Build block")
      recent = agent("note", "Session B today")

      get "/api/coach/tidy?before=2026-11-01"
      _(json).must_equal({ "count" => 3 })

      post_json "/api/coach/tidy", before: "2026-11-01"
      _(json).must_equal({ "deleted" => 3 })
      _(CoachNote.select_map(:id).sort)
        .must_equal [answered, reply, open_concern, current_focus, yours, current_status, recent].map(&:id).sort
      _([old, old_status, resolved].map { CoachNote.where(id: it.id).count }).must_equal [0, 0, 0]

      get "/api/coach/tidy"
      _(last_response.status).must_equal 400
      post_json "/api/coach/tidy", before: "soon"
      _(last_response.status).must_equal 400
      post_json "/api/coach/tidy", before: "2026-11-06"
      _(last_response.status).must_equal 400
    end
  end

  describe "GET /api/coach" do
    it "gives the board: goals, the newest status and focus, open concerns, notes and this week" do
      goal = Goal.add!(title: "Ski season")
      proposal = Goal.propose!(title: "Core twice a week", reason: "Back stiffness")
      old_status = note("status", "Week 2")
      status = note("status", "Week 3 of 6")
      focus = CoachNote.create(kind: "focus", body: "Single-leg strength", author_kind: "llm", author_name: "Trainer agent")
      open = note("concern", "Left knee")
      resolved = note("concern", "Old one").tap { it.resolve!("fine") }
      journal = note("note", "Knee fine", date: Date.new(2026, 11, 2))
      run, = Activity.log!({ date: "2026-11-02", sport: "run" })
      Activity.log!({ date: "2026-10-31", sport: "run" })
      session = session_on(Date.new(2026, 11, 6), "planned")
      long_run = Routine.plan!({ sport: "run", weekdays: [7], title: "Long run" }, today: Date.new(2026, 11, 4))

      get "/api/coach?today=2026-11-04"

      _(json["today"]).must_equal "2026-11-04"
      _(json["goals"].map { it["id"] }).must_equal [goal.id]
      _(json["proposals"].map { it["id"] }).must_equal [proposal.id]
      _(json["status"]["id"]).must_equal status.id
      _(json["status"]["replaces"]["id"]).must_equal old_status.id
      _(json["focus"].slice("id", "author_kind", "author_name", "replaces"))
        .must_equal({ "id" => focus.id, "author_kind" => "llm", "author_name" => "Trainer agent", "replaces" => nil })
      _(json["concerns"].map { it["id"] }).must_equal [open.id]
      _(json["notes"].map { it["id"] }).must_equal [journal.id, resolved.id, old_status.id]
      _(json["week"].slice("from", "to")).must_equal({ "from" => "2026-11-02", "to" => "2026-11-08" })
      _(json["week"]["activities"].map { it["id"] }).must_equal [run.id]
      _(json["week"]["sessions"].map { it["id"] }).must_equal [session.id]
      _(json["week"]["notes"].map { it["id"] }).must_equal [journal.id]
      _(json["week"]["routines"].map { it["id"] }).must_equal [long_run.id]
      _(json["week"]["routine_days"].map { it.values_at("routine_id", "on", "state") })
        .must_equal [[long_run.id, "2026-11-08", "tentative"]]
    end

    it "counts the goals achieved or dropped, not the dismissed proposals" do
      Goal.add!(title: "Active")
      Goal.add!(title: "Done").update(status: "achieved")
      Goal.add!(title: "Gone").update(status: "dropped")
      Goal.propose!(title: "Run a 10k", reason: "Racing").dismiss!

      get "/api/coach"

      _(json["past_goals"]).must_equal 2
    end

    it "says where the journal's next page starts" do
      notes = Array.new(11) { note("note", "Note #{it}") }

      get "/api/coach"

      _(json["notes"].size).must_equal 10
      _(json["notes_before"]).must_equal notes[1].id
      get "/api/coach/notes?journal=true&before=#{json["notes_before"]}"
      _(json["notes"].map { it["id"] }).must_equal [notes[0].id]
    end

    it "brings the status before back when the current one is deleted" do
      older = note("status", "Week 2")
      newer = note("status", "Week 3")

      delete "/api/coach/notes/#{newer.id}"
      get "/api/coach"

      _(json["status"]["id"]).must_equal older.id
    end

    it "is empty for a new account" do
      sign_out!
      sign_in(create_user("new", bare: true))

      get "/api/coach"

      _(json.slice("goals", "proposals", "past_goals", "status", "focus", "concerns", "notes")).must_equal(
        { "goals" => [], "proposals" => [], "past_goals" => 0, "status" => nil, "focus" => nil, "concerns" => [], "notes" => [] }
      )
    end
  end

  it "puts dated notes on the calendar" do
    dated = note("note", "Long run felt good", date: Date.new(2026, 11, 1))
    note("note", "Undated")

    get "/api/calendar?from=2026-10-26&to=2026-11-08"

    _(json["notes"].map { it["id"] }).must_equal [dated.id]
  end

  it "puts a note about a session or activity on its day, wherever it moved" do
    session = session_on(Date.new(2026, 11, 2))
    activity, = Activity.log!({ date: "2026-11-03", sport: "run" })
    about_session = note("note", "Heavy legs", session_id: session.id, date: Date.new(2026, 10, 20))
    about_activity = note("note", "Felt easy", activity_id: activity.id)
    session.update_columns(date: Date.new(2026, 11, 12))

    get "/api/calendar?from=2026-11-09&to=2026-11-15"
    _(json["notes"].map { it["id"] }).must_equal [about_session.id]
    get "/api/calendar?from=2026-10-26&to=2026-11-08"
    _(json["notes"].map { it["id"] }).must_equal [about_activity.id]
    get "/api/calendar?from=2026-10-19&to=2026-10-25"
    _(json["notes"]).must_equal []
  end

  it "keeps one user's goals and notes from another" do
    someone = create_user("someone")
    goal, written = Current.set(user: someone) { [Goal.add!(title: "Theirs"), note] }

    get "/api/goals"
    _(json["goals"]).must_be_empty
    get "/api/coach/notes"
    _(json["notes"]).must_be_empty

    [[:patch, "/api/goals/#{goal.id}"], [:delete, "/api/goals/#{goal.id}"], [:post, "/api/goals/#{goal.id}/accept"],
     [:patch, "/api/coach/notes/#{written.id}"], [:delete, "/api/coach/notes/#{written.id}"]].each do |verb, path|
      verb == :delete ? delete(path) : send(:"#{verb}_json", path, { title: "Mine" })
      _(last_response.status).must_equal 404, path
    end
  end
end
