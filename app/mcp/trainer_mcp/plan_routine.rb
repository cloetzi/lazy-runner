module TrainerMcp
  class PlanRoutine < RoutineTool
    description <<~TEXT.squish
      Plan a run, ride, hike or any sport (or one of the user's workouts) as a routine: weekly on `weekdays`, or a
      one-off on `starts_on` with `weekdays: []`. #{RULES} What you plan stays tentative until the user confirms a
      day, and is marked `created_by: llm`. Plan around their strength sessions and rest days, and keep to what
      they told you they can do. Answers with the routine and its days over the next four weeks.
    TEXT
    input_schema(
      properties: {
        sport: { type: "string", description: "The sport, such as run, ride or hike. A sport or workout_id, not both." },
        workout_id: { type: "integer", description: "One of the user's workouts (list_workouts), for a strength routine." },
        **FIELDS
      },
      required: %w[weekdays]
    )
    annotations(title: "Plan a routine", **WRITES)

    def self.answer(**arguments)
      routine = Routine.plan!(attributes(arguments), created_by: "llm")
      today = Time.zone.today
      { routine: shown(routine), days: RoutineCalendar.new(today..today + 27).days.select { it.routine.id == routine.id }.map { shown_day(it) } }
    end
  end
end
