# frozen_string_literal: true

module TrainerMcp
  class ListCheckIns < Tool
    description <<~TEXT.squish
      What the user said about their days, as context for Garmin's numbers: per day, `night` is the night that ended
      that morning (sleep poor/ok/good, drinks none/1-2/3+, tags such as late_to_bed or travelling, a note), the same
      night Garmin's sleep and overnight HRV for that date measure; `day` is how they felt that day (feeling
      rough/ok/good, stress low/normal/high, sore no/a_bit/a_lot with sore_areas, ill, a note). Either is null when
      nothing was logged, and a day with neither is left out: a missing day means nothing was logged, not a good day.
      `logged_by` is manual for the user, llm for an agent that logged what the user told it. Without dates, the 14
      days up to today; at most 366 days.
    TEXT
    input_schema(
      properties: {
        from: { type: "string", format: "date", description: "First day, YYYY-MM-DD." },
        to: { type: "string", format: "date", description: "Last day, YYYY-MM-DD." }
      }
    )
    annotations(title: "List check-ins", **READ_ONLY)

    def self.answer(from: nil, to: nil)
      range = from.blank? && to.blank? ? (Current.today - 13)..Current.today : days(from, to)
      {
        **today_and_weekday, from: range.begin.iso8601, to: range.end.iso8601,
                             check_ins: CheckIn.where(date: range).in_order.all.map { shown(it) }
      }
    end

    def self.shown(check_in)
      compact(date: check_in.date.iso8601, weekday: check_in.date.strftime("%A"),
              night: check_in.group_json("night"), day: check_in.group_json("day"))
    end
  end
end
