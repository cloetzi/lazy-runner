require "test_helper"

describe PlanChange do
  # A Wednesday.
  let(:today) { Date.new(2026, 11, 11) }
  let(:strength) { workout("cycle-1-workout-1") }
  let(:other) { workout("cycle-1-workout-2") }

  before { travel_to Time.utc(2026, 11, 11, 12) }
  after { travel_back }

  def d(text) = Date.iso8601(text)

  def plan(date, **attributes) = Session.plan!(workout: strength, date: d(date), **attributes)

  def as_agent(name = "Coach agent", &) = Current.set(agent_name: name, &)

  def changes = PlanChange.order(:id).all

  def latest = PlanChange.order(:id).last

  def undo(change) = change.refresh.undo!(today:)

  describe "what a session records" do
    it "records a session planned, by the user or by an agent named by its token" do
      mine = plan("2026-11-12")
      theirs = as_agent { Session.plan!(workout: other, date: d("2026-11-13"), created_by: "llm") }

      _(changes.map { [it.action, it.changed_by, it.agent_name, it.session_id, it.title, it.to_date] }).must_equal [
        ["planned", "manual", nil, mine.id, strength.title, d("2026-11-12")],
        ["planned", "llm", "Coach agent", theirs.id, other.title, d("2026-11-13")]
      ]
    end

    it "shares one batch within a call and starts another for the next" do
      Current.set(plan_batch: nil) { Session.plan_all!([{ workout: strength, date: d("2026-11-12") }, { workout: other, date: d("2026-11-13") }]) }
      Current.set(plan_batch: nil) { plan("2026-11-14") }

      batches = changes.map(&:batch)
      _(batches[0]).must_equal batches[1]
      _(batches[2]).wont_equal batches[0]
    end

    it "records a move to another day with the day and place it left, keeping the note, and not a new place on its day" do
      session = plan("2026-11-12", note: "Legs")
      plan("2026-11-12")
      session.move!(position: 2)
      _(latest.action).must_equal "planned"

      PlanChange.because("Legs fresh for Sunday") { session.move!(date: d("2026-11-14")) }

      _(session.refresh.note).must_equal "Legs"
      _([latest.action, latest.session_id, latest.from_date, latest.to_date, latest.reason]).must_equal ["moved", session.id, d("2026-11-12"), d("2026-11-14"), "Legs fresh for Sunday"]
      _(latest.was).must_equal({ "date" => "2026-11-12", "position" => 2 })
      _(latest.now).must_equal({ "date" => "2026-11-14", "position" => 1 })
    end

    it "records a note or parts changed as changed, with the values before and after" do
      session = plan("2026-11-12", note: "Legs")
      session.update(note: "Legs, easy", part_kinds: %w[workout cooldown])

      _(latest.action).must_equal "changed"
      _(latest.was).must_equal({ "note" => "Legs", "parts" => nil })
      _(latest.now).must_equal({ "note" => "Legs, easy", "parts" => %w[workout cooldown] })
    end

    it "records a session taken off the calendar with what putting it back needs" do
      session = as_agent { Session.plan!(workout: strength, date: d("2026-11-12"), note: "Legs", parts: %w[workout], created_by: "llm") }
      PlanChange.because("Too close to the long run") { session.remove! }

      _([latest.action, latest.session_id, latest.from_date, latest.reason, latest.title]).must_equal ["removed", nil, d("2026-11-12"), "Too close to the long run", strength.title]
      _(latest.was).must_equal(
        "workout_id" => strength.id, "date" => "2026-11-12", "position" => 1, "note" => "Legs", "parts" => %w[workout],
        "created_by" => "llm", "agent_name" => "Coach agent", "routine_id" => nil, "routine_date" => nil
      )
    end

    it "records nothing for what happens to a plan: starting, skipping, finishing, deleting a finished session" do
      started = plan("2026-11-11")
      skipped = plan("2026-11-12")
      count = PlanChange.count
      started.update(status: "in_progress", started_at: Time.now)
      skipped.update(status: "skipped")
      skipped.update(status: "planned")
      started.update(status: "done")
      started.erase!

      _(PlanChange.count).must_equal count
    end

    it "records the sessions an archived workout takes off the calendar, with why" do
      session = plan("2026-11-12")
      strength.archive!

      _([latest.action, latest.from_date, latest.reason, latest.was["workout_id"]]).must_equal ["removed", session.date, "its workout was archived", strength.id]
    end
  end

  describe "what a routine records" do
    def routine(**attributes) = Routine.plan!({ sport: "run", weekdays: [3], **attributes }, today:)

    it "records a routine planned, changed and ended" do
      run = routine(minutes: 40)
      run.revise!(minutes: 50, note: "Easy")
      PlanChange.because("Taper week") { run.end! }

      _(changes.map { [it.action, it.routine_id, it.title, it.reason] }).must_equal [
        ["planned", nil, "Run", nil], ["changed", nil, "Run", nil], ["ended", nil, "Run", "Taper week"]
      ]
      # Deleted, having no days gone by: the changes stay without it.
      _(Routine.with_pk(run.id)).must_be_nil
      changed, ended = changes.last(2)
      _(changed.was).must_equal({ "minutes" => 40, "note" => nil })
      _(changed.now).must_equal({ "minutes" => 50, "note" => "Easy" })
      _(ended.was).must_equal(
        "title" => nil, "sport" => "run", "workout_id" => nil, "weekdays" => [3], "starts_on" => "2026-11-11", "ends_on" => nil,
        "minutes" => 50, "distance_m" => nil, "effort" => nil, "note" => "Easy", "created_by" => "manual", "agent_name" => nil, "id" => run.id
      )
    end

    it "records a rescheduled routine with days gone by as one change of the new routine" do
      run = Routine.plan!({ sport: "run", weekdays: [1] }, today: d("2026-11-02")).tap { it.today = today }
      count = PlanChange.count
      revised = run.revise!(weekdays: [3, 6])

      _(PlanChange.count).must_equal count + 1
      _([latest.action, latest.routine_id, latest.from_date, latest.was, latest.now]).must_equal ["changed", revised.id, today, { "weekdays" => [1], "starts_on" => "2026-11-02" }, { "weekdays" => [3, 6], "starts_on" => "2026-11-11" }]
    end

    it "records nothing for a day confirmed or made tentative again, and the session a routine change removes with why" do
      lift = Routine.plan!({ workout_id: strength.id, weekdays: [5] }, today:)
      count = PlanChange.count
      lift.confirm!(d("2026-11-13"))
      lift.reset!(d("2026-11-13"))
      _(PlanChange.count).must_equal count

      lift.confirm!(d("2026-11-13"))
      lift.revise!(weekdays: [6])

      _(changes.last(2).map { [it.item_kind, it.action, it.reason] }).must_equal [["routine", "changed", nil], ["session", "removed", "its routine changed"]]
    end
  end

  describe "undo" do
    it "moves a moved session back to its day and place, recorded as the user's change taking it back" do
      session = plan("2026-11-12")
      moved = as_agent { session.move!(date: d("2026-11-14")) && latest }

      back = undo(moved)

      _(session.refresh.date).must_equal d("2026-11-12")
      _([back.action, back.changed_by, back.undoes_id, back.to_date]).must_equal ["moved", "manual", moved.id, d("2026-11-12")]
      _(moved.refresh.undone?).must_equal true
    end

    it "puts a removed session back as a new session with its workout, day, note, parts and planner" do
      session = as_agent { Session.plan!(workout: strength, date: d("2026-11-12"), note: "Legs", parts: %w[workout], created_by: "llm") }
      as_agent { session.remove! }

      back = undo(latest)
      again = Session.with_pk(back.session_id)

      _([again.id == session.id, again.workout_id, again.date, again.note, again.part_kinds, again.created_by, again.agent_name]).must_equal [false, strength.id, d("2026-11-12"), "Legs", %w[workout], "llm", "Coach agent"]
      _(back.action).must_equal "planned"
    end

    it "puts a removed routine session back on its routine day" do
      lift = Routine.plan!({ workout_id: strength.id, weekdays: [5] }, today:)
      lift.confirm!(d("2026-11-13"))
      as_agent { Session.first(routine_id: lift.id).remove! }

      again = Session.with_pk(undo(latest).session_id)
      _([again.routine_id, again.routine_date]).must_equal [lift.id, d("2026-11-13")]
    end

    it "puts nothing back on a routine day planned again since, and nothing over a day the user skipped" do
      lift = Routine.plan!({ workout_id: strength.id, weekdays: [5] }, today:)
      lift.confirm!(d("2026-11-13"))
      removed = as_agent { Session.first(routine_id: lift.id).remove! && latest }
      lift.confirm!(d("2026-11-13"))
      _(_ { undo(removed) }.must_raise(PlanChange::NotUndoable).message).must_equal "its routine day, 2026-11-13, is planned again"

      Session.first(routine_id: lift.id).remove!
      lift.skip!(d("2026-11-13"))
      again = Session.with_pk(undo(removed).session_id)
      _([again.date, again.routine_id]).must_equal [d("2026-11-13"), nil]
    end

    it "refuses a reason longer than 2000 characters" do
      session = plan("2026-11-12")
      _ { PlanChange.because("x" * 2001) { session.move!(date: d("2026-11-13")) } }.must_raise Sequel::ValidationFailed
      _(session.refresh.date).must_equal d("2026-11-12")
    end

    it "changes a note back" do
      session = plan("2026-11-12", note: "Mine")
      as_agent { session.update(note: "Theirs") }

      undo(latest)
      _(session.refresh.note).must_equal "Mine"
    end

    it "changes a routine back, and plans an ended one again from today" do
      run = Routine.plan!({ sport: "run", weekdays: [3], minutes: 40 }, today:)
      as_agent { run.revise!(minutes: 60) }
      undo(latest)
      _(run.refresh.minutes).must_equal 40

      ended = as_agent { run.end! && latest }
      _(Routine.with_pk(run.id)).must_be_nil
      again = Routine.with_pk(undo(ended).routine_id)
      _([again.sport, again.weekdays, again.minutes, again.starts_on]).must_equal ["run", [3], 40, today]
    end

    it "plans an ended workout routine again with the sessions that confirmed its days" do
      lift = Routine.plan!({ workout_id: strength.id, weekdays: [5] }, today:)
      lift.confirm!(d("2026-11-13"))
      as_agent { lift.end! }
      ended = PlanChange.first(action: "ended")

      back = undo(ended)
      again = Routine.with_pk(back.routine_id)
      session = Session.first(routine_id: again.id)

      _([session.date, session.routine_date]).must_equal [d("2026-11-13"), d("2026-11-13")]
      _(PlanChange.where(item_kind: "session", action: "removed").all.map { it.undone? }).must_equal [true]
    end

    it "offers no routine back whose last day has gone by, or whose workout is archived" do
      run = Routine.plan!({ sport: "run", weekdays: [3], ends_on: "2026-11-20" }, today:)
      ended = run.end! && latest
      lookup = ->(on) { PlanChange::Lookup.new([ended], today: on) }
      _(ended.undo_problem(lookup.(d("2026-11-20")))).must_be_nil
      _(ended.undo_problem(lookup.(d("2026-11-21")))).must_equal "its last day, 2026-11-20, has gone by"

      lift = Routine.plan!({ workout_id: strength.id, weekdays: [5] }, today:)
      strength.archive!
      _(_ { undo(PlanChange.where(action: "ended", title: lift.workout.title).last) }.must_raise(PlanChange::NotUndoable).message).must_equal "its workout is archived"
    end

    it "takes back only the latest change of an item, once, and nothing planned" do
      session = plan("2026-11-12")
      planned = latest
      session.move!(date: d("2026-11-13"))
      first = latest
      session.move!(date: d("2026-11-14"))
      second = latest

      _(_ { undo(planned) }.must_raise(PlanChange::NotUndoable).message).must_equal "take a planned session off the calendar instead"
      _(_ { undo(first) }.must_raise(PlanChange::NotUndoable).message).must_match(/latest change/)
      back = undo(second)
      _(_ { undo(second) }.must_raise(PlanChange::NotUndoable).message).must_match(/taken back already/)
      _(_ { undo(back) }.must_raise(PlanChange::NotUndoable).message).must_match(/an undo can't be taken back/)
    end

    it "offers nothing into a day gone by, nor for a session no longer planned or with its workout archived" do
      session = plan("2026-11-12")
      session.move!(date: d("2026-11-14"))
      moved = latest
      travel_to Time.utc(2026, 11, 13, 12)
      _(_ { moved.refresh.undo!(today: d("2026-11-13")) }.must_raise(PlanChange::NotUndoable).message).must_match(/2026-11-12, has gone by/)
      travel_back

      session.update(status: "skipped")
      _(_ { undo(moved) }.must_raise(PlanChange::NotUndoable).message).must_match(/skipped/)

      removed = plan("2026-11-15").then { it.remove! && latest }
      strength.archive!
      _(_ { undo(removed) }.must_raise(PlanChange::NotUndoable).message).must_equal "its workout is archived"
    end

    it "says whether a change can be taken back, for a list" do
      session = plan("2026-11-12")
      session.move!(date: d("2026-11-14"))
      list = changes
      lookup = PlanChange::Lookup.new(list, today:)

      _(list.map { it.as_json(lookup:)[:undoable] }).must_equal [false, true]
    end
  end
end
