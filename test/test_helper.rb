# frozen_string_literal: true

ENV["RAGE_ENV"] = "test"

require "bundler/setup"
# Before the app loads, so every file of it is counted. Reported, with no
# threshold: a number to watch, not a gate.
if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    add_filter %w[/test/ /config/ /db/]
  end
end
require "minitest/autorun"
require "rack/test"
require "json"
require "active_support/testing/time_helpers"
require_relative "../config/application"
require_relative "openapi_schema"

# Booting migrated storage/test.sqlite3 (config/initializers/database.rb).
SeedLoader.load!

module TestUsers
  PASSWORD = "correct horse battery"
  # What a test user owns: everything in the catalogue (the generic weight
  # comes with the dumbbells), with these weights.
  WEIGHTS = { "dumbbell" => [10, 20], "kettlebell" => [40] }.freeze

  # Owns the gear and imports every example program, as a user would on the
  # Equipment page and in Settings.
  def self.equip!(user)
    Current.set(user:) do
      Equipment.current.where(any_weight: false).all.each do |item|
        UserEquipment.create(equipment: item, owned: true, weights: WEIGHTS.fetch(item.slug, []))
      end
      Example.all.each(&:import!)
    end
  end

  def self.create(username)
    AuthApp.rodauth.create_account(login: username, password: PASSWORD)
    User.first!(username:)
  end

  # The user tests run as, made afresh on every run from the examples as they
  # are now.
  User.where(username: "runner").delete
  RUNNER_ID = create("runner").tap { equip!(it) }.id
end

# The app's fibers take turns on its one connection; tests key connections
# by thread, so request fibers, which run on the test's thread (see below),
# share the test's connection and transaction and see its records. So a
# fiber that waits on another fiber's query inside a transaction passes here
# but waits on the connection in the app: don't.
module ThreadConnections
  def current = Thread.current
end
Sequel.extend(ThreadConnections)

# Every test runs inside a transaction that is rolled back afterwards, so the
# seeded library is the same at the start of each test. The outermost
# transaction the code under test opens becomes a savepoint, rolled back on
# its own as it would be in the app; ones nested in it join it, as they do
# in the app. after_commit hooks never run here, and transactions don't
# begin IMMEDIATE.
module TransactionalTests
  def run(...)
    Auth::Throttles.reset!
    Oidc.cache.clear
    UserScopeTripwire.reset!
    DB.transaction(rollback: :always, auto_savepoint: true) do
      # Model code a test calls runs as the test's user, as a request would.
      Current.set(user: User.with_pk(TestUsers::RUNNER_ID), gear_units: nil) { super }
    end
  end
end

# Every query a request makes on a table of one user's records names
# user_id; one that doesn't (an `everyone` or a raw DB query) could read or
# change another user's. The
# check runs only while a request is answered (RequestHelpers::APP), so a
# test's own lookups are free, and a test that made such a query fails. It
# reads the SQL as text, so it is a tripwire, not a proof: a query naming
# user_id anywhere (in a subquery on another table, say) passes, and blocks,
# steps and completions, which belong to a user through their parent, are
# left to the isolation tests (test/requests/isolation_test.rb).
module UserScopeTripwire
  TABLES = %w[programs workouts sessions set_logs exercise_weights settings user_equipment api_tokens user_identities activities goals
              coach_notes routines plan_changes].freeze
  # Asked on purpose of everyone's: the token a request's secret is, and
  # the identity an OIDC sign-in vouched for.
  ALLOWED = [
    /\bFROM `api_tokens` WHERE \(`digest` = '[0-9a-f]+'\)/,
    /\bFROM `user_identities` WHERE \(\(`issuer` = '[^']*'\) AND \(`subject` = '[^']*'\)\)/
  ].freeze
  QUERY = /\A\([\d.]+s\) (SELECT|UPDATE|DELETE|WITH)\b/
  TABLE = /\b(?:FROM|JOIN|UPDATE)\s+`(?:#{TABLES.join("|")})`/

  @found = []

  class << self
    attr_reader :found

    def reset! = @found = []

    def during
      outer = Thread.current.thread_variable_get(:user_scope_tripwire)
      Thread.current.thread_variable_set(:user_scope_tripwire, true)
      yield
    ensure
      Thread.current.thread_variable_set(:user_scope_tripwire, outer)
    end

    # Sequel's logger interface.
    %i[debug info warn error].each do |level|
      define_method(level) do |message|
        next unless Thread.current.thread_variable_get(:user_scope_tripwire)

        next unless message.match?(QUERY) && message.match?(TABLE) && !message.include?("user_id")

        @found << message.sub(/\A\([\d.]+s\) /, "") unless ALLOWED.any? { message.match?(it) }
      end
    end
  end
