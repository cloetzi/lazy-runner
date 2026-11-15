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

  # The signed-in user, from the session AuthApp checked in front of the
  # app (lib/auth_app.rb). AuthApp has already answered 401 for a route
  # that needs one when there is none.
  before_action do
    id = request.env["lazy_runner.user_id"]
    Current.user = id && User.with_pk(id)
    # Signed in with an API token: its name, for what an agent writes
    # (`created_by: llm`, Record::AgentSigned).
    Current.agent_name = request.env["lazy_runner.agent_name"]
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

  rescue_from Forbidden, Workout::ReadOnly do |error|
    render_error :forbidden, "forbidden", error.message
  end

  rescue_from Session::Settled, Routine::Settled, Workout::Running, Goal::NotProposed, CoachNote::NotAConcern do |error|
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

  private

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
    given && (server - 1..server + 1).cover?(given) ? given : server
  end

  # Which parts of a framed workout to run: "warmup,cooldown" or a list of
  # kinds, nil for all of them.
  def parts_param
    Workout.part_kinds(params[:parts])
  rescue ArgumentError => error
    raise BadRequest.new(error.message, fields: { parts: [error.message] })
  end

  # A parameter the request can't do without, such as the id of what it
  # acts on: missing is a 400, not a 404 for an id nobody sent.
  def required!(key)
    return params[key] if params[key].present?

    raise BadRequest.param(key, "is required")
  end
end
