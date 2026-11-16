# frozen_string_literal: true

require "test_helper"

describe CoachNote do
  describe ".written_today" do
    after { travel_back }

    it "counts from midnight of the server's day" do
      travel_to Time.zone.local(2026, 11, 4, 0, 30)
      late = CoachNote.create(kind: "note", body: "Late", author_kind: "llm")
      late.update_columns(created_at: Time.zone.local(2026, 11, 3, 23, 59, 59).to_time)
      midnight = CoachNote.create(kind: "note", body: "Midnight", author_kind: "llm")
      midnight.update_columns(created_at: Time.zone.local(2026, 11, 4).to_time)

      _(CoachNote.written_today.select_map(:id)).must_equal [midnight.id]
      _(CoachNote.by_agent.count).must_equal 2
    end
  end
end
