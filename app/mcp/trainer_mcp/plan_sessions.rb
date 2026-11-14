module TrainerMcp
  class PlanSessions < SessionTool
    description <<~TEXT.squish
      Put workouts on calendar days, from today on: up to #{Session::PLAN_LIMIT} sessions in one call, all or
      nothing. Each goes last on its day unless `position` says otherwise (1 first; sessions planned earlier in the
      same call count). Plan main workouts (kind workout) as a rule, and their warm-up and cool-down come with them; a stand-alone stretch or mobility routine (a cooldown or warmup) can be planned on its own.
      Sessions you plan are marked `created_by: llm`. #{CALENDAR} Plan around the user's running, and leave the days
      between strength sessions empty when they should rest. Answers with the sessions planned.
    TEXT
    input_schema(
      properties: {
        sessions: {
          type: "array", minItems: 1, maxItems: Session::PLAN_LIMIT,
          items: {
            type: "object", additionalProperties: false,
            properties: {
              date: { type: "string", description: "The day, YYYY-MM-DD, today or later." },
              workout_id: { type: "integer", description: "The workout, from list_workouts." },
              position: { type: "integer", minimum: 1, description: "Its place on the day, 1 first; last when left out." },
              note: { type: "string", description: "Why it is there, shown to the user, such as \"Legs before the long run\"." },
              parts: PARTS
            },
            required: %w[date workout_id]
          }
        }
      },
      required: %w[sessions]
    )
    annotations(title: "Plan sessions", **WRITES)

    def self.answer(sessions:)
      entries = sessions.each_with_index.map do |entry, index|
        workout = Workout.with_pk(entry[:workout_id]) || raise(Problem, "sessions[#{index}]: no workout #{entry[:workout_id]}; list_workouts lists them")
        { workout:, date: entry[:date], position: entry[:position], note: entry[:note].presence, parts: parts(entry[:parts]) }
      end
      planned = Session.plan_all!(entries, created_by: "llm")
      minutes = {}
      { planned: planned.map { shown(it, minutes) } }
    rescue Session::EntryInvalid => error
      entry = sessions[error.index]
      raise Problem, "sessions[#{error.index}] (#{entry[:date]}, workout #{entry[:workout_id]}): " \
                     "#{error.errors.full_messages.join(", ")}. Nothing was planned."
    end
  end
end
