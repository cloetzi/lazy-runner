# frozen_string_literal: true

# Every error has one shape, so a client (the PWA, or an agent through MCP)
# can tell what failed without parsing English:
#
#   { "error": { "code": "invalid", "message": "Reps must be greater than 0",
#                "fields": { "reps": ["must be greater than 0"] } } }
#
# `code` is one of the codes in config/openapi_components.yml (Error).
# A not_found error names the `resource` and `id` it looked for.
class ApplicationController < RageController::API
  # @title The Lazy Runner API
  # @version 1

  # A request that can't be read as asked. `fields` names the parameters at
  # fault, each with what is wrong with it.
  class BadRequest < StandardError
    attr_reader :fields

    # One parameter at fault: "days must be ..." with the problem under its key.
    def self.param(key, problem)
      new("#{key} #{problem}", fields: { key => [problem] })
    end

    def initialize(message, fields: nil)
      super(message)
      @fields = fields
    end
  end

  class Forbidden < StandardError; end

  # What SQLite answers when the database can't take a write just now: held
  # by another process past the busy timeout, or the disk full or failing.
  # The request may well succeed later.
  UNAVAILABLE = [SQLite3::BusyException, SQLite3::LockedException, SQLite3::FullException, SQLite3::IOException].freeze

  # A bug: logged, and answered in the one shape. Declared first, so every
  # handler below comes before it (Rage tries the last declared first). A
  # database that can't be written for now is a 503 `unavailable` instead,
  # so a client retries rather than taking its change for the cause (the
  # PWA's outbox sets aside a change that keeps getting a `server_error`).
  rescue_from StandardError do |error|
    Rage.logger.error("#{error.class}: #{error.message}\n#{Array(error.backtrace).first(10).join("\n")}")
    if UNAVAILABLE.any? { (error.cause || error).is_a?(it) }
      render_error :service_unavailable, "unavailable", "The database can't save anything at the moment; try again later"
    else
      render_error :internal_server_error, "server_error", "Something went wrong on the server; the log says what"
    end
  end

  # Text that isn't UTF-8 (a stray %FF in the path or query, a raw byte in
  # a JSON string) is read with its bad bytes replaced, once, so nothing
  # further in trips over it.
  before_action do
    ApplicationController.scrub!(params)
  end

  # The signed-in user, from the session AuthApp checked in front of the
  # app (lib/auth/gate.rb). The gate has already answered 401 for a route
  # that needs one when there is none.
  before_action do
    id = request.env["lazy_runner.user_id"]
    Current.user = id && User.with_pk(id)
    # Signed in with an API token: its name, for what an agent writes
    # (`created_by: llm`, Record::AgentSigned).
    Current.agent_name = request.env["lazy_runner.agent_name"]
    # The plan changes one request makes share a batch (PlanChange).
    Current.plan_batch = nil
  end

  # A user given a temporary password (the owner reset theirs) chooses
  # their own before anything else. /api/me still answers, to say so.
  before_action :password_chosen!

  # "Session 9 not found" (Record.find!), or a message raised in the app.
  rescue_from Record::NotFound do |error|
    render_error :not_found, "not_found", error.message, resource: error.resource, id: error.id
  end

  rescue_from Sequel::ValidationFailed do |error|
    errors = error.errors
    render_error :unprocessable_content, "invalid", errors.full_messages.join(", "), fields: errors.to_h
  end

  rescue_from Sequel::UniqueConstraintViolation do
    render_error :conflict, "conflict", "conflicts with an existing record; fetch it and try again"
  end

  rescue_from BadRequest do |error|
    render_error :bad_request, "bad_request", error.message, fields: error.fields
  end

  rescue_from DateRange::Invalid do |error|
    render_error :bad_request, "bad_request", error.message, fields: { error.field => [error.problem] }
  end

  rescue_from Forbidden, Workout::ReadOnly, Record::UserOnly do |error|
    render_error :forbidden, "forbidden", error.message
  end

  rescue_from Session::Settled, Routine::Settled, Workout::Running, Goal::NotProposed, CoachNote::NotAConcern, PlanChange::NotUndoable,
              CoachNote::DailyLimit do |error|
    render_error :conflict, "conflict", error.message
  end

  rescue_from User::Refused, UserIdentity::Refused do |error|
    render_error :conflict, "conflict", error.message
  end

  rescue_from Activity::EntryInvalid do |error|
    render_error :unprocessable_content, "invalid", error.message, fields: error.fields
  end

  rescue_from Example::AlreadyImported do |error|
    render_error :conflict, "already_imported", error.message
  end

  rescue_from WorkoutStructure::Invalid do |error|
    render_error :unprocessable_content, "invalid", error.message, fields: error.fields
  end

  # Replaces bytes that aren't UTF-8 in every string of `value`, a hash or
  # array of params, in place.
  # Writes only what changes: most params hold nothing to scrub.
  def self.scrub!(value)
    case value
    when Hash
      value.each { |key, item| (clean = scrub!(item)).equal?(item) || (value[key] = clean) }
    when Array
      value.each_with_index { |item, index| (clean = scrub!(item)).equal?(item) || (value[index] = clean) }
    when String then value.valid_encoding? ? value : value.scrub("\uFFFD")
    else value
    end
  end

  private

  # A parameter that must be text when it is sent: nil when it isn't,
  # else the string; anything else (an object, a number) is a 400.
  def string_param(key)
    value = params[key]
    return value if value.nil? || value.is_a?(String)

    raise BadRequest.param(key, "must be text")
  end

  # A whole number given as one or as its digits; nil when not sent.
  def integer_param(key)
    value = params[key]
    return if value.nil? || value == ""
    return value if value.is_a?(Integer)
    return value.to_i if value.is_a?(String) && value.match?(/\A-?\d+\z/)

    raise BadRequest.param(key, "must be a whole number")
  end

  # A record's id, as a number or its digits; nil when not sent. Anything
  # else is no record's id: a 404, as for an id there is no record of.
  def id_param(key)
    value = params[key]
    return if value.nil? || value == ""

    Record.id(value) || raise(Record::NotFound.new(key.to_s.delete_suffix("_id").camelize, value.is_a?(String) ? value : value.to_json))
  end

  # true or false, given as one or as text ("true", "0", ...); nil when not
  # sent. An object or a number is a 400 rather than true.
  def boolean_param(key)
    value = params[key]
    return Record.boolean(value) if value.nil? || value == true || value == false || value.is_a?(String)

    raise BadRequest.param(key, "must be true or false")
  end

  # An object (a JSON one), or nil when not sent.
  def hash_param(key)
    value = params[key]
    return if value.nil?
    return value if value.is_a?(Hash)

    raise BadRequest.param(key, "must be an object")
  end

  # Rodauth for this request (lib/auth_app.rb): its session and devices.
  def rodauth = request.env.fetch("rodauth")

  def password_chosen!
    return unless Current.user&.password_change_required

    render_error :unauthorized, "password_change_required", "Choose a new password first: the one you signed in with was temporary"
  end

  # For the routes that manage the install: users and invites.
  def owner_only!
    raise Forbidden, "Only the owner can manage users and invites" unless Current.user!.owner
  end

  def render_error(status, code, message, **details)
    render json: { error: { code:, message:, **details.compact } }, status:
  end

  # The client may send its own local date. Without one, today is the day in
  # the server's time zone (TZ, see config/initializers/time_zone.rb).
  def date_param(key = :date)
    return Time.zone.today if params[key].blank?

    DateRange.date(params[key], key)
  end

  # The day a planning request counts from: the client's own `today` (its
  # local date) when it is within a day of the server's, which covers time
  # zones and a change sent just after midnight; else the server's today.
  def client_today
    server = Time.zone.today
    given = DateRange.date(params[:today], :today) if params[:today].present?
    given && ((server - 1)..(server + 1)).cover?(given) ? given : server
  end

  # Which parts of a framed workout to run: "warmup,cooldown" or a list of
  # kinds, nil for all of them.
  def parts_param
    Workout.part_kinds(params[:parts])
  rescue ArgumentError => error
    raise BadRequest.new(error.message, fields: { parts: [error.message] })
  end

  # A time the client sent (ISO 8601), never later than now; nil when not
  # given.
  def client_time(key)
    return if params[key].blank?

    [Time.iso8601(params[key].to_s), Time.now].min
  rescue ArgumentError
    raise BadRequest.param(key, "must be a time as ISO 8601")
  end

  # A parameter the request can't do without, such as the id of what it
  # acts on: missing is a 400, not a 404 for an id nobody sent.
  def required!(key)
    return params[key] if params[key].present?

    raise BadRequest.param(key, "is required")
  end
end
