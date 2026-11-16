# frozen_string_literal: true

# Days as the API and the MCP tools read them: a date as YYYY-MM-DD, and a
# range of dates with its defaults and its limit, so both answer alike.
module DateRange
  # The days a range runs for when one end, or neither, is given.
  DAYS = 28
  # The longest range.
  MAX_DAYS = 366

  # A date or range that can't be read. `field` names the argument at fault
  # and `problem` says what is wrong with it.
  class Invalid < StandardError
    attr_reader :field, :problem

    def initialize(field, problem, message = "#{field} #{problem}")
      @field = field
      @problem = problem
      super(message)
    end
  end

  # A Date, or a YYYY-MM-DD string read as one; no other ISO 8601 form.
  def self.date(value, field)
    return value if value.is_a?(Date)

    text = value.to_s
    raise Date::Error unless text.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(text)
  rescue Date::Error
    raise Invalid.new(field, "must be a date as YYYY-MM-DD")
  end

  # The days from `from` to `to` (Dates or YYYY-MM-DD, blank when left out).
  # Neither given: 28 days from `back` days before today, so the 28 days up
  # to today by default and from today on with `back: 0`. One given: 28 days
  # on from `from`, or back from `to`. Future dates are fine; a range runs at
  # most 366 days.
  def self.resolve(from, to, back: nil, today: Current.today)
    span = DAYS - 1
    to = date(to, :to) if to.present?
    from = from.present? ? date(from, :from) : to&.-(span)
    from ||= today - (back || span)
    to ||= from + span
    raise Invalid.new(:from, "must not be after to") if from > to
    raise Invalid.new(:to, "must be within #{MAX_DAYS} days of from", "a range is at most #{MAX_DAYS} days") if (to - from).to_i >= MAX_DAYS

    from..to
  end
end