end
DB.loggers << UserScopeTripwire

# Sets environment variables for the block (nil unsets one), then puts them
# back as they were.
module EnvHelpers
  def with_env(values)
    saved = values.keys.to_h { [it, ENV.fetch(it, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved&.each { |key, value| ENV[key] = value }
  end
end

module TripwireCheck
  def after_teardown
    super
    _(UserScopeTripwire.found).must_be_empty "queries without user_id on per-user tables"
  end
end

# Rage runs each request in a fiber on the server's scheduler, which does not
# exist in tests. Run the fiber synchronously instead, as Rage's RSpec helper does.
module SynchronousFibers
  def schedule(&)
    fiber = Fiber.new(blocking: true) do
      Fiber.current.__set_id
      Fiber.current.__set_result(yield)
    end
    fiber.resume
    fiber
  end

  def await(fibers)
    Array(fibers).map(&:__get_result)
  end
end
Fiber.singleton_class.prepend(SynchronousFibers)

module RequestHelpers
  include Rack::Test::Methods

  TEST_PASSWORD = TestUsers::PASSWORD

  RACK_APP = Rack::Builder.parse_file(Rage.root.join("config.ru").to_s).then { |app| app.is_a?(Array) ? app.first : app }
  APP = ->(env) { UserScopeTripwire.during { RACK_APP.call(env) } }

  # Rage only parses a body when the server says there is one.
  JSON_ENV = { "CONTENT_TYPE" => "application/json", "IODINE_HAS_BODY" => true }.freeze

  def app = APP

  def json = JSON.parse(last_response.body)

  def post_json(path, body = {}) = post(path, JSON.generate(body), JSON_ENV)

  def put_json(path, body = {}) = put(path, JSON.generate(body), JSON_ENV)

  def patch_json(path, body = {}) = patch(path, JSON.generate(body), JSON_ENV)
end

# Runs the block with the server's time zone set, as TZ sets it on boot.
# Request fibers don't see Time.use_zone, so this sets the default zone.
module TimeZoneHelpers
  def with_time_zone(name)
    default = Time.zone_default
    Time.zone_default = Time.find_zone!(name)
    yield
  ensure
    Time.zone_default = default
  end
end

# Every API response a request test gets is checked against the API
# description: its status must be one the action describes, and its body must
# fit the schema described for that status (see test/openapi_schema.rb).
module RequestHelpers
  SPEC = JSON.parse(JSON.generate(Rage::OpenAPI.build))
  SCHEMA = OpenAPISchema.new(SPEC)
  # Literal paths first, so /api/history/exercises is not taken for a path with an id.
  OPERATIONS = SPEC["paths"].sort_by { it.first.count("{") }.map do |path, operations|
    [Regexp.new("\\A#{Regexp.escape(path).gsub(/\\\{\w+\\\}/, "[^/]+")}\\z"), operations]
  end

  %i[get post put patch delete].each do |verb|
    define_method(verb) do |*args, **options, &block|
      prepare_request
      super(*args, **options, &block).tap { must_match_description }
    end
  end

  # Requests come from the app's own pages (see the CSRF check in
  # lib/auth/csrf.rb), signed in as `user` unless a test signs out first.
  # A test sets @fetch_site to send another Sec-Fetch-Site, or nil for none.
  def prepare_request
    header "Sec-Fetch-Site", instance_variable_defined?(:@fetch_site) ? @fetch_site : "same-origin"
    return if @signed_out || @signed_in || @signing_in

    sign_in(user)
  end

  def sign_in(user, password: TEST_PASSWORD)
    @signing_in = true
    @signed_out = false
    post_json("/api/auth/login", username: user.username, password:)
    _(last_response.status).must_equal 200, last_response.body
    @user = user
    @signed_in = true
  ensure
    @signing_in = false
  end

  # Later requests are made with no session at all (a new cookie jar).
  def sign_out!
    clear_cookies
    @signed_in = false
    @signed_out = true
  end

  private

  # What AuthApp, in front of the app, answers for any route: a 401 without a
  # session or a valid token, a 403 for a write from another site or without
  # a JSON body, or for an API token on the account's routes or one
  # without REST access.
  def answered_by_auth_app(status)
    return { "$ref" => "#/components/responses/Unauthorized" } if status == "401"
    if status == "409" && JSON.parse(last_response.body).dig("error", "code") == "user_mismatch"
      return { "$ref" => "#/components/responses/Conflict" }
    end

    refusal = JSON.parse(last_response.body).dig("error", "message") if status == "403"
    return unless [Auth::Csrf::REFUSED, Auth::Csrf::NOT_JSON, Auth::Token::REFUSED, Auth::Token::MCP_ONLY].include?(refusal)

    { "$ref" => "#/components/responses/Forbidden" }
  end

  def must_match_description
    path = last_request.path
    method = last_request.request_method.downcase
    # A server error is a bug, which no description covers.
    # Rodauth's routes under /api/auth are not Rage routes; docs/api.md describes them.
    return if !path.start_with?("/api/") || path.start_with?("/api/openapi", "/api/auth/") || last_response.server_error?

    operation = OPERATIONS.find { |pattern, _| pattern.match?(path) }&.last&.dig(method)
    _(operation).wont_be_nil "#{method.upcase} #{path} is not in the API description"
    status = last_response.status.to_s
    response = operation["responses"][status] || answered_by_auth_app(status)
    _(response).wont_be_nil "#{method.upcase} #{path} answered #{status}, which its description leaves out"

    response = SPEC.dig(*response["$ref"].delete_prefix("#/").split("/")) if response["$ref"]
    schema = response.dig("content", "application/json", "schema")
    return _(last_response.body).must_be_empty if status == "204"

    _(schema).wont_be_nil "#{method.upcase} #{path} #{status} has no body schema"
    problems = SCHEMA.errors(JSON.parse(last_response.body), schema)
    _(problems).must_be_empty "#{method.upcase} #{path} #{status} does not match its description"
  end
end

module UserHelpers
  # The user a test runs as, the install's owner (TestUsers), unless a
  # request test signs in as another.
  def user = @user ||= Current.user

  # Another user, made as an account is, owning what the test user owns and
  # with the example programs imported; `bare`, with nothing of their own.
  def create_user(username, password: TestUsers::PASSWORD, bare: false)
    AuthApp.rodauth.create_account(login: username, password:)
    User.first!(username:).tap { TestUsers.equip!(it) unless bare }
  end
end

# The seeded records, by slug: the library's, and the signed-in user's
# copy of the example programs (by their example slug).
module SeedHelpers
  def workout(slug) = Workout.first!(example_slug: slug)

  def exercise(slug) = Exercise.first!(slug:)

  def equipment(slug) = Equipment.first!(slug:)

  # What the test user has of an item (UserEquipment).
  def inventory(slug) = UserEquipment.first!(equipment: equipment(slug))

  def step_for(workout_slug, exercise_slug)
    workout(workout_slug).blocks.flat_map(&:steps).find { it.exercise.slug == exercise_slug }
  end
end

module LoggingHelpers
  # A session of a workout (an imported example's slug, or a Workout) on a date
  # ("2026-10-19" or a Date). One planned is planned as on that day, so it
  # can be missed by now.
  def session_on(date, status = "done", workout: "cycle-1-workout-1", **attrs)
    workout = Workout.first!(example_slug: workout) unless workout.is_a?(Workout)
    Session.create(workout:, date:, status:, today: DateRange.date(date, :date), **attrs).tap { it.today = nil }
  end

  # Logs every planned set of an exercise in a session, overriding attributes.
  def log_all(session, exercise_slug, **attrs)
    session.parts.flat_map(&:blocks).each do |block|
      block.steps.select { it.exercise.slug == exercise_slug }.each do |step|
        (1..block.rounds).each do |round|
          (step.per_side ? %w[left right] : [nil]).each do |side|
            SetLog.create(
              session:, step:, set_number: round, side:, reps: step.reps,
              weight_value: step.weight_value, weight_unit: step.weight_unit, **attrs
            )
          end
        end
      end
    end
  end

  def finish(session, feedback)
    Completion.create(session:, finished_at: Time.now, feedback:)
    session.update(status: "done")
  end
end

class Minitest::Spec # rubocop:disable Style/ClassAndModuleChildren -- reopened, not defined
  prepend TransactionalTests
  include TripwireCheck
  include EnvHelpers
  include ActiveSupport::Testing::TimeHelpers
  include TimeZoneHelpers
  include UserHelpers
  include SeedHelpers
  include LoggingHelpers
end
