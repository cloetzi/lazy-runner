require "test_helper"

# A tool answered with an error; the message is its text.
class McpToolError < StandardError; end

# The MCP server at /mcp, driven over HTTP as a client would: JSON-RPC posts
# answered with plain JSON.
describe "MCP server" do
  include RequestHelpers

  # An assistant signs in with its user's API token.
  let(:token) { ApiToken.issue!(user, "Trainer agent").last }
  let(:headers) do
    RequestHelpers::JSON_ENV.merge(
      "HTTP_HOST" => "localhost", "HTTP_ACCEPT" => "application/json, text/event-stream",
      "HTTP_AUTHORIZATION" => "Bearer #{token}"
    )
  end

  def rpc(method, params = nil)
    post "/mcp", JSON.generate({ jsonrpc: "2.0", id: 1, method:, params: }.compact), headers
    _(last_response.status).must_equal 200, last_response.body
    _(json["error"]).must_be_nil
    json["result"]
  end

  # A tool's answer, parsed; a tool error raises McpToolError.
  def call_tool(name, **arguments)
    result = rpc("tools/call", { name:, arguments: })
    text = result["content"].first["text"]
    raise McpToolError, text if result["isError"]

    JSON.parse(text)
  end

  describe "initialize" do
    it "names the server and hands over the trainer brief" do
      result = rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } })

      _(result["serverInfo"]["name"]).must_equal "lazy-runner"
      _(result["instructions"]).must_equal TrainerMcp::BRIEF
      _(result["capabilities"].keys).must_include "tools"
    end

    it "keeps no session between requests" do
      rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } })

      _(last_response.headers["mcp-session-id"]).must_be_nil
    end
  end

  describe "the trainer brief" do
    it "states the rules a plan must keep" do
      brief = TrainerMcp::BRIEF

      _(brief).must_include "applies to all of them"
      _(brief).must_include "set per workout step"
      _(brief).must_include "Every workout is the user's"
      _(brief).must_include "can't add one"
      _(brief).must_include "Plan only with equipment the user owns"
      _(brief).must_include "a day without a session is a rest day"
      _(brief).must_include "not an error"
      _(brief).must_include "editing one changes every session"
      _(brief).must_include "Never estimate a number"
    end

    it "is a prompt" do
      _(rpc("prompts/list")["prompts"].map { it["name"] }).must_equal ["trainer_brief"]

      result = rpc("prompts/get", { name: "trainer_brief" })

      _(result["messages"].first["content"]["text"]).must_equal TrainerMcp::BRIEF
    end

    it "is a resource" do
      _(rpc("resources/list")["resources"].map { it["uri"] }).must_equal [TrainerMcp::BRIEF_URI]

      result = rpc("resources/read", { uri: TrainerMcp::BRIEF_URI })

      _(result["contents"].first.slice("mimeType", "text")).must_equal({ "mimeType" => "text/markdown", "text" => TrainerMcp::BRIEF })
    end
  end

  describe "tools/list" do
    let(:tools) { rpc("tools/list")["tools"].index_by { it["name"] } }

    it "lists the read tools marked read-only, then the write tools" do
      reads = %w[search_exercises get_exercise list_equipment list_workouts get_workout training_summary list_sessions list_activities list_routines
        list_examples get_coach_board list_coach_notes]
      writes = %w[create_workout import_example update_workout duplicate_workout archive_workout set_exercise_weight update_equipment plan_sessions move_session
        remove_session log_activities plan_routine update_routine end_routine write_coach_note update_coach_note delete_coach_notes resolve_concern propose_goal]

      _(tools.keys).must_equal reads + writes
      _(tools.values_at(*reads).map { it["annotations"].values_at("readOnlyHint", "destructiveHint") }.uniq).must_equal [[true, false]]
      _(tools.values_at(*writes).map { it["annotations"]["readOnlyHint"] }.uniq).must_equal [false]
      _(tools.select { |_, tool| tool["annotations"]["destructiveHint"] }.keys).must_equal %w[update_workout archive_workout update_equipment remove_session update_routine end_routine
        update_coach_note delete_coach_notes]
    end

    it "says a weight applies to every workout, while reps and time are per step" do
      _(tools["get_exercise"]["description"]).must_include "changing it applies to every workout that uses the exercise, while reps and time are set per workout step"
      _(tools["get_workout"]["description"]).must_include "changing an exercise's weight applies to every workout that uses it, while reps and time are set per workout step"
      _(tools["set_exercise_weight"]["description"]).must_include "It applies to every workout that uses the exercise"
      _(tools["set_exercise_weight"]["description"]).must_include "they are set per workout step"
    end

    it "says on the calendar that a change to a workout reaches every future session, a missed one is a signal and an empty day is rest" do
      %w[list_sessions plan_sessions move_session].each do |name|
        description = tools[name]["description"]

        _(description).must_include "changing a workout changes every future session of it"
        _(description).must_include "not an error"
        _(description).must_include "A day without one is a rest day"
      end
      _(tools["update_workout"]["description"]).must_include "a change applies to every future session of it"
    end
  end

  describe "search_exercises" do
    it "keeps to the equipment owned by default" do
      inventory("hangboard").update(owned: false)

      slugs = call_tool("search_exercises")["exercises"].map { it["slug"] }

      _(slugs).must_include "dead-bug"
      _(slugs).wont_include "dead-hang"
      _(call_tool("search_exercises", equipment: "all")["exercises"].map { it["slug"] }).must_include "dead-hang"
    end

    it "filters by area, pattern, category and words" do
      found = call_tool("search_exercises", area: "legs", pattern: "squat", category: "strength")["exercises"]

      _(found.map { it["slug"] }).must_include "goblet-squat"
      _(found.map { it.values_at("pattern", "category") }.uniq).must_equal [%w[squat strength]]
      _(found.all? { it["areas"].include?("legs") }).must_equal true

      _(call_tool("search_exercises", text: "goblet SQUAT")["exercises"].map { it["slug"] }).must_equal ["goblet-squat"]
      _(call_tool("search_exercises", text: "pigeon-stretch")["exercises"].map { it["slug"] }).must_equal ["pigeon-stretch"]
    end

    it "says which exercises alternate sides within a set" do
      found = call_tool("search_exercises", text: "dead bug")["exercises"].find { it["slug"] == "dead-bug" }

      _(found.slice("unilateral", "alternating")).must_equal({ "unilateral" => false, "alternating" => true })
      _(call_tool("search_exercises", text: "goblet squat")["exercises"].first["alternating"]).must_equal false
      _(call_tool("get_workout", workout_id: workout("cycle-1-workout-1").id)["blocks"].flat_map { it["steps"] }
        .find { it["exercise"]["slug"] == "dead-bug" }["exercise"]["alternating"]).must_equal true
    end

    it "falls back to any of the words, most words first, when no exercise has them all" do
      found = call_tool("search_exercises", text: "calf ankle foot", equipment: "all")["exercises"].map { it["slug"] }

      _(found).must_include "single-leg-calf-raise"
      _(found).must_include "calf-stretch"
      _(call_tool("search_exercises", text: "zebra unicorn")["count"]).must_equal 0
      _(call_tool("search_exercises", text: "a stretch for the zebra")["exercises"].map { it["category"] }.uniq).must_equal ["stretch"]
    end

    it "answers compactly, without animations or instructions" do
      squat = call_tool("search_exercises", text: "goblet squat")["exercises"].first

      _(squat.keys).must_equal %w[id slug name category areas pattern unilateral alternating equipment default_reps cues]
      _(squat["equipment"]).must_equal ["weight"]
    end

    it "keeps to the equipment named, or to bodyweight" do
      _(call_tool("search_exercises", equipment: "none")["exercises"].map { it["equipment"] }.uniq).must_equal [[]]
      _(call_tool("search_exercises", equipment: "dumbbell")["exercises"].map { it["slug"] }).must_include "goblet-squat"
    end

    it "says which equipment slug it does not know" do
      error = _ { call_tool("search_exercises", equipment: "dumbbell,barbell") }.must_raise McpToolError

      _(error.message).must_include "unknown equipment: barbell"
    end

    it "rejects an area the library does not use" do
      _ { call_tool("search_exercises", area: "arms") }.must_raise McpToolError
    end

    it "leaves retired exercises out" do
      exercise("dead-bug").update(retired: true)

      _(call_tool("search_exercises", equipment: "all")["exercises"].map { it["slug"] }).wont_include "dead-bug"
    end
  end

  describe "get_exercise" do
    let(:squat) { exercise("goblet-squat") }

    it "gives the instructions, mistakes and equipment, without the animation" do
      found = call_tool("get_exercise", exercise: "goblet-squat")

      _(found["instructions"]).must_equal squat.instructions
      _(found["equipment"]).must_equal ["weight"]
      _(found["allowed_weights"]).must_equal [10.0, 20.0, 40.0]
      _(found.key?("animation")).must_equal false
      _(found["used_in"].map { it["title"] }).must_include "Workout 1"
    end

    it "gives the remembered weight and a pending suggestion" do
      ExerciseWeight.create(exercise: squat, value: 20, unit: "lb")
      WeightSuggestion.create(exercise: squat, session: session_on(Date.today), direction: "up", value: 30, unit: "lb", reason: "Felt too easy at 20 lb")

      found = call_tool("get_exercise", exercise: squat.id)

      _(found["remembered_weight"]).must_equal({ "value" => 20.0, "unit" => "lb" })
      _(found["suggestion"]).must_equal({ "direction" => "up", "value" => 30.0, "unit" => "lb", "reason" => "Felt too easy at 20 lb" })
    end

    it "leaves the remembered weight out while there is none" do
      _(call_tool("get_exercise", exercise: "goblet-squat").key?("remembered_weight")).must_equal false
    end

    it "says when there is no such exercise" do
      error = _ { call_tool("get_exercise", exercise: "burpee") }.must_raise McpToolError

      _(error.message).must_include 'no exercise "burpee"'
    end

    it "wants an exercise" do
      _ { call_tool("get_exercise") }.must_raise McpToolError
    end

    it "finds one by its id as text too" do
      _(call_tool("get_exercise", exercise: exercise("plank").id.to_s)["slug"]).must_equal "plank"
    end
  end

  describe "list_equipment" do
    it "gives the inventory with the weights owned, and the unit weights are shown in" do
      answer = call_tool("list_equipment")
      dumbbell = answer["equipment"].find { it["slug"] == "dumbbell" }

      _(answer["unit"]).must_equal "lb"
      _(dumbbell.slice("owned", "weights", "unit")).must_equal({ "owned" => true, "weights" => [10, 20], "unit" => "lb" })
      _(answer["equipment"].map { it["slug"] }).must_equal Equipment.current.in_order.map(&:slug)
    end
  end

  describe "update_equipment" do
    it "records gear the user says they have, which search_exercises then counts" do
      inventory("step").update(owned: false)
      _(call_tool("search_exercises")["exercises"].map { it["slug"] }).wont_include "lateral-step-down"

      item = call_tool("update_equipment", equipment: "step", owned: true)

      _(item.slice("slug", "owned")).must_equal({ "slug" => "step", "owned" => true })
      _(inventory("step").owned).must_equal true
      _(call_tool("search_exercises")["exercises"].map { it["slug"] }).must_include "lateral-step-down"
    end

    it "replaces the weights owned of an item that comes in set weights" do
      item = call_tool("update_equipment", equipment: "dumbbell", weights: [10, 20, 30])

      _(item.slice("owned", "weights", "unit")).must_equal({ "owned" => true, "weights" => [10, 20, 30], "unit" => "lb" })
      _(inventory("dumbbell").weights).must_equal [10, 20, 30]
    end

    it "says what it can't change" do
      _(_ { call_tool("update_equipment", equipment: "stool", owned: true) }.must_raise(McpToolError).message).must_include "list_equipment lists the slugs"
      _(_ { call_tool("update_equipment", equipment: "mat", weights: [5]) }.must_raise(McpToolError).message).must_include "can only be listed for equipment with a unit"
      _(_ { call_tool("update_equipment", equipment: "mat") }.must_raise(McpToolError).message).must_include "nothing to change"
    end
  end

  describe "list_examples" do
    it "lists the example programs, and which are imported" do
      examples = call_tool("list_examples")["examples"]

      _(examples.map { it["slug"] }).must_equal %w[cycle-1 home-strength]
      _(examples.first["workouts"].map { it["slug"] }).must_include "cycle-1-workout-1"
      _(examples.map { it["imported"] }.uniq).must_equal [true]
    end
  end

  describe "import_example" do
    it "imports one as an assistant's program, its weights snapped to what is owned" do
      inventory("kettlebell").update(weights: [35])
      program = call_tool("import_example", example: "home-strength", copy: true)

      _(program.slice("example_slug", "name")).must_equal("example_slug" => "home-strength", "name" => "Home strength (copy)")
      _(program["workouts"].map { it["source"] }.uniq).must_equal ["llm"]
      squat = Workout.find!(program["workouts"].first["id"]).blocks.flat_map(&:steps).find { it.exercise.slug == "goblet-squat" }
      _(squat.weight).must_equal(value: 35.0, unit: "lb")
      _(Program.with_pk(program["id"]).source).must_equal "llm"
    end

    it "refuses a second import without copy, and an unknown example" do
      error = _ { call_tool("import_example", example: "cycle-1") }.must_raise McpToolError
      _(error.message).must_equal "Cycle 1 is already imported; import it again with copy to add another"

      error = _ { call_tool("import_example", example: "marathon") }.must_raise McpToolError
      _(error.message).must_equal "no example program marathon"
    end
  end

  describe "list_workouts" do
    it "lists the programs' workouts, then the user's own" do
      copy = workout("cycle-1-workout-1").duplicate!(title: "My legs")

      programs = call_tool("list_workouts")["programs"]

      _(programs.first["workouts"].map { it["source"] }.uniq).must_equal ["user"]
      _(programs.last["name"]).must_equal "My workouts"
      _(programs.last["workouts"].map { it.slice("id", "title", "source") }).must_equal [{ "id" => copy.id, "title" => "My legs", "source" => "user" }]
      _(programs.last.key?("id")).must_equal false
    end
  end

  describe "get_workout" do
    let(:seeded) { workout("cycle-1-workout-1") }

    it "gives the blocks and steps with their targets, naming each exercise" do
      ExerciseWeight.create(exercise: exercise("goblet-squat"), value: 20, unit: "lb")

      found = call_tool("get_workout", workout_id: seeded.id)
      step = found["blocks"].first["steps"].first

      _(found.slice("title", "source", "editable")).must_equal({ "title" => "Workout 1", "source" => "user", "editable" => true })
      _(step["exercise"]).must_equal({ "id" => exercise("goblet-squat").id, "slug" => "goblet-squat", "name" => "Goblet squat", "alternating" => false, "equipment" => ["weight"] })
      # Any weight, so no gear of its own.
      _(step["equipment"]).must_be_nil
      _(step["target"]).must_equal({ "reps" => 8, "weight" => { "value" => 20.0, "unit" => "lb" } })
      _(found["framed"].map { it["example_slug"] }).must_equal %w[cycle-1-warmup cycle-1-workout-1 cycle-1-cooldown]
      _(found.keys).wont_include "plan"
    end

    it "says when there is no such workout" do
      error = _ { call_tool("get_workout", workout_id: 0) }.must_raise McpToolError

      _(error.message).must_include "no workout 0"
    end
  end

  describe "training_summary" do
    it "covers the last 28 days up to today by default" do
      travel_to Time.zone.local(2026, 10, 20, 12) do
        session_on("2026-09-22")
        session_on("2026-09-23")
        session_on("2026-10-21", "planned")

        answer = call_tool("training_summary")

        _(answer.values_at("today", "from", "to")).must_equal %w[2026-10-20 2026-09-23 2026-10-20]
        _(answer["sessions"].map { it["date"] }).must_equal ["2026-09-23"]
        # Wednesday to Tuesday: the first and last weeks are partly covered.
        _(answer["weeks"].map { it["days"] }).must_equal [2, nil, nil, nil, 5]
      end
    end

    it "gives each session, how it felt and what was done against the target" do
      done = session_on("2026-10-19")
      log_all(done, "goblet-squat", reps: 6)
      finish(done, "too_hard")
      done.completion.update(rpe: 9, note: "Heavy")
      session_on("2026-10-22", "planned", created_by: "llm")

      answer = travel_to(Time.zone.local(2026, 10, 20, 12)) { call_tool("training_summary", from: "2026-10-19", to: "2026-10-26") }
      first, planned = answer["sessions"]
      squat = first["exercises"].find { it["exercise"] == "goblet-squat" }

      _(first.slice("date", "status")).must_equal({ "date" => "2026-10-19", "status" => "done" })
      _(first["workout"]["title"]).must_equal "Workout 1"
      _(first["completion"]).must_equal({ "rpe" => 9, "feedback" => "too_hard", "note" => "Heavy", "ended_early" => false })
      _(squat["target"]).must_equal({ "reps" => 8, "weight" => { "value" => 40.0, "unit" => "lb" } })
      _(squat.slice("sets_done", "sets_skipped", "reps", "weights")).must_equal(
        { "sets_done" => 3, "sets_skipped" => 0, "reps" => [6, 6, 6], "weights" => [{ "value" => 40.0, "unit" => "lb" }] }
      )
      _(planned.slice("date", "status", "created_by")).must_equal({ "date" => "2026-10-22", "status" => "planned", "created_by" => "llm" })
      _(planned.key?("exercises")).must_equal false
      _(answer["weeks"]).must_equal [
        { "week_start" => "2026-10-26", "done" => 0, "partial" => 0, "days" => 1 }, { "week_start" => "2026-10-19", "done" => 1, "partial" => 0 }
      ]
    end

    it "says a planned session whose day has passed was missed" do
      travel_to Time.zone.local(2026, 10, 20, 12) do
        session_on("2026-10-18", "planned")

        _(call_tool("training_summary")["sessions"].map { it["status"] }).must_equal ["missed"]
      end
    end

    it "counts a per-side set once for both sides" do
      session = session_on("2026-10-19")
      log_all(session, "single-leg-deadlift", reps: 9)
      SetLog.where(session:, set_number: 2, side: "right").update(status: "skipped")

      deadlift = call_tool("training_summary", from: "2026-10-19", to: "2026-10-19")["sessions"].first["exercises"].first

      _(deadlift.slice("per_side", "sets_done", "sets_skipped", "reps")).must_equal({ "per_side" => true, "sets_done" => 2, "sets_skipped" => 0, "reps" => [9, 9, 9] })
    end

    it "runs four weeks on from a first day given alone, into the future too" do
      travel_to Time.zone.local(2026, 10, 20, 12) do
        session_on("2026-11-09", "planned")

        answer = call_tool("training_summary", from: "2026-11-02")

        _(answer.values_at("from", "to")).must_equal %w[2026-11-02 2026-11-29]
        _(answer["sessions"].map { it["date"] }).must_equal ["2026-11-09"]
      end
    end

    it "names the exercise planned when one was swapped" do
      session = session_on("2026-10-19", "in_progress")
      step = step_for("cycle-1-workout-1", "goblet-squat")
      SetLog.create(session:, step:, set_number: 1, exercise: exercise("curtsy-lunge"), reps: 8)

      squat = call_tool("training_summary", from: "2026-10-19", to: "2026-10-19")["sessions"].first["exercises"].first

      _(squat.slice("exercise", "instead_of")).must_equal({ "exercise" => "curtsy-lunge", "instead_of" => "goblet-squat" })
    end

    it "gives the remembered weights and the suggestions waiting for the user" do
      squat = exercise("goblet-squat")
      ExerciseWeight.create(exercise: squat, value: 20, unit: "lb")
      session = session_on("2026-10-19")
      WeightSuggestion.create(exercise: squat, session:, direction: "up", value: 30, unit: "lb", reason: "Felt too easy at 20 lb")

      answer = call_tool("training_summary", from: "2026-10-01", to: "2026-10-28")

      _(answer["remembered_weights"].map { it.except("updated") }).must_equal [{ "exercise" => "goblet-squat", "name" => "Goblet squat", "value" => 20.0, "unit" => "lb" }]
      _(answer["pending_suggestions"]).must_equal [{
        "exercise" => "goblet-squat", "name" => "Goblet squat", "direction" => "up", "value" => 30.0, "unit" => "lb",
        "reason" => "Felt too easy at 20 lb", "after_session" => session.id
      }]
    end

    it "dates a remembered weight by the server's day" do
      with_time_zone("America/Vancouver") do
        travel_to Time.utc(2026, 10, 31, 2) do
          ExerciseWeight.create(exercise: exercise("goblet-squat"), value: 20, unit: "lb")

          _(call_tool("training_summary")["remembered_weights"].first["updated"]).must_equal "2026-10-30"
        end
      end
    end

    it "says what is wrong with a range" do
      _(_ { call_tool("training_summary", from: "2026-10-20", to: "2026-10-01") }.must_raise(McpToolError).message).must_include "from must not be after to"
      _(_ { call_tool("training_summary", from: "2025-01-01", to: "2026-10-01") }.must_raise(McpToolError).message).must_include "at most 366 days"
      _(_ { call_tool("training_summary", from: "October") }.must_raise(McpToolError).message).must_include "from"
    end
  end

  # The workouts and the calendar the assistant writes, all on the 20th.
  describe "writing" do
    before { travel_to Time.zone.local(2026, 10, 20, 12) }
    after { travel_back }

    let(:blocks) do
      [
        { label: "Main", rounds: 3, rest_seconds: 60, steps: [{ exercise: "goblet-squat", reps: 8, tempo: "3110" }, { exercise: "plank", duration_seconds: 30 }] },
        { label: "Finisher", steps: [{ exercise: "dead-bug", reps: 10 }] }
      ]
    end

    def create(**arguments) = call_tool("create_workout", kind: "workout", title: "Legs for skiing", blocks:, **arguments)

    describe "create_workout" do
      it "builds a workout of the assistant's from exercise slugs, answering as get_workout does" do
        built = create(subtitle: "Knees over toes", cooldown: "none")
        squat = built["blocks"].first["steps"].first

        _(built.slice("title", "subtitle", "kind", "source", "editable", "cooldown")).must_equal(
          { "title" => "Legs for skiing", "subtitle" => "Knees over toes", "kind" => "workout", "source" => "llm", "editable" => true, "cooldown" => "none" }
        )
        _(built["blocks"].map { it.slice("label", "rounds", "rest_seconds") }).must_equal [
          { "label" => "Main", "rounds" => 3, "rest_seconds" => 60 }, { "label" => "Finisher", "rounds" => 1, "rest_seconds" => 0 }
        ]
        _(squat.slice("reps", "tempo")).must_equal({ "reps" => 8, "tempo" => "3110" })
        _(squat["exercise"]["slug"]).must_equal "goblet-squat"
        _(squat["id"]).must_equal Workout.find!(built["id"]).blocks.first.steps.first.id
        _(call_tool("list_workouts")["programs"].last["workouts"].map { it["title"] }).must_equal ["Legs for skiing"]
      end

      it "names each block and step at fault, and writes nothing" do
        count = Workout.count
        blocks[0][:steps] << { exercise: "burpee", reps: 8 }
        blocks[1][:steps][0].merge!(duration_seconds: 30)

        error = _ { create }.must_raise McpToolError

        _(error.message).must_include "Block 1 (Main), step 3: Exercise burpee is not in the library"
        _(error.message).must_include "Block 2 (Finisher), step 1 (dead-bug): needs reps or seconds, not both"
        _(error.message).must_include "Nothing was changed"
        _(Workout.count).must_equal count
      end

      it "says what is wrong with an argument of the wrong type, before anything is written" do
        blocks[0][:steps][0][:reps] = "eight"

        _(_ { create }.must_raise(McpToolError).message).must_include "/blocks/0/steps/0/reps"
      end

      it "names a step's equipment only when it is not the exercise's own, so the workout goes back as it came" do
        blocks[1][:steps] << { exercise: "goblet-squat", reps: 8, equipment: ["kettlebell"], weights_held: 1 }
        built = create
        squat, kettlebell = built["blocks"].map { it["steps"].find { it["exercise"]["slug"] == "goblet-squat" } }

        _(squat.key?("equipment")).must_equal false
        _(kettlebell["equipment"]).must_equal ["kettlebell"]

        sent = built["blocks"]
        sent.first["steps"][0]["exercise"] = "single-leg-deadlift"
        sent.first["steps"][0].merge!("reps" => 6, "tempo" => nil, "per_side" => true)
        call_tool("update_workout", workout_id: built["id"], blocks: sent)

        _(Workout.find!(built["id"]).blocks.flat_map(&:steps).map { it.equipment.map(&:slug) }).must_equal [[], [], [], ["kettlebell"]]
      end

      it "takes a weight as a number in the exercise's unit, or as value and unit" do
        blocks[0][:steps][0][:weight] = 20
        blocks[1][:steps] << { exercise: "two-arm-row", reps: 10, weight: { value: 10, unit: "lb" } }

        built = create

        _(built["blocks"][0]["steps"][0]["weight"]).must_equal({ "value" => 20.0, "unit" => "lb" })
        _(built["blocks"][1]["steps"][1]["weight"]).must_equal({ "value" => 10.0, "unit" => "lb" })
        _(built.key?("warnings")).must_equal false
      end

      it "says a weight without a value needs one, before anything is written" do
        blocks[0][:steps][0][:weight] = { unit: "lb" }

        error = _ { create }.must_raise McpToolError

        _(error.message).must_include "/blocks/0/steps/0/weight` is missing required properties: value"
      end

      it "warns of a weight the user doesn't own for the step's gear, naming the gear that has it" do
        blocks[0][:steps][0] = { exercise: "two-arm-row", reps: 8, weight: 40 }

        warnings = create["warnings"]

        _(warnings).must_equal [
          %(Block 1 (Main), step 1 (two-arm-row): 40 lb is not a weight the user owns for dumbbell (10, 20 lb); give equipment ["kettlebell"] if it is done with that, or give one of those)
        ]
      end

      it "takes any weight owned for an exercise that needs just a weight" do
        blocks[0][:steps][0][:weight] = 40
        _(create.key?("warnings")).must_equal false

        blocks[0][:steps][0][:weight] = 30
        _(create["warnings"]).must_equal [
          "Block 1 (Main), step 1 (goblet-squat): 30 lb is not a weight the user owns for any weight (10, 20, 40 lb); give one of those"
        ]
      end

      it "warns of the remembered weight a session will use, not of a start weight it won't" do
        blocks[0][:steps][0] = { exercise: "two-arm-row", reps: 8, weight: 20 }
        ExerciseWeight.remember!(exercise("two-arm-row"), 40, "lb")

        _(create["warnings"].first).must_include "40 lb is not a weight the user owns for dumbbell"
        _(create["warnings"].first).must_include "remembered weight, which wins over a step's: set_exercise_weight changes it"

        ExerciseWeight.remember!(exercise("two-arm-row"), 20, "lb")
        blocks[0][:steps][0][:weight] = 40

        _(create.key?("warnings")).must_equal false
      end

      it "warns of gear the user doesn't own, and saves the workout anyway" do
        inventory("step").update(owned: false)
        blocks[1][:steps] << { exercise: "lateral-step-down", reps: 6 }

        built = create

        _(built["warnings"]).must_equal ["Block 2 (Finisher), step 2 (lateral-step-down): needs step, which the user doesn't own: pick an exercise without it, or update_equipment once they say they have it"]
        _(Workout.with_pk(built["id"])).wont_be_nil
      end

      it "says equipment it doesn't know is unknown, not missing from the inventory" do
        blocks[1][:steps][0][:equipment] = ["none"]

        _(_ { create }.must_raise(McpToolError).message).must_include "Block 2 (Finisher), step 1 (dead-bug): Equipment none is unknown: no equipment has that slug"
      end

      it "picks a warm-up by id, and says when it is not one" do
        warmup = workout("cycle-1-warmup")

        _(create(warmup: warmup.id)["framed"].map { it["id"] }.first).must_equal warmup.id
        _(_ { create(warmup: workout("cycle-1-cooldown").id) }.must_raise(McpToolError).message).must_include "Warmup must be a warm-up"
      end
    end

    describe "update_workout" do
      it "takes back what get_workout gave, keeping the steps it names and the sets logged against them" do
        built = create
        squat = Step.find!(built["blocks"].first["steps"].first["id"])
        session = Session.create(workout_id: built["id"], date: Date.new(2026, 10, 19), status: "done")
        SetLog.create(session:, step: squat, set_number: 1, reps: 8)

        sent = call_tool("get_workout", workout_id: built["id"])["blocks"]
        sent.first["steps"].first["reps"] = 10
        sent.first["steps"].pop
        updated = call_tool("update_workout", workout_id: built["id"], title: "Legs, harder", blocks: sent)

        _(updated["title"]).must_equal "Legs, harder"
        _(updated["blocks"].first["steps"].map { it.values_at("id", "reps") }).must_equal [[squat.id, 10]]
        _(SetLog.first(session:).step_id).must_equal squat.id
      end

      it "keeps a step's weights held when sent back as get_workout gave it" do
        copy = call_tool("duplicate_workout", workout_id: workout("cycle-1-workout-1").id)
        held = ->(id) { Workout.find!(id).blocks.flat_map(&:steps).map(&:weights_held) }
        before = held.(copy["id"])

        call_tool("update_workout", workout_id: copy["id"], blocks: call_tool("get_workout", workout_id: copy["id"])["blocks"])

        _(before).must_include 1
        _(held.(copy["id"])).must_equal before
      end

      it "keeps the structure when only the title changes" do
        built = create

        updated = call_tool("update_workout", workout_id: built["id"], subtitle: "For the ski season")

        _(updated["subtitle"]).must_equal "For the ski season"
        _(updated["blocks"].map { it["id"] }).must_equal built["blocks"].map { it["id"] }
      end

      it "leaves a workout a session is running alone" do
        built = create
        Session.create(workout_id: built["id"], date: Date.new(2026, 10, 20), status: "in_progress")

        error = _ { call_tool("update_workout", workout_id: built["id"], blocks: [{ label: "A", steps: [{ exercise: "plank", duration_seconds: 20 }] }]) }.must_raise McpToolError

        _(error.message).must_include "is being trained right now"
        _(Workout.find!(built["id"]).blocks.map(&:label)).must_equal %w[Main Finisher]
      end

      it "wants something to change" do
        _(_ { call_tool("update_workout", workout_id: create["id"]) }.must_raise(McpToolError).message).must_include "nothing to change"
      end
    end

    describe "duplicate_workout" do
      it "copies a built-in workout into an editable one of the assistant's" do
        copy = call_tool("duplicate_workout", workout_id: workout("cycle-1-workout-1").id, title: "Workout 1, my way")

        _(copy.slice("title", "source", "editable")).must_equal({ "title" => "Workout 1, my way", "source" => "llm", "editable" => true })
        _(copy["framed"].map { it["example_slug"] }).must_equal ["cycle-1-warmup", nil, "cycle-1-cooldown"]
      end
    end

    describe "archive_workout" do
      it "archives a workout and takes its sessions from today on off the calendar" do
        built = create
        missed = session_on("2026-10-18", "planned", workout: Workout.find!(built["id"]))
        coming = Session.create(workout_id: built["id"], date: Date.new(2026, 10, 22), status: "planned")

        answer = call_tool("archive_workout", workout_id: built["id"])

        _(answer).must_equal({ "id" => built["id"], "title" => "Legs for skiing", "archived" => true, "removed_sessions" => [{ "id" => coming.id, "date" => "2026-10-22" }], "reframed_workouts" => [] })
        _(Session.where(id: missed.id).empty?).must_equal false
        _(_ { call_tool("update_workout", workout_id: built["id"], title: "Again") }.must_raise(McpToolError).message).must_include "is archived"
      end

      it "names the workouts an archived warm-up leaves" do
        warmup = call_tool("duplicate_workout", workout_id: workout("cycle-1-warmup").id)
        built = create
        call_tool("update_workout", workout_id: built["id"], warmup: warmup["id"])

        answer = call_tool("archive_workout", workout_id: warmup["id"])

        _(answer["reframed_workouts"]).must_equal [{ "id" => built["id"], "title" => "Legs for skiing" }]
        _(Workout.find!(built["id"]).frame_choice("warmup")).must_equal "none"
      end

      it "archives a workout of an imported example too" do
        imported = workout("cycle-1-workout-2")
        _(call_tool("archive_workout", workout_id: imported.id)["archived"]).must_equal true
        _(imported.refresh.archived?).must_equal true
      end
    end

    describe "set_exercise_weight" do
      let(:squat) { exercise("goblet-squat") }

      it "remembers the weight for every workout with the exercise, answering a pending suggestion" do
        WeightSuggestion.create(exercise: squat, session: session_on("2026-10-19"), direction: "up", value: 20, unit: "lb", reason: "Felt too easy")

        answer = call_tool("set_exercise_weight", exercise: "goblet-squat", value: 20)

        _(answer.slice("exercise", "remembered_weight", "suggestion")).must_equal(
          { "exercise" => "goblet-squat", "remembered_weight" => { "value" => 20.0, "unit" => "lb" }, "suggestion" => { "direction" => "up", "value" => 20.0, "unit" => "lb", "status" => "accepted" } }
        )
        _(answer["used_in"].map { it["title"] }).must_include "Workout 1"
        _(call_tool("get_workout", workout_id: workout("cycle-1-workout-1").id)["blocks"].first["steps"].first["target"]["weight"]).must_equal({ "value" => 20.0, "unit" => "lb" })
      end

      it "takes 0 as no weight, which wins over the workout's own and reads back as 0" do
        answer = call_tool("set_exercise_weight", exercise: "goblet-squat", value: 0)

        _(answer["remembered_weight"]).must_equal({ "value" => 0.0, "unit" => "lb" })
        _(ExerciseWeight.first!(exercise_id: squat.id).value).must_be_nil
        ExerciseWeight.first!(exercise_id: squat.id).update(unit: "kg")
        _(call_tool("get_exercise", exercise: "goblet-squat")["remembered_weight"]).must_equal({ "value" => 0.0, "unit" => "lb" })
        _(call_tool("get_workout", workout_id: workout("cycle-1-workout-1").id)["blocks"].first["steps"].first["target"].key?("weight")).must_equal false
      end

      it "converts a weight in the other unit and snaps it to one owned" do
        _(call_tool("set_exercise_weight", exercise: squat.id, value: 9, unit: "kg")["remembered_weight"]).must_equal({ "value" => 20.0, "unit" => "lb" })
      end

      it "says what is wrong with a weight" do
        _(_ { call_tool("set_exercise_weight", exercise: "goblet-squat", value: -5) }.must_raise(McpToolError).message).must_include "Value must be greater than or equal to 0"
        _(_ { call_tool("set_exercise_weight", exercise: "burpee", value: 5) }.must_raise(McpToolError).message).must_include 'no exercise "burpee"'
      end
    end

    describe "list_sessions" do
      it "lists the calendar over a range, missed sessions and finished ones included" do
        done = session_on("2026-10-19")
        finish(done, "right")
        missed = session_on("2026-10-18", "planned", created_by: "llm")
        coming = session_on("2026-10-22", "planned", part_kinds: %w[workout cooldown])

        answer = call_tool("list_sessions", from: "2026-10-18", to: "2026-10-24")

        _(answer.values_at("today", "from", "to")).must_equal %w[2026-10-20 2026-10-18 2026-10-24]
        _(answer["sessions"].map { it.values_at("id", "status") }).must_equal [[missed.id, "missed"], [done.id, "done"], [coming.id, "planned"]]
        _(answer["sessions"].first["created_by"]).must_equal "llm"
        _(answer["sessions"][1]["completion"]["feedback"]).must_equal "right"
        _(answer["sessions"].last["parts"]).must_equal %w[workout cooldown]
        _(answer["sessions"].last["minutes"]).must_equal coming.parts.sum(&:estimated_minutes)
        _(answer["sessions"].first["minutes"]).must_be :>, answer["sessions"].last["minutes"]
      end

      it "looks four weeks ahead for what is planned, and keeps to the statuses asked" do
        session_on("2026-10-18", "planned")
        coming = session_on("2026-11-10", "planned")

        answer = call_tool("list_sessions", status: ["planned"])

        _(answer.values_at("from", "to")).must_equal %w[2026-10-20 2026-11-16]
        _(answer["sessions"].map { it["id"] }).must_equal [coming.id]
        _(call_tool("list_sessions", status: ["missed"])["sessions"].map { it["status"] }).must_equal ["missed"]
      end

      it "says what is wrong with a range, as the API does" do
        _(_ { call_tool("list_sessions", from: "2026-10-20", to: "2026-10-01") }.must_raise(McpToolError).message).must_equal "from must not be after to"
        _(_ { call_tool("list_sessions", status: ["someday"]) }.must_raise(McpToolError).message).must_include "/status/0"
      end
    end

    describe "plan_sessions" do
      let(:workout_1) { workout("cycle-1-workout-1") }

      it "plans several sessions at once, marked as the assistant's" do
        session_on("2026-10-21", "planned")

        answer = call_tool("plan_sessions", sessions: [
          { date: "2026-10-21", workout_id: workout_1.id, position: 1, note: "Legs before the long run", parts: %w[workout cooldown] },
          { date: "2026-10-23", workout_id: workout("cycle-1-workout-2").id }
        ])

        _(answer["planned"].map { it.values_at("date", "position", "status", "created_by") }).must_equal [
          ["2026-10-21", 1, "planned", "llm"], ["2026-10-23", 1, "planned", "llm"]
        ]
        _(answer["planned"].first.values_at("note", "parts")).must_equal ["Legs before the long run", %w[workout cooldown]]
        _(Session.where(date: Date.new(2026, 10, 21)).order(:position).map(&:created_by)).must_equal %w[llm manual]
      end

      it "plans nothing when one session can't be planned, naming it" do
        error = _ do
          call_tool("plan_sessions", sessions: [{ date: "2026-10-22", workout_id: workout_1.id }, { date: "2026-10-19", workout_id: workout_1.id }])
        end.must_raise McpToolError

        _(error.message).must_equal "sessions[1] (2026-10-19, workout #{workout_1.id}): Date must be today or later. Nothing was planned."
        _(Session.count).must_equal 0
      end

      it "says which workout it does not know, or which is archived" do
        archived = Workout.find!(create["id"]).tap(&:archive!)

        _(_ { call_tool("plan_sessions", sessions: [{ date: "2026-10-22", workout_id: 0 }]) }.must_raise(McpToolError).message).must_include "sessions[0]: no workout 0"
        _(_ { call_tool("plan_sessions", sessions: [{ date: "2026-10-22", workout_id: archived.id }]) }.must_raise(McpToolError).message).must_include "Workout is archived"
        _(Session.count).must_equal 0
      end

      it "reads a date as YYYY-MM-DD only" do
        error = _ { call_tool("plan_sessions", sessions: [{ date: "11/03/2026", workout_id: workout_1.id }]) }.must_raise McpToolError

        _(error.message).must_include "sessions[0] (11/03/2026, workout #{workout_1.id}): Date must be a date as YYYY-MM-DD"
        _(Session.count).must_equal 0
      end

      it "plans at most four weeks of sessions at once" do
        sessions = Array.new(Session::PLAN_LIMIT + 1) { { date: "2026-10-22", workout_id: workout_1.id } }

        _(_ { call_tool("plan_sessions", sessions:) }.must_raise(McpToolError).message).must_include "/sessions"
        _(Session.count).must_equal 0
      end
    end

    describe "move_session" do
      it "moves a missed session to a day from today on, answering with the days it left and joined" do
        missed = session_on("2026-10-18", "planned")
        there = session_on("2026-10-21", "planned")

        answer = call_tool("move_session", session_id: missed.id, date: "2026-10-21", position: 1, note: "Moved after the race")

        _(answer["session"].values_at("date", "position", "status", "note")).must_equal ["2026-10-21", 1, "planned", "Moved after the race"]
        _(answer["days"].transform_values { |day| day.map { it["id"] } }).must_equal({ "2026-10-18" => [], "2026-10-21" => [missed.id, there.id] })
      end

      it "keeps the note unless one is given" do
        planned = session_on("2026-10-21", "planned", note: "Legs")

        _(call_tool("move_session", session_id: planned.id, date: "2026-10-22")["session"]["note"]).must_equal "Legs"
        _(call_tool("move_session", session_id: planned.id, note: nil)["session"].key?("note")).must_equal false
      end

      it "leaves a session that has started, been skipped or is done alone" do
        done = session_on("2026-10-19")

        _(_ { call_tool("move_session", session_id: done.id, date: "2026-10-22") }.must_raise(McpToolError).message).must_equal(
          "session #{done.id} is done; only a planned session can be moved"
        )
        _(_ { call_tool("move_session", session_id: done.id) }.must_raise(McpToolError).message).must_include "nothing to change"
        _(_ { call_tool("move_session", session_id: 0, date: "2026-10-22") }.must_raise(McpToolError).message).must_include "no session 0"
      end

      it "says a planned session can't go back in time" do
        planned = session_on("2026-10-21", "planned")

        _(_ { call_tool("move_session", session_id: planned.id, date: "2026-10-19") }.must_raise(McpToolError).message).must_equal "Date must be today or later"
      end
    end

    describe "remove_session" do
      it "takes a planned session off the calendar, the user's included" do
        first, second = 2.times.map { session_on("2026-10-21", "planned") }

        answer = call_tool("remove_session", session_id: first.id)

        _(answer["removed"].values_at("id", "created_by")).must_equal [first.id, "manual"]
        _(answer["day"].map { it.values_at("id", "position") }).must_equal [[second.id, 1]]
        _(Session.where(id: first.id).empty?).must_equal true
      end

      it "keeps history" do
        skipped = session_on("2026-10-19", "skipped")

        _(_ { call_tool("remove_session", session_id: skipped.id) }.must_raise(McpToolError).message).must_include "only a planned session can be removed"
        _(Session.where(id: skipped.id).empty?).must_equal false
      end
    end

    it "builds a workout and plans it through /mcp, which the REST API then reads back" do
      built = create
      planned = call_tool("plan_sessions", sessions: [{ date: "2026-10-22", workout_id: built["id"], note: "Before the weekend long run" }])["planned"].first

      get "/api/workouts/#{built["id"]}"
      _(last_response.status).must_equal 200
      _(json.slice("title", "source", "editable")).must_equal({ "title" => "Legs for skiing", "source" => "llm", "editable" => true })
      _(json["blocks"].flat_map { |block| block["steps"].map { it["exercise"]["slug"] } }).must_equal %w[goblet-squat plank dead-bug]

      get "/api/sessions?status=planned"
      _(json.map { it.slice("id", "date", "created_by", "note") }).must_equal [
        { "id" => planned["id"], "date" => "2026-10-22", "created_by" => "llm", "note" => "Before the weekend long run" }
      ]
      _(json.first["workout"]["id"]).must_equal built["id"]

      get "/api/workouts"
      _(json.last["workouts"].map { it["id"] }).must_equal [built["id"]]
    end
  end

  describe "activities" do
    before { travel_to Time.zone.local(2026, 11, 4, 12) }
    after { travel_back }

    let(:garmin_run) do
      {
        date: "2026-11-03", sport: "trail_running", source: "garmin", external_id: 18_234_567_890, title: "Morning trail",
        started_at: "2026-11-03T06:12:00Z", distance: "5 mi", climb: "820 ft", moving_seconds: 2950.4, elapsed_seconds: 3101, avg_hr: 148.6, max_hr: 171
      }
    end

    it "logs a backfill as the agent's, converting distances to metres" do
      logged = call_tool("log_activities", activities: [garmin_run, { date: "2026-11-01", sport: "ride", distance: 21_500.4 }])

      _(logged.slice("created", "updated")).must_equal("created" => 2, "updated" => 0)
      _(logged["activities"].map { it["outcome"] }).must_equal %w[created created]
      run = Activity.with_pk(logged["activities"].first["id"])
      _(run.values.slice(:sport, :source, :external_id, :distance_m, :climb_m, :moving_seconds, :avg_hr, :created_by)).must_equal(
        sport: "trail running", source: "garmin", external_id: "18234567890", distance_m: 8047, climb_m: 250,
        moving_seconds: 2950, avg_hr: 149, created_by: "llm"
      )
      _(run.started_at).must_equal Time.utc(2026, 11, 3, 6, 12)
      _(Activity.with_pk(logged["activities"].last["id"]).distance_m).must_equal 21_500
    end

    it "updates what it sent again, keeping the person's RPE and note and the fields left out" do
      first = call_tool("log_activities", activities: [garmin_run])["activities"].first
      Activity.with_pk(first["id"]).update(rpe: 6, note: "Heavy legs")

      again = call_tool("log_activities", activities: [{ date: "2026-11-03", sport: "trail run", source: "garmin", external_id: "18234567890", distance: "8.1 km" }])

      _(again.slice("created", "updated")).must_equal("created" => 0, "updated" => 1)
      _(again["activities"].first["id"]).must_equal first["id"]
      run = Activity.with_pk(first["id"])
      _(run.values.slice(:distance_m, :climb_m, :title, :rpe, :note)).must_equal(distance_m: 8100, climb_m: 250, title: "Morning trail", rpe: 6, note: "Heavy legs")
      _(Activity.count).must_equal 1
    end

    it "logs nothing when one entry is wrong, and names it" do
      bad_distance = { date: "2026-11-02", sport: "run", distance: "5 parsecs" }
      _(_ { call_tool("log_activities", activities: [garmin_run, bad_distance]) }.must_raise(McpToolError).message).must_include "activities[1].distance must be metres"

      tomorrow = { date: "2026-11-05", sport: "run" }
      message = _ { call_tool("log_activities", activities: [garmin_run, tomorrow]) }.must_raise(McpToolError).message
      _(message).must_include "activities[1]: Date must not be after today"
      _(message).must_include "Nothing was logged"

      us_date = { date: "11/3/2026", sport: "run" }
      _(_ { call_tool("log_activities", activities: [us_date]) }.must_raise(McpToolError).message).must_equal "activities[0].date must be a date as YYYY-MM-DD"
      _(_ { call_tool("log_activities", activities: [garmin_run.merge(climb: -3)]) }.must_raise(McpToolError).message).must_include "activities[0].climb must not be negative"

      zoneless = garmin_run.merge(started_at: "2026-11-03T07:12:00")
      _(_ { call_tool("log_activities", activities: [zoneless]) }.must_raise(McpToolError).message).must_include "needs its offset"
      _(Activity.count).must_equal 0
    end

    it "counts a pair sent twice once, a float id matching its integer" do
      logged = call_tool("log_activities", activities: [garmin_run, garmin_run.merge(external_id: 18_234_567_890.0, title: "Trail loop")])

      _(logged.slice("created", "updated")).must_equal("created" => 1, "updated" => 0)
      _(Activity.select_map(%i[external_id title])).must_equal [["18234567890", "Trail loop"]]
    end

    it "takes the user's today, a day either side of the server's" do
      _(call_tool("log_activities", today: "2026-11-05", activities: [{ date: "2026-11-05", sport: "run" }])["created"]).must_equal 1
      _(_ { call_tool("log_activities", today: "2026-11-07", activities: [{ date: "2026-11-07", sport: "run" }]) }.must_raise(McpToolError).message).must_include "within a day"
    end

    it "takes no RPE or note, which are the person's" do
      _(_ { call_tool("log_activities", activities: [garmin_run.merge(rpe: 7)]) }.must_raise(McpToolError).message).must_include "/rpe"
      _(_ { call_tool("log_activities", activities: [garmin_run.merge(note: "Felt great")]) }.must_raise(McpToolError).message).must_include "/note"
    end

    it "lists the user's activities only, with how they read distances" do
      call_tool("log_activities", activities: [garmin_run])
      mine, = Activity.log!({ date: "2026-11-02", sport: "run", distance_m: 5000, rpe: 5 })
      Current.set(user: create_user("someone")) { Activity.log!({ date: "2026-11-02", sport: "run" }) }
      Setting.current.update(distance_unit: "mi")

      listed = call_tool("list_activities")

      _(listed.slice("today", "from", "to", "distance_unit")).must_equal("today" => "2026-11-04", "from" => "2026-10-08", "to" => "2026-11-04", "distance_unit" => "mi")
      _(listed["activities"].map { it.slice("date", "sport", "created_by") }).must_equal [
        { "date" => "2026-11-02", "sport" => "run", "created_by" => "manual" },
        { "date" => "2026-11-03", "sport" => "trail running", "created_by" => "llm" }
      ]
      _(listed["activities"].first).must_equal("id" => mine.id, "date" => "2026-11-02", "sport" => "run", "distance_m" => 5000, "rpe" => 5, "created_by" => "manual")
      _(call_tool("list_activities", sport: "Trail Running", from: "2026-11-01", to: "2026-11-04")["activities"].size).must_equal 1
      _(_ { call_tool("list_activities", from: "yesterday") }.must_raise(McpToolError).message).must_include "YYYY-MM-DD"
    end
  end

  describe "routines" do
    # A Wednesday.
    before { travel_to Time.zone.local(2026, 11, 11, 12) }
    after { travel_back }

    it "plans a weekly run as the agent's, tentative, with its distance in metres" do
      planned = call_tool("plan_routine", sport: "Run", weekdays: [3, 6], title: "Easy run", distance: "5 mi", effort: "easy", note: "Keep it chatty")

      routine = Routine.with_pk(planned["routine"]["id"])
      _(routine.values.slice(:sport, :distance_m, :created_by, :starts_on)).must_equal(sport: "run", distance_m: 8047, created_by: "llm", starts_on: Date.new(2026, 11, 11))
      _(planned["days"].first(2).map { it.values_at("on", "state") }).must_equal [%w[2026-11-11 tentative], %w[2026-11-14 tentative]]
    end

    it "plans a one-off hike, and refuses one in the past" do
      planned = call_tool("plan_routine", sport: "hike", weekdays: [], starts_on: "2026-11-15")

      _(planned["routine"].values_at("one_off", "ends_on")).must_equal [true, "2026-11-15"]
      _(_ { call_tool("plan_routine", sport: "hike", weekdays: [], starts_on: "2026-11-10") }.must_raise(McpToolError).message).must_include "Starts on must be today or later"
    end

    it "lists routines and their days, with raw counts per state" do
      run = Routine.plan!({ sport: "run", weekdays: [1, 3] }, today: Date.new(2026, 11, 2))
      Activity.log!({ date: "2026-11-09", sport: "trail run" })
      listed = call_tool("list_routines", from: "2026-11-02", to: "2026-11-11")

      _(listed["routines"].map { it.values_at("id", "created_by") }).must_equal [[run.id, "manual"]]
      _(listed["days"].map { it.values_at("on", "state") }).must_equal [%w[2026-11-02 missed], %w[2026-11-04 missed], %w[2026-11-09 done], %w[2026-11-11 tentative]]
      _(listed["counts"]).must_equal("missed" => 2, "done" => 1, "tentative" => 1)
    end

    it "looks a week back and three weeks ahead without dates, so a one-off planned for next week shows" do
      Routine.plan!({ sport: "run", weekdays: [], title: "Before the week back" }, today: Date.new(2026, 11, 3))
      Routine.plan!({ sport: "run", weekdays: [], title: "A week back" }, today: Date.new(2026, 11, 4))
      call_tool("plan_routine", sport: "run", weekdays: [], starts_on: "2026-11-17", title: "Tempo run")
      call_tool("plan_routine", sport: "run", weekdays: [], starts_on: "2026-12-01", title: "Last day ahead")
      call_tool("plan_routine", sport: "run", weekdays: [], starts_on: "2026-12-02", title: "Past the range")
      listed = call_tool("list_routines")

      _(listed.values_at("from", "to")).must_equal %w[2026-11-04 2026-12-01]
      _(listed["routines"].map { it["title"] }).must_equal ["A week back", "Tempo run", "Last day ahead"]
      _(listed["days"].map { it.values_at("on", "state") }).must_equal [%w[2026-11-04 missed], %w[2026-11-17 tentative], %w[2026-12-01 tentative]]
      _(call_tool("list_routines", to: "2026-11-11").values_at("from", "to")).must_equal %w[2026-10-15 2026-11-11]
    end

    it "changes and ends only the routines it planned" do
      mine = Routine.plan!({ sport: "run", weekdays: [3] })
      _(_ { call_tool("update_routine", routine_id: mine.id, weekdays: [4]) }.must_raise(McpToolError).message).must_include "is the user's"
      _(_ { call_tool("end_routine", routine_id: mine.id) }.must_raise(McpToolError).message).must_include "is the user's"

      planned = call_tool("plan_routine", sport: "ride", weekdays: [6])["routine"]
      changed = call_tool("update_routine", routine_id: planned["id"], weekdays: [7], minutes: 90)
      _(changed["routine"].values_at("id", "weekdays", "minutes")).must_equal [planned["id"], [7], 90]
      _(call_tool("end_routine", routine_id: planned["id"])).must_equal("id" => planned["id"], "outcome" => "deleted")
    end

    it "turns its workout routine into a run" do
      planned = call_tool("plan_routine", workout_id: workout("cycle-1-workout-1").id, weekdays: [5])["routine"]
      changed = call_tool("update_routine", routine_id: planned["id"], workout_id: nil, sport: "run")

      _(changed["routine"].values_at("sport", "workout")).must_equal ["run", nil]
    end

    it "starts a new routine when it reschedules one with days gone by, and says which it ended" do
      old = Routine.plan!({ sport: "run", weekdays: [1] }, today: Date.new(2026, 11, 2), created_by: "llm")
      changed = call_tool("update_routine", routine_id: old.id, weekdays: [2])

      _(changed["routine"]["id"]).wont_equal old.id
      _(changed["ended"].values_at("id", "ends_on")).must_equal [old.id, "2026-11-10"]
      _(call_tool("end_routine", routine_id: changed["routine"]["id"])["outcome"]).must_equal "deleted"
    end

    it "can't reach another user's routines" do
      other = create_user("other")
      theirs = Current.set(user: other) { Routine.plan!({ sport: "run", weekdays: [3] }, created_by: "llm") }

      _(call_tool("list_routines", from: "2026-11-09", to: "2026-11-15")["routines"]).must_equal []
      _(_ { call_tool("end_routine", routine_id: theirs.id) }.must_raise(McpToolError).message).must_include "no routine #{theirs.id}"
    end

    it "has no tool that confirms, skips or moves a routine day" do
      names = rpc("tools/list")["tools"].map { it["name"] }

      _(names.grep(/routine/)).must_equal %w[list_routines plan_routine update_routine end_routine]
    end
  end

  describe "coaching" do
    before { travel_to Time.zone.local(2026, 11, 4, 12) }
    after { travel_back }

    def person_note(kind, body, **fields) = CoachNote.create(kind:, body:, author_kind: "user", **fields)

    it "reads the board: goals first, then status, focus, concerns, notes and this week" do
      goal = Goal.add!(title: "Ski season with quiet knees", target_date: Date.new(2026, 12, 15))
      dismissed = Goal.propose!(title: "Run a marathon", reason: "You like long runs").tap(&:dismiss!)
      person_note("status", "Week 3 of 6")
      concern = person_note("concern", "Sore after the downhills", title: "Left knee")
      run, = Activity.log!({ date: "2026-11-03", sport: "run", distance_m: 7100 })

      board = call_tool("get_coach_board")

      _(board["goals"]).must_equal [{ "id" => goal.id, "title" => "Ski season with quiet knees", "target_date" => "2026-12-15", "status" => "active", "position" => 1 }]
      _(board["dismissed"].map { it["id"] }).must_equal [dismissed.id]
      _(board["status"].slice("body", "author_kind")).must_equal("body" => "Week 3 of 6", "author_kind" => "user")
      _(board["focus"]).must_be_nil
      _(board["concerns"].map { it["id"] }).must_equal [concern.id]
      _(board.slice("today", "weekday")).must_equal("today" => "2026-11-04", "weekday" => "Wednesday")
      _(board["week"].slice("from", "to")).must_equal("from" => "2026-11-02", "to" => "2026-11-08")
      _(board["week"]["activities"].map { it["id"] }).must_equal [run.id]
    end

    it "shows this week's routine days on the board, the user's and the agent's" do
      runs = Routine.plan!({ sport: "run", weekdays: [2, 6], title: "Easy run" }, today: Date.new(2026, 11, 2))
      Activity.log!({ date: "2026-11-03", sport: "run" })
      tempo = Routine.plan!({ sport: "run", weekdays: [], starts_on: "2026-11-05", title: "Tempo" }, created_by: "llm")
      Routine.plan!({ sport: "run", weekdays: [], starts_on: "2026-11-10" }, created_by: "llm")

      week = call_tool("get_coach_board")["week"]

      _(week["routines"].map { it.values_at("id", "title", "created_by") }).must_equal [[runs.id, "Easy run", "manual"], [tempo.id, "Tempo", "llm"]]
      _(week["routine_days"].map { it.values_at("routine_id", "on", "state") }).must_equal [
        [runs.id, "2026-11-03", "done"], [tempo.id, "2026-11-05", "tentative"], [runs.id, "2026-11-07", "tentative"]
      ]
    end

    it "writes notes as the agent, about the user's own activities only" do
      run, = Activity.log!({ date: "2026-11-03", sport: "run" })

      written = call_tool("write_coach_note", kind: "status", body: "Base block, week 3", author_name: "Someone else", activity_id: run.id)

      _(written.slice("kind", "author_kind", "author_name")).must_equal("kind" => "status", "author_kind" => "llm", "author_name" => "Trainer agent")
      _(written["about"]).must_equal("type" => "activity", "id" => run.id, "label" => "Run")
      _(_ { call_tool("write_coach_note", kind: "concern", body: "Hmm") }.must_raise(McpToolError).message).must_equal "Title can't be blank"

      theirs = Current.set(user: create_user("someone")) { Activity.log!({ date: "2026-11-03", sport: "run" }).first }
      _(_ { call_tool("write_coach_note", kind: "note", body: "Sneaky", activity_id: theirs.id) }.must_raise(McpToolError).message).must_equal "Activity is not found"
    end

    it "resolves only the concerns an agent raised" do
      mine = call_tool("write_coach_note", kind: "concern", title: "Run club missed twice", body: "Wednesday may not fit")
      theirs = person_note("concern", "Sore", title: "Left knee")

      resolved = call_tool("resolve_concern", note_id: mine["id"], resolution: "Back on track")
      _(resolved.slice("resolution", "resolved")).must_equal("resolution" => "Back on track", "resolved" => "2026-11-04")

      _(_ { call_tool("resolve_concern", note_id: theirs.id, resolution: "Fine") }.must_raise(McpToolError).message).must_include "the person's to resolve"
      _(theirs.refresh.resolved?).must_equal false
      _(_ { call_tool("resolve_concern", note_id: mine["id"], resolution: "Again") }.must_raise(McpToolError).message).must_include "already resolved"
    end

    it "signs everything it writes with its token's name" do
      workout_1 = workout("cycle-1-workout-1")
      call_tool("plan_sessions", sessions: [{ date: "2026-11-05", workout_id: workout_1.id }])
      call_tool("plan_routine", sport: "run", weekdays: [6], title: "Long run")
      routine = call_tool("plan_routine", workout_id: workout("cycle-1-workout-2").id, weekdays: [], starts_on: "2026-11-07")["routine"]
      call_tool("log_activities", activities: [{ date: "2026-11-03", sport: "run", source: "garmin", external_id: "1" }])
      call_tool("propose_goal", title: "Run a half", reason: "You asked")
      call_tool("write_coach_note", kind: "note", body: "Easy week")

      # The person says yes to the agent's workout day: the session is still the agent's.
      Routine.find!(routine["id"]).confirm!(Date.new(2026, 11, 7))

      _(Session.count).must_equal 2
      [Session, Routine, Activity, Goal].each { _(it.select_map(:agent_name).uniq).must_equal ["Trainer agent"] }
      _(CoachNote.select_map(:author_name)).must_equal ["Trainer agent"]
      _(Current.agent_name).must_be_nil
      _(call_tool("list_sessions", from: "2026-11-01", to: "2026-11-30")["sessions"].map { it["agent_name"] }.uniq).must_equal ["Trainer agent"]

      # The app reads the name wherever it shows what the agent did.
      get "/api/calendar?from=2026-11-01&to=2026-11-08&today=2026-11-04"
      %w[sessions activities routines].each { |list| _(json[list].map { it["agent_name"] }.uniq).must_equal ["Trainer agent"] }
      get "/api/coach"
      _(json["proposals"].map { it["agent_name"] }).must_equal ["Trainer agent"]
    end

    it "only proposes goals, which wait for the user" do
      goal = Goal.add!(title: "Half marathon under 1:55")

      proposal = call_tool("propose_goal", title: "Half marathon under 1:50", reason: "Your long runs got faster", replaces: goal.id)

      _(proposal.slice("status", "reason", "replaces")).must_equal("status" => "proposed", "reason" => "Your long runs got faster", "replaces" => goal.id)
      _(Goal.active.select_map(:title)).must_equal ["Half marathon under 1:55"]
      _(Goal.with_pk(proposal["id"]).created_by).must_equal "llm"

      Goal.with_pk(proposal["id"]).dismiss!
      _(_ { call_tool("propose_goal", title: "Half marathon under 1:50", reason: "Really") }.must_raise(McpToolError).message).must_include "don't propose it again"
      _(_ { call_tool("propose_goal", title: "Other", reason: "Why not", replaces: 999_999) }.must_raise(McpToolError).message).must_include "no active goal"
    end

    it "writes the same note once, and at most #{CoachNote::AGENT_DAILY_LIMIT} a day" do
      first = call_tool("write_coach_note", kind: "note", body: "Easy week ", date: "2026-11-05")
      again = call_tool("write_coach_note", kind: "note", body: "Easy week", date: "2026-11-05")

      _(again["id"]).must_equal first["id"]
      _(again["already_written"]).must_equal true
      _(call_tool("write_coach_note", kind: "note", body: "Easy week", date: "2026-11-06")["id"]).wont_equal first["id"]
      # The name it signs with is its token's, whatever it sends.
      _(call_tool("write_coach_note", kind: "note", body: "Easy week", date: "2026-11-05", author_name: "Other agent")["id"]).must_equal first["id"]
      _(TrainerMcp::BRIEF).must_include "at most #{CoachNote::AGENT_DAILY_LIMIT} a day"
      _(TrainerMcp::BRIEF).must_include "up to #{CoachNote::PAGE_LIMIT} at once"

      status = call_tool("write_coach_note", kind: "status", body: "Base block")
      call_tool("write_coach_note", kind: "status", body: "Taper")
      back = call_tool("write_coach_note", kind: "status", body: "Base block")
      _(back["id"]).wont_equal status["id"]
      _(back["already_written"]).must_be_nil

      person_note("note", "Mine do not count")
      (CoachNote::AGENT_DAILY_LIMIT - CoachNote.by_agent.count).times { call_tool("write_coach_note", kind: "note", body: "Note #{it}") }
      _(_ { call_tool("write_coach_note", kind: "note", body: "One more") }.must_raise(McpToolError).message).must_include "update_coach_note"
      _(call_tool("write_coach_note", kind: "note", body: "Note 0")["already_written"]).must_equal true
      _(_ { call_tool("write_coach_note", kind: "concern", body: "No title") }.must_raise(McpToolError).message).must_equal "Title can't be blank"

      CoachNote.by_agent.update(created_at: Time.zone.local(2026, 11, 3, 23, 59).to_time)
      _(call_tool("write_coach_note", kind: "note", body: "One more")["body"]).must_equal "One more"
      _(call_tool("write_coach_note", kind: "note", body: "Note 0")["already_written"]).must_be_nil
    end

    it "lists every note, newest first, by kind, author and day" do
      mine = call_tool("write_coach_note", kind: "note", body: "Long run Sunday", date: "2026-11-08")
      theirs = person_note("note", "Knee fine", date: "2026-11-03")
      status = call_tool("write_coach_note", kind: "status", body: "Week 3")

      all = call_tool("list_coach_notes")
      _(all["notes"].map { it["id"] }).must_equal [status["id"], theirs.id, mine["id"]]
      _(all.slice("count", "today")).must_equal("count" => 3, "today" => "2026-11-04")
      _(call_tool("list_coach_notes", author: "llm")["notes"].map { it["id"] }).must_equal [status["id"], mine["id"]]
      _(call_tool("list_coach_notes", kind: "status")["notes"].map { it["id"] }).must_equal [status["id"]]
      _(call_tool("list_coach_notes", from: "2026-11-05", to: "2026-11-30")["notes"].map { it["id"] }).must_equal [mine["id"]]

      page = call_tool("list_coach_notes", limit: 2)
      _(page.slice("count", "before")).must_equal("count" => 3, "before" => theirs.id)
      rest = call_tool("list_coach_notes", limit: 2, before: page["before"])
      _(rest["notes"].map { it["id"] }).must_equal [mine["id"]]
      _(rest["before"]).must_be_nil

      Current.set(user: create_user("someone")) { CoachNote.create(kind: "note", body: "Not yours", author_kind: "llm") }
      _(call_tool("list_coach_notes")["count"]).must_equal 3
    end

    it "changes only the notes an agent wrote" do
      mine = call_tool("write_coach_note", kind: "note", body: "Run 5 km Sunday", date: "2026-11-08")
      theirs = person_note("note", "Knee fine")
      run, = Activity.log!({ date: "2026-11-03", sport: "run" })

      changed = call_tool("update_coach_note", note_id: mine["id"], body: "Run 8 km Sunday", activity_id: run.id, date: nil)
      _(changed.slice("id", "body", "date")).must_equal("id" => mine["id"], "body" => "Run 8 km Sunday")
      _(changed["about"]["id"]).must_equal run.id

      _(_ { call_tool("update_coach_note", note_id: theirs.id, body: "Knee sore") }.must_raise(McpToolError).message).must_include "the person's"
      _(theirs.refresh.body).must_equal "Knee fine"
      _(call_tool("update_coach_note", note_id: mine["id"], body: "Run 8 km Sunday")["body"]).must_equal "Run 8 km Sunday"
      _(_ { call_tool("update_coach_note", note_id: mine["id"]) }.must_raise(McpToolError).message).must_include "nothing to change"
      _(_ { call_tool("update_coach_note", note_id: mine["id"], body: " ") }.must_raise(McpToolError).message).must_equal "Body can't be blank"

      other = Current.set(user: create_user("someone")) { CoachNote.create(kind: "note", body: "Not yours", author_kind: "llm") }
      _(_ { call_tool("update_coach_note", note_id: other.id, body: "Mine now") }.must_raise(McpToolError).message).must_include "no note #{other.id}"
    end

    it "deletes the agent's notes, all or nothing" do
      notes = 3.times.map { call_tool("write_coach_note", kind: "note", body: "Run plan #{it}")["id"] }
      theirs = person_note("note", "Knee fine")
      status = call_tool("write_coach_note", kind: "status", body: "Week 3")
      older = person_note("status", "Week 2")
      newest = call_tool("write_coach_note", kind: "status", body: "Week 4")

      refused = _ { call_tool("delete_coach_notes", note_ids: [notes.first, theirs.id]) }.must_raise(McpToolError)
      _(refused.message).must_include "notes #{theirs.id} are the person's"
      _(_ { call_tool("delete_coach_notes", note_ids: [notes.first, 999_999]) }.must_raise(McpToolError).message).must_include "no notes 999999"
      _(CoachNote.where(id: notes).count).must_equal 3

      _(call_tool("delete_coach_notes", note_ids: notes.reverse + [newest["id"]])).must_equal("deleted" => notes + [newest["id"]], "count" => 4)
      _(CoachNote.select_order_map(:id)).must_equal [theirs.id, status["id"], older.id]
      _(call_tool("get_coach_board")["status"]["body"]).must_equal "Week 2"
    end

    it "has no tool that edits a goal" do
      names = rpc("tools/list")["tools"].map { it["name"] }

      _(names.grep(/goal|note|concern/)).must_equal %w[list_coach_notes write_coach_note update_coach_note delete_coach_notes resolve_concern propose_goal]
    end
  end

  it "refuses an argument a tool does not take, as its schema says" do
    schemas = rpc("tools/list")["tools"].map { it["inputSchema"] }

    _(schemas.map { it["additionalProperties"] }.uniq).must_equal [false]
    _(_ { call_tool("list_equipment", owned: true) }.must_raise(McpToolError).message).must_include "`/owned` is a disallowed additional property"
    _(_ { call_tool("get_exercise", exercise: "plank", limit: 3) }.must_raise(McpToolError).message).must_include "`/limit`"
  end

  describe "the local network guard" do
    it "turns away a host it was not told about, as a rebound name would be" do
      post "/mcp", JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list"), headers.merge("HTTP_HOST" => "evil.example")

      _(last_response.status).must_equal 403
    end

    it "accepts the hosts MCP_ALLOWED_HOSTS names" do
      app = TrainerMcp.app(allowed_hosts: "trainer.home.arpa, 192.168.1.5:3000")
      body = JSON.generate(jsonrpc: "2.0", id: 1, method: "ping")
      env = lambda do |host|
        Rack::MockRequest.env_for("/", method: "POST", input: body, "CONTENT_TYPE" => "application/json",
                                       "HTTP_ACCEPT" => "application/json", "HTTP_HOST" => host, "HTTP_AUTHORIZATION" => "Bearer #{token}")
      end

      _(app.call(env.("trainer.home.arpa")).first).must_equal 200
      _(app.call(env.("192.168.1.5:3000")).first).must_equal 200
      _(app.call(env.("192.168.1.5:8080")).first).must_equal 403
    end
  end

  describe "signing in" do
    def post_rpc(extra = {})
      post "/mcp", JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list"), headers.merge(extra)
    end

    it "turns away a request without a token, saying how to sign in" do
      post_rpc("HTTP_AUTHORIZATION" => nil)

      _(last_response.status).must_equal 401
      _(last_response.headers["www-authenticate"]).must_match(/\ABearer/)
    end

    it "takes no browser session in place of a token" do
      sign_in(user)
      post_rpc("HTTP_AUTHORIZATION" => nil)

      _(last_response.status).must_equal 401
    end

    it "turns away an unknown or revoked token" do
      post_rpc("HTTP_AUTHORIZATION" => "Bearer lr_#{"x" * 43}")
      _(last_response.status).must_equal 401
      _(last_response.headers["www-authenticate"]).must_include "invalid_token"

      secret = token
      ApiToken.first!(user_id: user.id).destroy
      post_rpc("HTTP_AUTHORIZATION" => "Bearer #{secret}")
      _(last_response.status).must_equal 401
    end

    it "turns away a user who signed in with a temporary password" do
      secret = token
      user.this.update(password_change_required: true)
      post_rpc

      _(last_response.status).must_equal 401
      _(last_response.headers["www-authenticate"]).must_include "invalid_token"
    end

    it "hands the token's user to a tool that asks for one" do
      tool = Class.new(TrainerMcp::Tool) do
        tool_name "whoami"
        def self.answer(user:) = { username: user.username }
      end
      context = Struct.new(:auth_info).new(TrainerMcp::TokenVerifier.new.verify(token))
      response = tool.call(server_context: context)

      _(JSON.parse(response.content.first[:text])).must_equal({ "username" => "runner" })
      _ { tool.call(server_context: nil) }.must_raise TrainerMcp::Tool::Unauthenticated
    end

    it "notes when a token was last used, to the minute" do
      rpc("tools/list")
      used = ApiToken.first!(user_id: user.id).last_used_at
      rpc("tools/list")

      _(used).wont_be_nil
      _(ApiToken.first!(user_id: user.id).last_used_at).must_equal used
    end
  end
end
