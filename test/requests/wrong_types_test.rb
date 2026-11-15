require "test_helper"

# JSON can hold any type where a field expects another: an object, an array
# or a number sent to a documented field (and invalid UTF-8 to a query
# parameter) is answered in the one error shape, never with a 500. Each
# route starts from a request it would accept, so the wrong value is the
# only thing wrong; the fields come from the API description, so a new one
# is covered as soon as it is described.
describe "wrongly typed parameters" do
  include RequestHelpers

  # A Wednesday.
  before { travel_to Time.utc(2026, 11, 11, 12) }
  after { travel_back }

  WRONG = [{ "a" => "b" }, [1, 2], 7, 7.5, true, "x"].freeze

  def self.schema_for(operation)
    spec = RequestHelpers::SPEC
    resolve = ->(schema) { schema && schema["$ref"] ? spec.dig(*schema["$ref"].delete_prefix("#/").split("/")) : schema }
    schema = resolve.(operation.dig("requestBody", "content", "application/json", "schema"))
    schema = resolve.(schema["oneOf"].first) if schema&.key?("oneOf")
    schema
  end

  # Everything a request below needs: a record of each kind.
  let(:strength) { workout("cycle-1-workout-1") }
  let(:planned) { session_on("2026-11-12", "planned") }
  let(:done) { session_on("2026-11-10", "done").tap { Completion.create(session_id: it.id, finished_at: Time.now) } }
  let(:step) { step_for("cycle-1-workout-1", "goblet-squat") }
  let(:own_workout) { Workout.create_with!({ kind: "workout", title: "Mine", blocks: [{ label: "A", steps: [{ exercise_id: exercise("plank").id, duration_seconds: 30 }] }] }) }
  let(:activity) { Activity.log!({ date: "2026-11-10", sport: "run", moving_seconds: 1800 }).first }
  let(:routine) { Routine.plan!({ sport: "run", weekdays: [6] }) }
  let(:goal) { Goal.add!(title: "Strong knees") }
  let(:note) { CoachNote.create(kind: "note", body: "Easy week", author_kind: "llm") }
  let(:change) { Current.set(agent_name: "Coach agent") { Session.add!(workout: strength, date: Date.new(2026, 11, 13), status: "planned", created_by: "llm") }; PlanChange.first! }

  # [method, path, a body it accepts]: every route that takes a body.
  def requests
    [
      [:post, "/api/account/tokens", { name: "Script" }],
      [:post, "/api/invites", { label: "Sam" }],
      [:patch, "/api/settings", { unit: "kg" }],
      [:patch, "/api/equipment/#{equipment("dumbbell").id}", { owned: true }],
      [:put, "/api/exercises/#{exercise("goblet-squat").id}/weight", { value: 20, unit: "lb" }],
      [:post, "/api/examples/cycle-1/import", { copy: true }],
      [:post, "/api/workouts", { kind: "workout", title: "Knees", blocks: [{ label: "A", steps: [{ exercise_id: exercise("plank").id, duration_seconds: 30 }] }] }],
      [:patch, "/api/workouts/#{own_workout.id}", { title: "Mine again" }],
      [:put, "/api/workouts/#{own_workout.id}", { title: "Mine", blocks: [{ label: "A", steps: [{ exercise_id: exercise("plank").id, duration_seconds: 40 }] }] }],
      [:post, "/api/workouts/#{own_workout.id}/duplicate", { title: "Copy" }],
      [:post, "/api/sessions", { workout_id: strength.id, date: "2026-11-12" }],
      [:patch, "/api/sessions/#{planned.id}", { note: "Legs" }],
      [:post, "/api/sessions/#{planned.id}/sets", { step_id: step.id, set_number: 1, reps: 8, weight: { value: 20, unit: "lb" } }],
      [:post, "/api/sessions/#{planned.id}/complete", { rpe: 6 }],
      [:patch, "/api/sessions/#{done.id}/completion", { rpe: 6 }],
      [:post, "/api/activities", { date: "2026-11-10", sport: "run", moving_seconds: 1800 }],
      [:patch, "/api/activities/#{activity.id}", { title: "Loop" }],
      [:post, "/api/plan_changes/#{change.id}/undo", { today: "2026-11-11" }],
      [:post, "/api/routines", { sport: "run", weekdays: [3] }],
      [:patch, "/api/routines/#{routine.id}", { title: "Long run" }],
      [:put, "/api/routines/#{routine.id}/days/2026-11-14", { status: "confirmed" }],
      [:post, "/api/goals", { title: "Ski season" }],
      [:patch, "/api/goals/#{goal.id}", { title: "Stronger knees" }],
      [:post, "/api/coach/notes", { kind: "note", body: "Rest well" }],
      [:patch, "/api/coach/notes/#{note.id}", { resolved: false }],
      [:post, "/api/coach/tidy", { before: "2026-11-11" }],
      [:post, "/api/coach/seen", { until: "2026-11-11T12:00:00Z" }]
    ]
  end

  def operation(method, path)
    RequestHelpers::OPERATIONS.find { |pattern, _| pattern.match?(path) }.last.fetch(method.to_s)
  end

  # Notes a request answered otherwise, so a test lists them all at once.
  def must_answer_in_shape(label)
    status = last_response.status
    return if status < 400
    return problems << "#{label} answered #{status}: #{last_response.body}" if status >= 500

    error = JSON.parse(last_response.body)["error"]
    problems << "#{label} answered #{status} without the error shape" unless error["code"].is_a?(String) && error["message"].is_a?(String)
  rescue JSON::ParserError, NoMethodError, TypeError
    problems << "#{label} answered #{status} without the error shape"
  end

  let(:problems) { [] }
  after { _(problems).must_be_empty problems.join("\n") }

  it "covers every route that takes a body" do
    covered = requests.map { |method, path, _| [method.to_s, RequestHelpers::OPERATIONS.find { |pattern, _| pattern.match?(path) }.first] }
    described = RequestHelpers::OPERATIONS.flat_map do |pattern, operations|
      operations.filter_map { |method, op| [method, pattern] if op.is_a?(Hash) && self.class.schema_for(op)&.dig("properties")&.any? }
    end
    # PUT and PATCH name the same action where both are routed.
    missing = described - covered
    missing.reject! { |method, pattern| %w[put patch].include?(method) && covered.include?([(%w[put patch] - [method]).first, pattern]) }
    _(missing.map { |method, pattern| "#{method.upcase} #{pattern.source}" }).must_be_empty
  end

  it "answers a wrong type in any documented field with the error shape" do
    requests.each do |method, path, body|
      fields = self.class.schema_for(operation(method, path))["properties"].keys
      fields.each do |field|
        WRONG.each do |value|
          send(:"#{method}_json", path, body.merge(field.to_sym => value))
          must_answer_in_shape("#{method.upcase} #{path} #{field}: #{value.inspect}")
        end
      end
    end
  end

  it "answers a wrong type inside a set's weight and target" do
    [20, "20", [20], { value: { a: 1 } }, { value: 20, unit: { a: 1 } }].each do |weight|
      post_json "/api/sessions/#{planned.id}/sets", step_id: step.id, set_number: 1, reps: 8, weight: weight
      must_answer_in_shape("weight #{weight.inspect}")
      post_json "/api/sessions/#{planned.id}/sets", step_id: step.id, set_number: 1, reps: 8, target: { reps: 8, weight: weight }
      must_answer_in_shape("target weight #{weight.inspect}")
    end
  end

  it "answers a wrong type inside a workout's blocks and steps" do
    step = { exercise_id: exercise("plank").id, duration_seconds: 30 }
    blocks = WRONG.map { [it] } + WRONG.map { [{ label: "A", steps: it }] } + WRONG.map { [{ label: "A", steps: [it] }] }
    blocks += %i[label rounds rest_seconds].product(WRONG).map { |key, value| [{ label: "A", steps: [step], key => value }] }
    blocks += %i[exercise_id reps duration_seconds tempo weight side].product(WRONG).map { |key, value| [{ label: "A", steps: [step.merge(key => value)] }] }
    blocks.each do |value|
      post_json "/api/workouts", kind: "workout", title: "Knees", blocks: value
      must_answer_in_shape("blocks #{value.inspect}")
    end
  end

  it "answers an object, an array or invalid UTF-8 in a query parameter" do
    RequestHelpers::SPEC["paths"].each do |path, operations|
      operations.each do |method, op|
        next unless op.is_a?(Hash) && %w[get delete].include?(method)

        names = (op["parameters"] || []).reject { it["in"] == "path" }.map { it["name"] }
        next if names.empty?

        concrete = path.sub("/api/sessions/{id}", "/api/sessions/#{planned.id}").sub("/api/routines/{id}", "/api/routines/#{routine.id}")
                       .sub("{date}", "2026-11-14")
        names.each do |name|
          ["#{name}[a]=b", "#{name}[]=1", "#{name}=%FF%FE"].each do |query|
            send(method, "#{concrete}?#{query}")
            must_answer_in_shape("#{method.upcase} #{concrete}?#{query}")
          end
        end
      end
    end
  end

  it "answers a path or a JSON string that isn't UTF-8" do
    get "/api/sessions/%FF"
    must_answer_in_shape("GET /api/sessions/%FF")
    _(last_response.status).must_equal 404

    post "/api/coach/notes", "{\"kind\":\"note\",\"body\":\"bad \xFF byte\"}".b, RequestHelpers::JSON_ENV
    must_answer_in_shape("a note with a raw \\xFF")
    _(last_response.status).must_equal 201
  end

  it "answers a body that is not JSON, or not an object" do
    ["{", "\xFF".b, "[1, 2]", "7", "\"text\""].each do |raw|
      post "/api/sessions", raw, RequestHelpers::JSON_ENV
      must_answer_in_shape("body #{raw.inspect}")
    end
  end

  it "answers a wrong type sent to sign-in and the account routes" do
    someone = create_user("someone")
    sign_in(user)
    {
      "/api/auth/change-password" => { password: "wrong password", new_password: "a brand new password", sign_out_others: false },
      "/api/auth/login" => { username: someone.username, password: "wrong password" },
      "/api/auth/create-account" => { username: "newcomer", password: "a long password", invite: "x" * 43 },
      "/api/auth/invite-check" => { invite: "x" * 43 }
    }.each do |path, body|
      sign_out! if path == "/api/auth/login"
      body.each_key do |field|
        WRONG.each do |value|
          # Past the throttles, so each try reaches the route.
          [Auth::Throttles::SIGN_INS, Auth::Throttles::ACCOUNTS, Auth::Throttles::PASSWORD_CHANGES].each(&:reset!)
          post_json path, body.merge(field => value)
          must_answer_in_shape("POST #{path} #{field}: #{value.inspect}")
        end
      end
    end
  end

  it "refuses an object where a yes or no is asked, rather than reading it as yes" do
    patch_json "/api/equipment/#{equipment("dumbbell").id}", owned: {}
    _(last_response.status).must_equal 400
    _(json["error"]["fields"]).must_equal({ "owned" => ["must be true or false"] })

    post_json "/api/examples/cycle-1/import", copy: {}
    _(last_response.status).must_equal 400
  end

  it "answers a bug in the one shape, as server_error" do
    version = AppVersion.method(:version)
    AppVersion.define_singleton_method(:version) { raise "boom" }
    get "/api/version"

    _(last_response.status).must_equal 500
    _(json).must_equal({ "error" => { "code" => "server_error", "message" => "Something went wrong on the server; the log says what" } })
  ensure
    AppVersion.define_singleton_method(:version, version)
  end
end
