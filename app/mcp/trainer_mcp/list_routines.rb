module TrainerMcp
  class ListRoutines < RoutineTool
    # Days before today a range without dates starts: one week back, the
    # rest of the 28 days ahead, since checking before planning is its main use.
    BACK = 7

    description <<~TEXT.squish
      The user's routines with days in a date range, and those days by the day they show on. #{RULES} `created_by`
      says who planned a routine: `manual` the user, `llm` you or another agent. A day's `date` is the routine's own
      day; `on` is where it shows (moved, or its session's day). `counts` gives how many days read as each state
      over the range, as raw counts: nothing is scored. Without dates, the #{BACK} days before today and the
      #{DateRange::DAYS - BACK} from today on, so what is planned ahead shows; with only `from` #{DateRange::DAYS} days on,
      with only `to` #{DateRange::DAYS} days back; at most #{DateRange::MAX_DAYS} days.
    TEXT
    input_schema(
      properties: {
        from: { type: "string", format: "date", description: "First day, YYYY-MM-DD." },
        to: { type: "string", format: "date", description: "Last day, YYYY-MM-DD." }
      }
    )
    annotations(title: "List routines", **READ_ONLY)

    def self.answer(from: nil, to: nil)
      range = days(from, to, back: BACK)
      calendar = RoutineCalendar.new(range)
      {
        today: Time.zone.today.iso8601, from: range.begin.iso8601, to: range.end.iso8601,
        routines: calendar.routines.map { shown(it) },
        days: calendar.days.map { shown_day(it) },
        counts: calendar.days.map(&:state).tally
      }
    end
  end
end
