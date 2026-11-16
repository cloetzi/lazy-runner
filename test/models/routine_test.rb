# frozen_string_literal: true

require "test_helper"

describe Routine do
  # A Wednesday.
  let(:today) { Date.new(2026, 11, 11) }
  let(:strength) { workout("cycle-1-workout-1") }

  before { travel_to Time.utc(2026, 11, 11, 12) }
  after { travel_back }

  def d(text) = Date.iso8601(text)

  # A routine made as on `on` (so it may have days gone by now).
  def routine(on: today, **attributes)
    Routine.plan!({ sport: "run", weekdays: [3], **attributes }, today: on).tap { it.today = today }
  end

  def run_on(date, sport: "run", **entry) = Activity.log!({ date:, sport:, **entry }, today:).first

  def days(from, to) = RoutineCalendar.new(d(from)..d(to), today:).days

  def states(from, to) = days(from, to).map { [it.routine.id, it.on.iso8601, it.state] }

  describe "its days" do
    it "has a day on each of its weekdays from its start, tentative from today on and missed before" do
      run = routine(on: d("2026-11-02"), weekdays: [1, 3])

      _(states("2026-11-01", "2026-11-17")).must_equal [
        [run.id, "2026-11-02", "missed"], [run.id, "2026-11-04", "missed"], [run.id, "2026-11-09", "missed"],
        [run.id, "2026-11-11", "tentative"], [run.id, "2026-11-16", "tentative"]
      ]
    end

    it "keeps its weekdays sorted once each, Monday 1, and a one-off ends on its day" do
      _(routine(weekdays: [7, "3", 3]).weekdays).must_equal [3, 7]

      once = routine(weekdays: [], starts_on: "2026-11-14")
      _(once.one_off?).must_equal true
      _(once.ends_on).must_equal d("2026-11-14")
      _(states("2026-11-09", "2026-11-22").select { it.first == once.id }).must_equal [[once.id, "2026-11-14", "tentative"]]
    end

    it "refuses a start before today, both a sport and a workout, and weekdays out of 1..7" do
      _(Routine.new(sport: "run", starts_on: d("2026-11-10"), today:).valid?).must_equal false
      both = Routine.new(sport: "run", workout_id: strength.id, starts_on: today, today:)
      _(both.valid?).must_equal false
      _(both.errors.full_messages).must_include "A routine is a sport or a workout, not both"
      _(Routine.new(starts_on: today, today:).tap(&:valid?).errors[:sport]).must_equal ["can't be blank without a workout"]
      _(Routine.new(sport: "run", weekdays: [0, 8], starts_on: today, today:).tap(&:valid?).errors[:weekdays]).wont_be_nil
    end

    it "refuses another user's workout, and an archived one" do
      other = create_user("other")
      theirs = Current.set(user: other) { Workout.first!(example_slug: "cycle-1-workout-1") }

      _(Routine.new(workout_id: theirs.id, starts_on: today, today:).tap(&:valid?).errors[:workout_id]).must_equal ["is not found"]
      strength.archive!
      _(Routine.new(workout_id: strength.id, starts_on: today, today:).tap(&:valid?).errors[:workout])
        .must_equal ["is archived; pick another workout"]
    end
  end

  describe "what fulfils a day" do
    it "is done by an activity of the same sport family on its day" do
      routine(on: d("2026-11-04"))
      trail = run_on("2026-11-04", sport: "TrailRun")

      day = days("2026-11-04", "2026-11-04").first
      _(day.state).must_equal "done"
      _(day.activity.id).must_equal trail.id
    end

    it "is not done by another sport, nor by a run on another day" do
      routine(on: d("2026-11-04"))
      run_on("2026-11-04", sport: "ride")
      run_on("2026-11-05")

      _(days("2026-11-04", "2026-11-04").first.state).must_equal "missed"
    end

    it "matches a word no family knows only to itself" do
      routine(on: d("2026-11-04"), sport: "Kayak")
      run_on("2026-11-04", sport: "kayak")

      _(days("2026-11-04", "2026-11-04").first.state).must_equal "done"
    end

    it "gives each activity to one day: the day's routines choose in id order, the earliest first" do
      first = routine(on: d("2026-11-04"))
      second = routine(on: d("2026-11-04"), sport: "jog")
      morning = run_on("2026-11-04", started_at: "2026-11-04T07:00:00Z")

      _(days("2026-11-04", "2026-11-04").map { [it.routine.id, it.activity&.id] }).must_equal [[first.id, morning.id], [second.id, nil]]

      evening = run_on("2026-11-04", started_at: "2026-11-04T18:00:00Z")
      _(days("2026-11-04", "2026-11-04").map { it.activity.id }).must_equal [morning.id, evening.id]
    end

    it "takes an activity linked by hand first, and never gives that one to another day" do
      run = routine(on: d("2026-11-03"), weekdays: [2, 3])
      wednesday = run_on("2026-11-04")
      wednesday.update(routine_id: run.id, routine_date: d("2026-11-03"))

      _(states("2026-11-03", "2026-11-04")).must_equal [[run.id, "2026-11-03", "done"], [run.id, "2026-11-04", "missed"]]
      _(days("2026-11-03", "2026-11-03").first.linked).must_equal true
    end

    it "matches a moved day on the day it moved to" do
      run = routine
      run.move!(today, d("2026-11-12"))
      run_on("2026-11-11")

      day = days("2026-11-11", "2026-11-12").first
      _([day.on, day.state]).must_equal [d("2026-11-12"), "tentative"]
    end
  end

  describe "changing a day" do
    it "confirms, skips and makes a sport day tentative again" do
      run = routine

      _(run.confirm!(today).state).must_equal "confirmed"
      _(run.skip!(today).state).must_equal "skipped"
      _(run.reset!(today).state).must_equal "tentative"
      _(RoutineDay.count).must_equal 0
    end

    it "keeps a confirmed day confirmed when it moves, and moves it back on its own date" do
      run = routine
      run.confirm!(today)
      moved = run.move!(today, d("2026-11-13"))

      _([moved.on, moved.state, moved.date]).must_equal [d("2026-11-13"), "confirmed", today]
      back = run.move!(today, today)
      _([back.on, back.state]).must_equal [today, "confirmed"]
    end

    it "keeps a moved day where it shows when it is skipped or made tentative again" do
      run = routine
      run.confirm!(today)
      run.move!(today, d("2026-11-13"))

      _(run.skip!(today).then { [it.on, it.state] }).must_equal [d("2026-11-13"), "skipped"]
      _(run.reset!(today).then { [it.on, it.state] }).must_equal [d("2026-11-13"), "tentative"]
      _(run.move!(today, today).on).must_equal today
      _(RoutineDay.count).must_equal 0
    end

    it "keeps a workout day's move when its session comes off the calendar" do
      lift = routine(sport: nil, workout_id: strength.id)
      lift.confirm!(today)
      lift.move!(today, d("2026-11-14"))
      day = lift.reset!(today)

      _([day.on, day.state, day.session]).must_equal [d("2026-11-14"), "tentative", nil]
    end

    it "links an activity by hand only to a day that shows on or before it" do
      run = routine(weekdays: [3, 5])
      run.move!(d("2026-11-13"), today)
      error = _ { run_on("2026-11-11", routine_id: run.id, routine_date: "2026-11-18") }.must_raise Sequel::ValidationFailed

      _(error.message).must_include "after the activity"
      _(run_on("2026-11-11", routine_id: run.id, routine_date: "2026-11-13").routine_date).must_equal d("2026-11-13")
    end

    it "refuses to move a day before today, to change a done day, and a date that isn't its day" do
      run = routine
      _ { run.move!(today, d("2026-11-10")) }.must_raise Sequel::ValidationFailed
      run_on("2026-11-11")
      _ { run.skip!(today) }.must_raise Routine::Settled
      _ { run.confirm!(d("2026-11-12")) }.must_raise Record::NotFound
    end

    it "refuses to confirm a day gone by" do
      run = routine(on: d("2026-11-04"))

      _ { run.confirm!(d("2026-11-04")) }.must_raise Sequel::ValidationFailed
    end

    it "plans a workout routine's confirmed day as a session, whose status the day then reads" do
      lift = routine(sport: nil, workout_id: strength.id, weekdays: [3, 5])
      day = lift.confirm!(d("2026-11-13"))

      session = day.session
      _([session.status, session.date, session.routine_id, session.routine_date])
        .must_equal ["planned", d("2026-11-13"), lift.id, d("2026-11-13")]
      _(day.state).must_equal "confirmed"

      _(lift.move!(d("2026-11-13"), d("2026-11-14")).on).must_equal d("2026-11-14")
      _(session.refresh.date).must_equal d("2026-11-14")
      _(lift.skip!(d("2026-11-13")).state).must_equal "skipped"
      _(session.refresh.status).must_equal "skipped"
      _(lift.reset!(d("2026-11-13")).state).must_equal "tentative"
      _(Session.where(id: session.id).count).must_equal 0
    end

    it "reads a workout day as done by its session, or by a done session of its workout on the day" do
      routine(on: d("2026-11-04"), sport: nil, workout_id: strength.id)
      session_on("2026-11-04", "done", workout: strength)

      _(days("2026-11-04", "2026-11-04").first.state).must_equal "done"
    end

    it "won't make a day gone by tentative again" do
      run = routine(on: d("2026-11-04"))
      run.skip!(d("2026-11-04"))

      _ { run.reset!(d("2026-11-04")) }.must_raise Routine::Settled
      _(days("2026-11-04", "2026-11-04").first.state).must_equal "skipped"
    end

    it "won't make a day tentative again once its session has started" do
      lift = routine(sport: nil, workout_id: strength.id)
      session = lift.confirm!(today).session
      session.update(status: "in_progress")

      _ { lift.reset!(today) }.must_raise Session::Settled
    end
  end

  describe "#revise!" do
    it "changes a routine without days gone by in place" do
      run = routine(weekdays: [5])
      revised = run.revise!(weekdays: [4], title: "Easy run")

      _(revised.id).must_equal run.id
      _(revised.weekdays).must_equal [4]
    end

    it "splits a routine with days gone by when its schedule changes, so they stay as they were" do
      run = routine(on: d("2026-11-02"), weekdays: [1, 3])
      run.confirm!(today)
      run.confirm!(d("2026-11-16"))
      revised = run.revise!(weekdays: [3, 5])

      _(revised.id).wont_equal run.id
      _(run.refresh.ends_on).must_equal d("2026-11-10")
      _(revised.starts_on).must_equal today
      # Wednesday's confirmation moves with it; Monday's goes.
      _(RoutineDay.select_map(%i[routine_id date])).must_equal [[revised.id, today]]
      _(states("2026-11-09", "2026-11-13"))
        .must_equal [[run.id, "2026-11-09", "missed"], [revised.id, "2026-11-11", "confirmed"], [revised.id, "2026-11-13", "tentative"]]
    end

    it "changes the title of a routine with days gone by in place" do
      run = routine(on: d("2026-11-02"))

      _(run.revise!(title: "Hills").id).must_equal run.id
    end

    it "drops a confirmed sport day when the routine becomes a workout, keeping where it shows" do
      run = routine(weekdays: [3, 5])
      run.confirm!(today)
      run.confirm!(d("2026-11-13"))
      run.move!(d("2026-11-13"), d("2026-11-14"))
      run.revise!(sport: nil, workout_id: strength.id)

      _(RoutineDay.select_map(%i[date status moved_to])).must_equal [[d("2026-11-13"), "moved", d("2026-11-14")]]
      _(states("2026-11-11", "2026-11-14").map(&:last)).must_equal %w[tentative tentative]
    end

    it "takes a workout routine's planned sessions off the calendar when its workout changes" do
      other = workout("cycle-1-workout-2")
      lift = routine(on: d("2026-11-04"), sport: nil, workout_id: strength.id)
      session = lift.confirm!(d("2026-11-18")).session
      lift.revise!(workout_id: other.id)

      _(Session.where(id: session.id).count).must_equal 0
    end

    it "refuses to end a routine before yesterday, or to move a past one-off" do
      run = routine(on: d("2026-11-02"))
      _ { run.revise!(ends_on: "2026-11-05") }.must_raise Sequel::ValidationFailed

      once = routine(on: d("2026-11-07"), weekdays: [], starts_on: "2026-11-07")
      _ { once.revise!(starts_on: "2026-11-14") }.must_raise Routine::Settled
    end
  end

  describe "#end!" do
    it "ends a routine with days gone by yesterday, and deletes one without" do
      old = routine(on: d("2026-11-02"))
      fresh = routine(weekdays: [5])

      _(old.end!).must_equal :ended
      _(old.refresh.ends_on).must_equal d("2026-11-10")
      _(fresh.end!).must_equal :deleted
      _(Routine.where(id: fresh.id).count).must_equal 0
    end

    it "erases an ended routine with its history when asked, unlinking what fulfilled it" do
      run = routine(on: d("2026-11-02"), weekdays: [1, 3])
      monday = run_on("2026-11-09")
      monday.update(routine_id: run.id, routine_date: d("2026-11-09"))
      run.end!

      _(run.end!(erase: true)).must_equal :deleted
      _(monday.refresh.values.values_at(:routine_id, :routine_date)).must_equal [nil, nil]
    end

    it "takes a day gone by but moved forward off the calendar too" do
      lift = routine(on: d("2026-11-04"), sport: nil, workout_id: strength.id)
      missed = Session.add!(workout: strength, date: d("2026-11-04"), status: "planned", today: d("2026-11-04"), routine_id: lift.id,
                            routine_date: d("2026-11-04"))
      missed.today = today
      missed.move!(date: d("2026-11-13"))
      run = routine(on: d("2026-11-04"))
      run.move!(d("2026-11-04"), d("2026-11-12"))
      lift.end!
      run.end!

      _(Session.where(id: missed.id).count).must_equal 0
      _(RoutineDay.count).must_equal 0
      _(states("2026-11-09", "2026-11-15")).must_equal []
    end

    it "counts a one-off gone by but moved forward as current until it is ended" do
      once = routine(on: d("2026-11-07"), weekdays: [], starts_on: "2026-11-07")
      once.move!(d("2026-11-07"), d("2026-11-12"))

      _(once.ended?).must_equal false
      _(Routine.current(today).select_map(:id)).must_equal [once.id]
      _(once.end!).must_equal :ended
      _(Routine.current(today).count).must_equal 0
      _(states("2026-11-12", "2026-11-12")).must_equal []
    end

    it "keeps an ended routine's end date when it is sent again, as text" do
      run = routine(on: d("2026-11-02"))
      run.end!

      _(run.revise!(title: "Old runs", ends_on: "2026-11-10").title).must_equal "Old runs"
    end

    it "is what archiving its workout does" do
      lift = routine(sport: nil, workout_id: strength.id)
      strength.archive!

      _(Routine.where(id: lift.id).count).must_equal 0
    end
  end

  it "plans a one-off as confirmed in the same write" do
    once = Routine.plan!({ sport: "hike", weekdays: [], starts_on: "2026-11-14" }, today:, confirmed: true)

    _(RoutineCalendar.day(once, d("2026-11-14"), today:).state).must_equal "confirmed"
    _ { Routine.plan!({ sport: "run", weekdays: [3] }, today:, confirmed: true) }.must_raise Routine::Settled
  end

  it "has the same families as the PWA's icons" do
    _(Sport.family("Trail running")).must_equal "run"
    _(Sport.family("e-bike")).must_equal "ride"
    _(Sport.family("Cross-country ski")).must_equal "ski"
    _(Sport.family("kayak")).must_equal "kayak"
  end
end
