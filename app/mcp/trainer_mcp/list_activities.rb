# frozen_string_literal: true

module TrainerMcp
  class ListActivities < ActivityTool
    description <<~TEXT.squish
      The user's activities (runs, rides, hikes, any sport) over a date range, by day and in the order they started:
      logged in the app or sent by a script through its API (`created_by: manual`), or by you or another agent
      (`created_by: llm`), with the numbers as sent; one without a `source` was typed in by hand. Distances and climb are metres, times seconds; `distance_unit` is how the user reads
      distances (km or mi). `rpe` (1-10) and `note` are the person's. One from somewhere else names its `source` and
      `external_id` there. Without dates, the last 28 days up to today; with only `from` 28 days on, with only `to`
      28 days back; at most 366 days. Nothing is summed or scored.
    TEXT
    input_schema(
      properties: {
        from: { type: "string", format: "date", description: "First day, YYYY-MM-DD." },
        to: { type: "string", format: "date", description: "Last day, YYYY-MM-DD." },
        sport: { type: "string", description: "Keep one sport, such as run or trail run." }
      }
    )
    annotations(title: "List activities", **READ_ONLY)

    def self.answer(from: nil, to: nil, sport: nil)
      range = days(from, to)
      activities = Activity.where(date: range).in_order
      activities = activities.of_sport(sport) if sport.present?

      {
        **today_and_weekday, from: range.begin.iso8601, to: range.end.iso8601,
                             distance_unit: Setting.current.distance_unit, activities: activities.all.map { shown(it) }
      }
    end
  end
end
