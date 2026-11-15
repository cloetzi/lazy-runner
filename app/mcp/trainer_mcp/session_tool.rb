module TrainerMcp
  # What the calendar tools share: a session as they answer with it.
  class SessionTool < Tool
    # What every calendar tool keeps in mind.
    CALENDAR = <<~TEXT.squish
      A day can hold several sessions, in `position` order (1 first). A day without one is a rest day: rest days need
      no entry. A planned session whose day has gone by reads as `missed`: a signal of how the plan fits the user's
      life, not an error to clean up. A session runs its workout as the workout is when it starts, so changing a
      workout changes every future session of it.
    TEXT

    PARTS = {
      type: %w[array null], items: { type: "string", enum: Workout::KINDS },
      description: "For a main workout, the parts to run: [\"warmup\", \"workout\", \"cooldown\"] (all of them) when left out, " \
                   "or such as [\"workout\", \"cooldown\"] to skip the warm-up after a run."
    }.freeze

    # A session the user planned is moved or removed only with a reason,
    # which goes on the change (PlanChange) while their note stays.
    def self.reason!(session, reason, change, date: nil)
      # One no longer planned can't change: the model says so.
      return if session.created_by == "llm" || session.status != "planned" || reason.to_s.strip.present?
      # A new place on its own day is no change to the plan.
      return if change == "move" && (date.nil? || date.to_s == session.date.iso8601)

      raise Problem, "session #{session.id} is the user's: give a `reason` for the #{change}, which they see with it"
    end

    def self.find_session(id)
      Session.eager(:completion, :workout).with_pk(id) || raise(Problem, "no session #{id}; list_sessions lists them")
    end

    # A session in an answer: its day and place, how it reads, its workout,
    # the minutes it runs with its parts and, once finished, how it felt.
    # `minutes` keeps what is worked out per workout and parts, for a list.
    def self.shown(session, minutes = {})
      compact(
        id: session.id, date: session.date.iso8601, position: session.position, status: session.shown_status,
        created_by: session.created_by, agent_name: session.agent_name, note: session.note, parts: session.part_kinds,
        workout: session.workout.then { { id: it.id, title: it.title, kind: it.kind, source: it.source, archived: (true if it.archived?) } },
        minutes: minutes[[session.workout_id, session.part_kinds]] ||= session.parts.sum(&:estimated_minutes),
        completion: session.completion&.as_json&.except(:finished_at)
      )
    end

    # The sessions on a day, in order, as `shown` gives them.
    def self.day(date)
      minutes = {}
      Session.eager(:completion, :workout).where(date:).in_order.all.map { shown(it, minutes) }
    end

    def self.parts(list)
      Workout.part_kinds(list)
    rescue ArgumentError => error
      raise Problem, error.message
    end
  end
end
