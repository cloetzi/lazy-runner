module TrainerMcp
  # A tool: `answer` returns what the tool says, which goes back as compact
  # JSON text. A mistake in the arguments (an unknown slug, a bad date, a
  # workout that doesn't hold together) comes back as a tool error that says
  # what to fix, so the assistant can correct itself; anything else is a bug
  # and is logged.
  #
  # Every input schema refuses arguments it doesn't name
  # (`additionalProperties: false`), and the SDK checks the arguments against
  # it before `answer` is called.
  class Tool < MCP::Tool
    # The arguments can't be answered as given.
    class Problem < StandardError; end
    # A call without a verified token's user: a bug, since the transport
    # refuses those.
    class Unauthenticated < StandardError; end

    READ_ONLY = { read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false }.freeze
    # A write that adds or changes something and takes nothing away.
    WRITES = { read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: false }.freeze
    # A write that replaces or removes something.
    REPLACES = WRITES.merge(destructive_hint: true).freeze

    # What the app refuses, put to the assistant as a tool error with the
    # model's own message: a record that doesn't validate, a workout that is
    # read-only or being trained, a session no longer planned. The API's
    # rescue_from list (ApplicationController) names the same errors.
    REFUSALS = [Problem, Record::NotFound, Workout::ReadOnly, Workout::Running, Session::Settled, Routine::Settled, Example::AlreadyImported, Goal::NotProposed, CoachNote::NotAConcern, PlanChange::NotUndoable,
               Record::UserOnly, CoachNote::DailyLimit].freeze

    def self.inherited(tool)
      super
      tool.input_schema({})
    end

    # Every schema refuses what it doesn't name.
    def self.input_schema(value = nil)
      return super() if value.nil?

      super({ properties: {} }.merge(value, additionalProperties: false))
    end

    # The tool answers for the user the token belongs to: the models read
    # them as Current.user while it runs, as they do in an API request, and
    # `answer` gets them as `user:` when it asks for one. What it writes is
    # signed with the token's name (Current.agent_name, from TokenVerifier).
    def self.call(server_context: nil, **arguments)
      user = user_for(server_context)
      arguments = arguments.merge(user:) if answer_takes_user?
      agent_name = server_context&.auth_info&.claims&.dig("agent_name")
      Current.set(user:, agent_name:, plan_batch: nil) { text(JSON.generate(answer(**arguments))) }
    rescue *REFUSALS => error
      text(error.message, error: true)
    rescue Sequel::ValidationFailed => error
      text(error.errors.full_messages.join("; "), error: true)
    rescue WorkoutStructure::Invalid => error
      text("#{error.message}. Nothing was changed; fix these and send the whole workout again.", error: true)
    rescue Sequel::UniqueConstraintViolation
      text("conflicts with a record written meanwhile; read it again and retry", error: true)
    end

    # The user whose token the transport verified (TokenVerifier). There is
    # always one: /mcp lets nobody in without a token.
    def self.user_for(server_context)
      id = server_context&.auth_info&.subject
      (id && User.with_pk(id.to_i)) || raise(Unauthenticated, "no user for this request")
    end

    def self.answer_takes_user?
      return @answer_takes_user if defined?(@answer_takes_user)

      @answer_takes_user = method(:answer).parameters.any? { |_, name| name == :user }
    end

    def self.text(text, error: false)
      MCP::Tool::Response.new([{ type: "text", text: }], error:)
    end

    # An exercise by slug or id, retired ones included (history may name them).
    def self.find_exercise(key)
      id = Record.id(key)
      exercise = Exercise.eager(:equipment, :remembered).first(id ? { id: } : { slug: key.to_s })
      exercise || raise(Problem, "no exercise #{key.inspect}; search_exercises lists the slugs")
    end

    def self.find_workout(id)
      Workout.with_pk(id) || raise(Problem, "no workout #{id}; list_workouts lists them")
    end

    # A workout the assistant may change: any not archived, as
    # Workout#read_only_reason decides.
    def self.editable_workout(id)
      workout = find_workout(id)
      reason = workout.read_only_reason
      raise Problem, reason if reason

      workout
    end

    # A workout the user made is edited or archived only with a reason,
    # which they see with the change.
    def self.workout_reason!(workout, reason, change)
      return if workout.source == "llm" || reason.to_s.strip.present?

      raise Problem, "#{workout.title} is the user's workout: give a `reason` for the #{change}, which they see with it"
    end

    # The server's day and its weekday, which answers start with, so the
    # assistant needn't work out what day of the week it is.
    def self.today_and_weekday
      day = Time.zone.today
      { today: day.iso8601, weekday: day.strftime("%A") }
    end

    # A date range as the API reads one (see DateRange).
    def self.days(from, to, back: nil)
      DateRange.resolve(from, to, back:)
    rescue DateRange::Invalid => error
      raise Problem, error.message
    end

    # A remembered weight in `unit`, as set_exercise_weight takes one: 0 for
    # no weight; nil with nothing remembered.
    def self.remembered_weight(remembered, unit)
      return unless remembered

      remembered.none? ? { value: 0.0, unit: } : Weights.convert(remembered.weight, unit)
    end

    # Drops nil values from hashes, all the way down, to keep answers short.
    def self.compact(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), out| out[key] = compact(item) unless item.nil? }
      when Array then value.map { compact(it) }
      else value
      end
    end
  end
end
