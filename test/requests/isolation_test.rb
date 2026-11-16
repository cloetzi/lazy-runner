# frozen_string_literal: true

require "test_helper"

# Every user sees and changes only their own records: another user's
# id is a 404 wherever an id is taken, and lists leave their records out.
describe "one user's data, kept from another" do
  include RequestHelpers

  let(:today) { Time.zone.today }

  # Someone else, with a bit of everything: a workout of their own, a day
  # with two sessions (one done, with sets and a finish), a
  # remembered weight, their settings and inventory.
  before do
    @someone = create_user("someone")
    Current.set(user: @someone) do
      @their_workout = workout("cycle-1-workout-1").duplicate!(title: "Theirs")
      @their_warmup = workout("cycle-1-warmup")
      @their_done = session_on(today, "planned")
      log_all(@their_done, "goblet-squat", weight_value: 40, weight_unit: "lb")
      finish(@their_done, "too_easy")
      @their_planned = Session.plan!(workout: @their_workout, date: today, client_ref: "same-ref")
      ExerciseWeight.remember!(exercise("reverse-fly"), 20)
      Setting.current.update(unit: "kg")
      inventory("dumbbell").update(weights: [5])
    end
    @their_step = @their_workout.blocks.first.steps.first
  end

  def theirs = [@their_workout, @their_done, @their_planned].map(&:id)

  it "leaves their records out of every list" do
    get "/api/workouts"
    ids = json.flat_map { it["workouts"] }.map { it["id"] }
    _(ids & Workout.of(@someone.id).select_map(:id)).must_be_empty
    _(ids).must_include workout("cycle-1-workout-1").id

    get "/api/programs"
    _(json.map { it["id"] }).must_equal Program.order(:id).select_map(:id)

    get "/api/sessions?from=#{today - 7}&to=#{today + 7}"
    _(json).must_be_empty

    get "/api/history"
    _(json["sessions"]).must_be_empty
    get "/api/history/exercises"
    _(json).must_be_empty
    get "/api/exercises/#{exercise("goblet-squat").id}/history"
    _(json["sessions"]).must_be_empty

    get "/api/today"
    _(json["day"]).must_be_empty
    _(json["session"]).must_be_nil
  end

  it "keeps their weights, settings and inventory to them" do
    get "/api/exercises/#{exercise("reverse-fly").id}/weight"
    _(json["value"]).must_be_nil

    get "/api/settings"
    _(json["unit"]).must_equal "lb"

    get "/api/equipment"
    _(json.find { it["slug"] == "dumbbell" }["weights"]).must_equal [10, 20]

    get "/api/workouts/#{workout("cycle-1-workout-1").id}"
    targets = json["blocks"].flat_map { it["steps"] }.to_h { [it["exercise"]["slug"], it] }
    _(targets["reverse-fly"]["target"]["weight"]).must_equal({ "value" => 10.0, "unit" => "lb" })
  end

  it "answers 404 for their workouts, whatever is asked" do
    workout_id = @their_workout.id
    requests = [
      -> { get "/api/workouts/#{workout_id}" },
      -> { patch_json "/api/workouts/#{workout_id}", title: "Mine now" },
      -> { put_json "/api/workouts/#{workout_id}", blocks: [] },
      -> { delete "/api/workouts/#{workout_id}" },
      -> { post_json "/api/workouts/#{workout_id}/duplicate" },
      -> { get "/api/today?workout_id=#{workout_id}" },
      -> { post_json "/api/sessions", workout_id:, date: today.to_s }
    ]
    requests.each do |request|
      request.call
      _(last_response.status).must_equal 404, last_request.path
    end
    _(@their_workout.refresh.title).must_equal "Theirs"
    _(@their_workout.archived?).must_equal false
  end

  it "answers 404 for their sessions, whatever is asked" do
    session_id = @their_done.id
    requests = [
      -> { get "/api/sessions/#{session_id}" },
      -> { patch_json "/api/sessions/#{session_id}", note: "mine" },
      -> { delete "/api/sessions/#{session_id}" },
      -> { post_json "/api/sessions/#{session_id}/sets", step_id: @their_step.id, set_number: 1, reps: 5 },
      -> { post_json "/api/sessions/#{session_id}/complete", feedback: "right" },
      -> { patch_json "/api/sessions/#{session_id}/completion", note: "mine" },
      -> { get "/api/today?session_id=#{session_id}&date=#{today}" }
    ]
    requests.each do |request|
      request.call
      _(last_response.status).must_equal 404, last_request.path
    end
    _(@their_done.refresh.note).must_be_nil
    _(Current.set(user: @someone) { @their_done.completion.feedback }).must_equal "too_easy"
  end

  it "takes no step of theirs for a set, nor a warm-up of theirs for a workout" do
    mine = session_on(today, "planned")
    post_json "/api/sessions/#{mine.id}/sets", step_id: @their_step.id, set_number: 1, reps: 5
    _(last_response.status).must_equal 404

    own = workout("cycle-1-workout-1").duplicate!(title: "Mine")
    patch_json "/api/workouts/#{own.id}", warmup: @their_warmup.id.to_s
    _(last_response.status).must_equal 422
    _(json["error"]["fields"].keys).must_equal ["warmup"]
  end

  it "keeps client_refs and a day's numbering per user" do
    post_json "/api/sessions", workout_id: workout("cycle-1-workout-1").id, client_ref: "same-ref", today: today.to_s

    _(last_response.status).must_equal 201
    _(json["id"]).wont_equal @their_planned.id
    _(json["position"]).must_equal 1

    first = json["id"]
    post_json "/api/sessions", workout_id: workout("cycle-1-workout-2").id, today: today.to_s
    patch_json "/api/sessions/#{json["id"]}", position: 1, today: today.to_s
    delete "/api/sessions/#{first}"

    _([@their_done, @their_planned].map { it.refresh.position }).must_equal [1, 2]
  end

  it "suggests the next workout from the user's own rotation" do
    get "/api/today"

    _(json["source"]).must_equal "default"
    _(json["workout_id"]).must_equal workout("cycle-1-workout-1").id
  end

  it "reads and writes nothing of anyone's when nobody is signed in" do
    Current.set(user: nil) do
      _ { Setting.current }.must_raise Current::Missing
      _ { Workout.suggested }.must_raise Current::Missing
      [Program, Workout, Block, Step, Session, SetLog, Completion, ExerciseWeight, Setting, UserEquipment, ApiToken].each do |model|
        _ { model.count }.must_raise Current::Missing, model.name
      end
    end
  end

  it "saves or deletes a record only as its own user" do
    theirs = Session.everyone.with_pk(@their_planned.id)
    _ { theirs.update(note: "mine") }.must_raise Current::Mismatch
    _ { theirs.destroy }.must_raise Current::Mismatch
    _ { Setting.everyone.first(user_id: @someone.id).update(unit: "lb") }.must_raise Current::Mismatch
    _(Current.set(user: @someone) { theirs.update(note: "theirs") }.note).must_equal "theirs"
  end

  # Blocks, steps and finishes are a user's through their parent, and set
  # logs link a step by its id alone: none of them can be attached to, moved
  # to or kept on another user's records.
  it "saves or deletes a record kept through its parent only with a parent of the user's" do
    mine = workout("cycle-1-workout-1")
    _ { Block.create(workout_id: @their_workout.id, label: "Mine", position: 9, rounds: 1, rest_seconds: 0) }.must_raise Current::Mismatch
    _ { Step.create(block_id: @their_step.block_id, exercise_id: exercise("goblet-squat").id, position: 9, reps: 5) }.must_raise Current::Mismatch
    _ { Completion.create(session_id: @their_planned.id, finished_at: Time.now) }.must_raise Current::Mismatch
    _ { mine.blocks.first.update(workout_id: @their_workout.id) }.must_raise Current::Mismatch

    their_block = Block.everyone.with_pk(@their_step.block_id)
    _ { their_block.update(label: "Mine now") }.must_raise Current::Mismatch
    _ { Step.everyone.with_pk(@their_step.id).destroy }.must_raise Current::Mismatch
    _(Current.set(user: @someone) { their_block.update(label: "Still theirs") }.label).must_equal "Still theirs"

    session = Session.plan!(workout: mine, date: today, client_ref: "mine")
    log = { session:, set_number: 1, status: "done" }
    _ { SetLog.create(**log, step_id: @their_step.id) }.must_raise Current::Mismatch
    _(SetLog.create(**log, step_id: mine.blocks.first.steps.first.id).step_id).must_equal mine.blocks.first.steps.first.id
  end

  it "keeps every query to the signed-in user, without asking" do
    _(Session.with_pk(@their_done.id)).must_be_nil
    _(Step.with_pk(@their_step.id)).must_be_nil
    _(Completion.where(session_id: @their_done.id).count).must_equal 0
    _(Workout.where(id: @their_workout.id).update(title: "Mine now")).must_equal 0
    _(Session.everyone.with_pk(@their_done.id)).wont_be_nil
  end

  # Sequel keeps the SQL of a dataset, and the loaders of associations, for
  # reuse: none of it may keep the first user's id.
  it "keeps no query of one user's for the next" do
    steps = ->(slug) { Workout.eager(blocks: :steps).first(example_slug: slug).blocks.flat_map(&:steps).map(&:id) }
    lazy = ->(slug) { Workout.first(example_slug: slug).blocks.first.steps.map(&:id) }
    mine = [steps.call("cycle-1-workout-1"), lazy.call("cycle-1-workout-1"), Session.select_order_map(:id)]
    theirs = Current.set(user: @someone) do
      [steps.call("cycle-1-workout-1"), lazy.call("cycle-1-workout-1"), Session.select_order_map(:id)]
    end

    _(theirs[0] & mine[0]).must_be_empty
    _(theirs[1] & mine[1]).must_be_empty
    _(theirs[2]).must_equal [@their_done.id, @their_planned.id]
    _([steps.call("cycle-1-workout-1"), lazy.call("cycle-1-workout-1"), Session.select_order_map(:id)]).must_equal mine
  end

  describe "through MCP" do
    let(:token) { ApiToken.issue!(user, "Trainer agent").last }

    def call_tool(name, **arguments)
      headers = RequestHelpers::JSON_ENV.merge(
        "HTTP_HOST" => "localhost", "HTTP_ACCEPT" => "application/json, text/event-stream", "HTTP_AUTHORIZATION" => "Bearer #{token}"
      )
      post "/mcp", JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/call", params: { name:, arguments: }), headers
      result = json["result"]
      [result["isError"], result["content"].first["text"]]
    end

    it "lists and reads only the token user's records" do
      _, text = call_tool("list_workouts")
      _(JSON.parse(text)["programs"].flat_map { it["workouts"] }.map { it["id"] } & Workout.of(@someone.id).select_map(:id)).must_be_empty

      _, text = call_tool("list_sessions", from: (today - 7).to_s, to: (today + 7).to_s)
      _(JSON.parse(text)["sessions"]).must_be_empty

      _, text = call_tool("training_summary")
      summary = JSON.parse(text)
      _(summary["sessions"]).must_be_empty
      _(summary["remembered_weights"].to_a).must_be_empty

      _, text = call_tool("get_exercise", exercise: "reverse-fly")
      _(JSON.parse(text)["remembered_weight"]).must_be_nil

      _, text = call_tool("list_equipment")
      _(JSON.parse(text)["unit"]).must_equal "lb"
    end

    it "can't read or change another user's workouts and sessions" do
      tools = [
        ["get_workout", { workout_id: @their_workout.id }],
        ["update_workout", { workout_id: @their_workout.id, title: "Mine now" }],
        ["duplicate_workout", { workout_id: @their_workout.id }],
        ["archive_workout", { workout_id: @their_workout.id }],
        ["plan_sessions", { sessions: [{ date: today.to_s, workout_id: @their_workout.id }] }],
        ["move_session", { session_id: @their_planned.id, date: (today + 1).to_s }],
        ["remove_session", { session_id: @their_planned.id }]
      ]
      tools.each do |name, arguments|
        error, text = call_tool(name, **arguments)
        _(error).must_equal true, name
        id = arguments[:workout_id] || arguments[:session_id] || @their_workout.id
        _(text).must_match(/\b(sessions\[0\]: )?no (workout|session) #{id};/, name)
      end
      _(@their_workout.refresh.title).must_equal "Theirs"
      _(@their_planned.refresh.date).must_equal today
    end
  end
end
