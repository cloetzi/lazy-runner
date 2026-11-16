# frozen_string_literal: true

module TrainerMcp
  # What the routine tools share: a routine as they answer with it, the
  # fields an agent sends for one, and the rule that the agent changes only
  # the routines it planned.
  class RoutineTool < ActivityTool
    RULES = <<~TEXT.squish
      A routine is what the user means to do, tentatively: a sport (fulfilled by any activity of the same family on
      the day: run, running and trail run are all runs) or one of their workouts (fulfilled by a session of it),
      weekly on ISO weekdays (1 Monday to 7 Sunday) or a one-off on one day. Its days read as tentative, confirmed
      (the user said they're going; a workout routine's confirmed day is a planned session), done, skipped, or
      missed (gone by with nothing logged). Only the user confirms, skips or moves a day.
    TEXT

    FIELDS = {
      title: { type: "string", description: "A short name, such as \"Long run\"; the sport or workout is shown without one." },
      weekdays: {
        type: "array", items: { type: "integer", minimum: 1, maximum: 7 }, uniqueItems: true,
        description: "ISO weekdays, 1 Monday to 7 Sunday, such as [3, 6] for Wednesday and Saturday; [] for a one-off on starts_on."
      },
      starts_on: { type: "string", format: "date",
                   description: "First day (a one-off's day), YYYY-MM-DD, today or later; today when left out." },
      ends_on: { type: %w[string null], format: "date", description: "Last day, YYYY-MM-DD; runs on when left out." },
      minutes: { type: %w[integer null], minimum: 1, description: "Roughly how long." },
      distance: { type: %w[number string null],
                  description: "Roughly how far: metres as a number, or text with its unit such as \"8 km\" or \"5 mi\"." },
      effort: { type: %w[string null], enum: [*Routine::EFFORTS, nil], description: "How hard it should feel." },
      note: { type: %w[string null],
              description: "Why it is there, shown to the user, such as \"Easy, to keep the legs fresh for Saturday\"." }
    }.freeze

    def self.find_routine(id)
      Routine.eager(:workout).with_pk(id) || raise(Problem, "no routine #{id}; list_routines lists them")
    end

    # One the agent planned: the user's own routines are theirs to change.
    def self.own_routine(id)
      routine = find_routine(id)
      unless routine.created_by == "llm"
        raise Problem, "routine #{id} is the user's; only they change or end it. Suggest the change to them, or write it in a coach note."
      end

      routine
    end

    # The fields of a routine as the model takes them, from a tool's arguments.
    def self.attributes(arguments)
      attributes = arguments.slice(:title, :sport, :workout_id, :weekdays, :starts_on, :ends_on, :minutes, :effort, :note)
      attributes[:distance_m] = metres(arguments[:distance], "distance") if arguments.key?(:distance)
      attributes[:sport] = attributes[:sport].presence if attributes.key?(:sport)
      attributes
    end

    def self.shown(routine)
      compact(
        routine.as_json.except(:created_at, :updated_at, :workout)
          .merge(workout: routine.workout&.then { { id: it.id, title: it.title, archived: (true if it.archived?) } })
      )
    end

    def self.shown_day(day)
      compact(day.as_json.except(:confirmed, :linked).merge(moved: (true if day.on != day.date)))
    end
  end
end
