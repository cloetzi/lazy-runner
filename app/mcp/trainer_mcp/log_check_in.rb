# frozen_string_literal: true

module TrainerMcp
  class LogCheckIn < Tool
    NIGHT = {
      sleep: { type: "string", enum: CheckIn::CHOICES[:sleep] },
      drinks: { type: "string", enum: CheckIn::CHOICES[:drinks] },
      tags: { type: "array", items: { type: "string", enum: CheckIn::NIGHT_TAGS } },
      note: { type: "string", maxLength: CheckIn::NOTE_LENGTH, description: "In the user's words, briefly." }
    }.freeze
    DAY = {
      feeling: { type: "string", enum: CheckIn::CHOICES[:feeling] },
      stress: { type: "string", enum: CheckIn::CHOICES[:stress] },
      sore: { type: "string", enum: CheckIn::CHOICES[:sore] },
      sore_areas: { type: "array", items: { type: "string", enum: CheckIn::SORE_AREAS } },
      ill: { type: "boolean" },
      note: { type: "string", maxLength: CheckIn::NOTE_LENGTH, description: "In the user's words, briefly." }
    }.freeze

    description <<~TEXT.squish
      Log what the user told you about a day ("had a few beers last night", "knees sore today"), for today or up to
      #{CheckIn::AGENT_DAYS_BACK} days back: `night` is the night that ended on that date's morning, `day` how they
      felt that day. Send only what they said, never a guess. It fills only fields still empty: what the user logged
      is theirs and stays (the answer lists it under `kept`). The user sees it in the app.
    TEXT
    input_schema(
      properties: {
        date: { type: "string", format: "date", description: "The day, YYYY-MM-DD: for last night's drinks, today." },
        night: { type: "object", properties: NIGHT, additionalProperties: false },
        day: { type: "object", properties: DAY, additionalProperties: false }
      },
      required: %w[date]
    )
    annotations(title: "Log a check-in", **WRITES)

    def self.answer(date:, night: nil, day: nil)
      raise Problem, "send what the user said in `night` or `day`" if night.blank? && day.blank?

      check_in, filled, kept = CheckIn.fill!(date, night:, day:)
      { check_in: check_in && ListCheckIns.shown(check_in), filled:, kept: }
    end
  end
end
