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

    def self.find_session(id)
      Session.eager(:completion, :workout).with_pk(id) || raise(Problem, "no session #{id}; list_sessions lists them")
    end

    # A session in an answer: its day and place, how it reads, its workout,
    # the minutes it runs with its parts and, once finished, how it felt.
    # `minutes` keeps what is worked out per workout and parts, for a list.
    def self.shown(session, minutes = {})
      compact(
        id: session.id, date: session.date.iso8601, position: session.position, status: session.shown_status,
        created_by: session.created_by, note: session.note, parts: session.part_kinds,
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
