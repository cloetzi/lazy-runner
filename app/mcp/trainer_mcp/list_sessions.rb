# frozen_string_literal: true

module TrainerMcp
  class ListSessions < SessionTool
    description <<~TEXT.squish
      The calendar over a date range: every session, by day and in order, planned, missed, in progress, done or
      skipped, each with its workout, the minutes it runs (warm-up and cool-down included), who planned it
      (`created_by`: manual for the user, llm for you) and, once done, how it felt (RPE 1-10, feedback, a note,
      whether it ended early). Without dates, the last 28 days up to today, or with status ["planned"] alone the
      next 28 days from today. With only `from` the range runs 28 days on, with only `to` 28 days back; at most
      366 days. #{CALENDAR} training_summary has what was done per exercise.
    TEXT
    input_schema(
      properties: {
        from: { type: "string", description: "First day, YYYY-MM-DD." },
        to: { type: "string", description: "Last day, YYYY-MM-DD; may be in the future." },
        status: { type: "array", minItems: 1, items: { type: "string", enum: Session::SHOWN_STATUSES }, description: "Keep only sessions that read as these." }
      }
    )
    annotations(title: "List sessions", **READ_ONLY)

    def self.answer(from: nil, to: nil, status: nil)
      statuses = Session.statuses(status)
      range = days(from, to, back: (0 if statuses == ["planned"]))
      sessions = Session.eager(:completion, :workout).where(date: range).in_order
      sessions = sessions.with_status(statuses) if statuses
      sessions = sessions.all
      minutes = {}

      { **today_and_weekday, from: range.begin.iso8601, to: range.end.iso8601, sessions: sessions.map { shown(it, minutes) } }
    end
  end
end
