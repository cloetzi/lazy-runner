# frozen_string_literal: true

module TrainerMcp
  # What the activity tools share: an activity as they answer with it, and
  # reading the distances, times and starts an agent sends.
  class ActivityTool < Tool
    # Metres in one of each unit a distance or climb may be sent in.
    METRES = {
      "m" => 1, "metre" => 1, "metres" => 1, "meter" => 1, "meters" => 1,
      "km" => 1000, "k" => 1000, "kilometre" => 1000, "kilometres" => 1000, "kilometer" => 1000, "kilometers" => 1000,
      "mi" => 1609.344, "mile" => 1609.344, "miles" => 1609.344,
      "ft" => 0.3048, "foot" => 0.3048, "feet" => 0.3048,
      "yd" => 0.9144, "yard" => 0.9144, "yards" => 0.9144
    }.freeze
    LENGTH = /\A(\d+(?:\.\d+)?)\s*([a-z]*)\z/i
    # A start without an offset, which would be read in the wrong zone.
    ZONELESS = /\A\d{4}-\d{2}-\d{2}[T\s]+\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?\z/i

    # A distance or climb as whole metres: a number is metres, text names its
    # unit ("5 mi", "10.2 km", "1200 ft"; none is metres).
    def self.metres(value, field)
      return if value.nil?
      raise Problem, "#{field} must not be negative; leave it out when the source has none" if value.is_a?(Numeric) && value.negative?
      return value.round if value.is_a?(Numeric) && value < 100_000_000

      match = value.is_a?(String) && value.strip.match(LENGTH)
      factor = match && METRES[match[2].downcase.presence || "m"]
      unless factor
        raise Problem, "#{field} must be metres as a number, or text with its unit such as \"5 mi\" or \"10.2 km\"; got #{value.inspect}"
      end

      (match[1].to_f * factor).round
    end

    # A start as ISO 8601 with its offset; Garmin's "2026-11-03 06:12:00"
    # (startTimeGMT) is read as UTC only when the agent says so with a Z.
    def self.start(value, field)
      return value unless value.is_a?(String)

      text = value.strip
      raise Problem, "#{field} needs its offset (+01:00) or Z for UTC, such as 2026-11-03T06:12:00Z" if text.match?(ZONELESS)

      text.sub(/\A(\d{4}-\d{2}-\d{2}) /, '\1T')
    end

    # A day as YYYY-MM-DD only, as DateRange reads one: "11/3/2026" is
    # refused rather than guessed at.
    def self.date(value, field)
      DateRange.date(value, field).iso8601
    rescue DateRange::Invalid => error
      raise Problem, error.message
    end

    def self.shown(activity)
      compact(activity.as_json.except(:client_ref, :created_at, :updated_at))
    end
  end
end
