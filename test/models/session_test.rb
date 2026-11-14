require "test_helper"

describe Session do
  describe ".for_day" do
    let(:date) { Date.new(2026, 10, 20) }

    def session(status, on: date) = session_on(on, status)

    it "prefers a session under way, then a planned one, then a done one" do
      done = session("done")
      planned = session("planned")
      _(Session.for_day(date)).must_equal planned

      running = session("in_progress")
      _(Session.for_day(date)).must_equal running

      planned.destroy
      running.destroy
      session("skipped")
      _(Session.for_day(date)).must_equal done
    end

    it "takes the newest of two with the same status" do
      session("done")
      newer = session("done")

      _(Session.for_day(date)).must_equal newer
    end

    it "only looks at that day" do
      session("in_progress", on: date - 1)

      _(Session.for_day(date)).must_be_nil
    end

    it "takes the first planned in the day's order" do
      first, second = 2.times.map { session("planned") }
      first.update_columns(position: 2)
      second.update_columns(position: 1)

      _(Session.for_day(date).id).must_equal second.id
    end
  end

  describe "on the calendar" do
    # Today is the 20th; the 19th has gone by.
    before { travel_to Time.utc(2026, 10, 20, 12) }
    after { travel_back }

    let(:workout_1) { workout("cycle-1-workout-1") }
    let(:workout_2) { workout("cycle-1-workout-2") }

    def plan(date, **options) = Session.plan!(workout: workout_1, date: Date.iso8601(date), **options)

    def day(date) = Session.where(date: Date.iso8601(date)).order(:position).map { [it.id, it.position] }

    it "puts a new session last on its day, or where asked" do
      first = plan("2026-10-21")
      second = plan("2026-10-21")
      third = plan("2026-10-21", position: 1)
      fourth = plan("2026-10-21", position: 9)

      _(day("2026-10-21")).must_equal [[third.id, 1], [first.id, 2], [second.id, 3], [fourth.id, 4]]
    end

    it "numbers sessions made without a position after the day's last" do
      planned = plan("2026-10-21")
      done = session_on("2026-10-21", "done")

      _(done.position).must_equal planned.position + 1
    end

    it "plans from today on" do
      _(plan("2026-10-20", note: "Easy legs").note).must_equal "Easy legs"

      error = _ { plan("2026-10-19") }.must_raise Sequel::ValidationFailed
      _(error.model.errors[:date]).must_equal ["must be today or later"]
      _(Session.where(date: Date.iso8601("2026-10-19"))).must_be_empty
    end

    it "takes a date as text, as an MCP tool sends it" do
      session = Session.plan!(workout: workout_1, date: "2026-10-22")
      _(session.date).must_equal Date.new(2026, 10, 22)

      error = _ { session.move!(date: "next week") }.must_raise Sequel::ValidationFailed
      _(error.model.errors[:date]).must_equal ["must be a date as YYYY-MM-DD"]
      _(session.refresh.date).must_equal Date.new(2026, 10, 22)
    end

    it "plans several sessions all or nothing" do
      planned = Session.plan_all!([
        { workout: workout_1, date: "2026-10-21", note: "Strength" },
        { workout: workout_2, date: "2026-10-21", position: 1, parts: %w[workout] }
      ], created_by: "llm")

      _(planned.map(&:created_by).uniq).must_equal ["llm"]
      _(day("2026-10-21")).must_equal [[planned[1].id, 1], [planned[0].id, 2]]
      _(planned[1].part_kinds).must_equal %w[workout]

      error = _ { Session.plan_all!([{ workout: workout_1, date: "2026-10-22" }, { workout: workout_1, date: "2026-10-19" }]) }
        .must_raise Session::EntryInvalid
      _(error).must_be_kind_of Sequel::ValidationFailed
      _([error.index, error.model.errors[:date]]).must_equal [1, ["must be today or later"]]
      _(Session.where(date: Date.iso8601("2026-10-22"))).must_be_empty
    end

    it "plans nothing new with an archived workout" do
      built = Workout.create_with!({ kind: "workout", title: "Old", blocks: [{ label: "A", steps: [{ exercise: "plank", duration_seconds: 30 }] }] })
      built.archive!

      error = _ { plan("2026-10-21", workout: built) }.must_raise Sequel::ValidationFailed
      _(error.model.errors[:workout]).must_equal ["is archived; plan another workout"]
    end

    it "moves no missed session of an archived workout back onto the calendar" do
      built = Workout.create_with!({ kind: "workout", title: "Old", blocks: [{ label: "A", steps: [{ exercise: "plank", duration_seconds: 30 }] }] })
      missed = session_on("2026-10-18", "planned", workout: built)
      skipped = Session.create(workout: built, date: Date.iso8601("2026-10-19"), status: "skipped")
      built.archive!

      _ { missed.move!(date: "2026-10-21") }.must_raise Sequel::ValidationFailed
      _ { skipped.update(status: "planned") }.must_raise Sequel::ValidationFailed
      _(missed.refresh.date).must_equal Date.iso8601("2026-10-18")
    end

    it "reads a list of statuses, missed included" do
      _(Session.statuses("planned, missed")).must_equal %w[planned missed]
      _(Session.statuses(%w[done])).must_equal %w[done]
      _(Session.statuses(nil)).must_be_nil
      _(_ { Session.statuses("done,someday") }.must_raise(ArgumentError).message).must_equal "unknown status: someday"
    end

    it "plans at most four weeks of sessions at once" do
      entries = Array.new(Session::PLAN_LIMIT + 1) { { workout: workout_1, date: "2026-10-21" } }

      _ { Session.plan_all!(entries) }.must_raise ArgumentError
      _(Session.count).must_equal 0
    end

    it "moves a session to another day, renumbering both" do
      first, moving, last = 3.times.map { plan("2026-10-21") }
      there = plan("2026-10-23")

      moving.move!(date: "2026-10-23", position: 1)

      _(day("2026-10-21")).must_equal [[first.id, 1], [last.id, 2]]
      _(day("2026-10-23")).must_equal [[moving.id, 1], [there.id, 2]]
    end

    it "writes only the move, not an older copy of the rest" do
      moving = plan("2026-10-21")
      Session.where(id: moving.id).update(note: "Written meanwhile")

      moving.move!(date: "2026-10-23", note: moving.note)

      _(moving.refresh.values.values_at(:date, :note)).must_equal [Date.new(2026, 10, 23), "Written meanwhile"]
    end

    it "goes last on the new day unless a position is given" do
      there = plan("2026-10-23")
      moving = plan("2026-10-21")

      moving.move!(date: "2026-10-23")

      _(day("2026-10-23")).must_equal [[there.id, 1], [moving.id, 2]]
    end

    it "reorders a day" do
      first, second, third = 3.times.map { plan("2026-10-21") }

      third.move!(position: 2)

      _(day("2026-10-21")).must_equal [[first.id, 1], [third.id, 2], [second.id, 3]]
    end

    it "keeps the note unless a new one is given" do
      session = plan("2026-10-21", note: "Easy legs")

      session.move!(date: "2026-10-22")
      _(session.refresh.note).must_equal "Easy legs"

      session.move!(date: "2026-10-23", note: nil)
      _(session.refresh.note).must_be_nil
    end

    it "reads a planned session on a day gone by as missed, until it moves" do
      missed = session_on("2026-10-19", "planned")

      _(missed.shown_status).must_equal "missed"
      _(missed.as_json[:status]).must_equal "missed"
      _(missed.shown_status(Date.new(2026, 10, 19))).must_equal "planned"

      missed.move!(date: "2026-10-20")

      _(missed.refresh.shown_status).must_equal "planned"
      _(missed.status).must_equal "planned"
    end

    it "reorders a missed session's day without a new date" do
      first, second = 2.times.map { session_on("2026-10-19", "planned") }

      second.move!(position: 1)

      _(day("2026-10-19")).must_equal [[second.id, 1], [first.id, 2]]
    end

    it "moves only to today or later" do
      session = plan("2026-10-21")

      _ { session.move!(date: "2026-10-19") }.must_raise Sequel::ValidationFailed
      _(session.refresh.date).must_equal Date.new(2026, 10, 21)
    end

    it "moves and removes only planned sessions" do
      %w[in_progress done skipped].each do |status|
        session = session_on("2026-10-20", status)

        _ { session.move!(date: "2026-10-21") }.must_raise Session::Settled
        _ { session.remove! }.must_raise Session::Settled
        _(session.refresh.date).must_equal Date.new(2026, 10, 20)
      end
    end

    it "removes a planned or missed session, renumbering its day" do
      first, second, third = 3.times.map { plan("2026-10-21") }
      missed = session_on("2026-10-19", "planned")

      second.remove!
      missed.remove!

      _(day("2026-10-21")).must_equal [[first.id, 1], [third.id, 2]]
      _(Session.where(id: missed.id).empty?).must_equal true
    end

    it "keeps a done session done" do
      session = session_on("2026-10-20", "done")

      %w[planned in_progress skipped].each do |status|
        _ { session.update(status:) }.must_raise Sequel::ValidationFailed
        session.refresh
      end
      _ { session.update(part_kinds: %w[workout]) }.must_raise Sequel::ValidationFailed
      session.refresh.update(note: "Felt strong")

      _(session.refresh.status).must_equal "done"
    end

    it "keeps a session with sets logged from going back to planned" do
      session = session_on("2026-10-20", "in_progress")
      log_all(session, "goblet-squat")

      error = _ { session.update(status: "planned") }.must_raise Sequel::ValidationFailed
      _(error.model.errors[:status]).must_equal ["can't go back to planned once sets are logged"]
    end

    it "counts what comes after a session in the day's order" do
      first, second = 2.times.map { plan("2026-10-21") }
      second.move!(position: 1)

      _(Session.after(second.refresh)).must_include first.refresh
      _(Session.after(first)).wont_include second
    end

    it "lets a session ended early be picked up again" do
      session = session_on("2026-10-20", "done")
      Completion.create(session:, finished_at: Time.now, ended_early: true)

      session.update(status: "in_progress")

      _(session.completion).must_be_nil
      _(Completion.where(session:)).must_be_empty
    end

    it "filters on the status a session reads as" do
      missed = session_on("2026-10-19", "planned")
      planned = plan("2026-10-20")
      done = session_on("2026-10-19", "done")

      _(Session.with_status(%w[missed]).all).must_equal [missed]
      _(Session.with_status(%w[planned]).all).must_equal [planned]
      _(Session.with_status(%w[missed done]).order(:id).all).must_equal [missed, done]
      _(Session.where(date: Date.new(2026, 10, 20)).with_status(%w[missed planned]).all).must_equal [planned]
      _(Session.with_status([]).all).must_equal []
    end
  end
end
