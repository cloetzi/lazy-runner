# frozen_string_literal: true

module TrainerMcp
  class LogActivities < ActivityTool
    # The fields an entry may hold. `rpe` and `note` are the person's, so
    # they are left to the app.
    ENTRY = {
      date: { type: "string", format: "date", description: "The day it started on, in the user's own time, YYYY-MM-DD; not after today." },
      sport: { type: "string",
               description: "Such as run, trail run, ride, hike, swim or ski (Garmin's running or trail_running read as words)." },
      source: { type: "string", description: "Where it comes from, such as garmin. With external_id, it is how a resend finds it." },
      external_id: { type: %w[string integer], description: "Its id at the source, such as the Garmin activity id." },
      title: { type: "string", description: "Its name at the source." },
      started_at: { type: "string", format: "date-time",
                    description: "When it started, ISO 8601 with its offset or Z, such as 2026-11-03T06:12:00Z." },
      distance: { type: %w[number string], description: "Metres as a number, or text with its unit: \"5 mi\", \"10.2 km\", \"800 m\"." },
      climb: { type: %w[number string], description: "Elevation gain: metres as a number, or text with its unit such as \"1200 ft\"." },
      moving_seconds: { type: "number", minimum: 0, maximum: 10_000_000, description: "Moving time in seconds." },
      elapsed_seconds: { type: "number", minimum: 0, maximum: 10_000_000, description: "Elapsed time in seconds, stops included." },
      avg_hr: { type: "number", minimum: 0, maximum: 1000, description: "Average heart rate, bpm." },
      max_hr: { type: "number", minimum: 0, maximum: 1000, description: "Highest heart rate, bpm." }
    }.freeze
    SECONDS_AND_BEATS = %i[moving_seconds elapsed_seconds avg_hr max_hr].freeze

    description <<~TEXT.squish
      Log the user's activities as they happened, one or up to #{Activity::BATCH_LIMIT} in one call, such as a
      backfill from Garmin: send each with its `source` and `external_id`, so sending it again updates it instead of
      adding a second one (fields sent are written, those left out are kept); one the user logged themselves is
      left as it is (outcome kept). What you log is marked
      `created_by: llm`. Send only numbers the source gave, never estimates; nothing is worked out from them.
      Before a backfill, list_activities the range: one the user logged by hand on the same day and sport is likely
      the same activity when its start or distance agree, so leave it out (or ask); a second one that day is not. The person's RPE and notes are theirs: the app asks for them.
      All or nothing: when one entry is wrong nothing is logged and the error names it, such as activities[3].distance.
    TEXT
    input_schema(
      properties: {
        today: { type: "string", format: "date",
                 description: "The user's today, YYYY-MM-DD, when it differs from the server's (a day either side at most); no date " \
                              "may be after it." },
        activities: {
          type: "array", minItems: 1, maxItems: Activity::BATCH_LIMIT,
          items: { type: "object", properties: ENTRY, required: %w[date sport], additionalProperties: false }
        }
      },
      required: %w[activities]
    )
    annotations(title: "Log activities", **WRITES)

    def self.answer(activities:, today: nil)
      entries = activities.each_with_index.map { |entry, index| entry(entry, index) }
      outcomes = Activity.log_all!(entries, today: user_today(today), created_by: "llm")
      logged = outcomes.map { |activity, outcome| shown(activity).slice(:id, :date, :sport, :source, :external_id).merge(outcome:) }
      # A pair sent twice is one activity, counted once.
      counted = outcomes.uniq { it.first.id }

      tally = counted.map(&:last).tally
      { created: tally.fetch(:created, 0), updated: tally.fetch(:updated, 0), kept: tally.fetch(:kept, 0), activities: logged }
    rescue Activity::EntryInvalid => error
      raise Problem, "#{error.message}. Nothing was logged; fix it and send the whole list again."
    end

    # The user's today as the API takes it (ApplicationController#client_today):
    # a day either side of the server's.
    def self.user_today(text)
      server = Time.zone.today
      return server if text.nil?

      given = Date.iso8601(date(text, :today))
      raise Problem, "today must be within a day of the server's (#{server.iso8601})" unless ((server - 1)..(server + 1)).cover?(given)

      given
    end

    # An entry as Activity.log_all! takes it: lengths in metres, times and
    # beats whole.
    def self.entry(entry, index)
      entry = entry.transform_keys(&:to_sym)
      place = "activities[#{index}]"
      distance, climb = entry.values_at(:distance, :climb)
      fields = entry.except(:distance, :climb)
      fields[:distance_m] = metres(distance, "#{place}.distance") if entry.key?(:distance)
      fields[:climb_m] = metres(climb, "#{place}.climb") if entry.key?(:climb)
      fields[:date] = date(fields[:date], "#{place}.date")
      fields[:started_at] = start(fields[:started_at], "#{place}.started_at") if fields.key?(:started_at)
      SECONDS_AND_BEATS.each { fields[it] = fields[it].round if fields[it].is_a?(Numeric) }
      fields
    end
  end
end
