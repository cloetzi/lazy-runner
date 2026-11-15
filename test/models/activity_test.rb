require "test_helper"

describe Activity do
  let(:today) { Date.new(2026, 11, 2) }

  before { travel_to Time.utc(2026, 11, 2, 12) }
  after { travel_back }

  def log(**entry) = Activity.log!({ date: "2026-11-01", sport: "run", **entry }, today:)

  describe "what it keeps" do
    it "keeps the sport trimmed, lowercase and with single spaces" do
      activity, = log(sport: "  Trail   RUN ")

      _(activity.sport).must_equal "trail run"
      _(Activity.of_sport("Trail Run").select_map(:id)).must_equal [activity.id]
    end

    it "reads another app's sport names as plain words" do
      _(%w[TrailRun mountain_bike VirtualRide].map { log(sport: it).first.sport }).must_equal ["trail run", "mountain bike", "virtual ride"]
    end

    it "finds a known client_ref and source id sent with spaces around them" do
      first, = log(client_ref: "activity:1", source: "garmin", external_id: "9")

      _(log(client_ref: " activity:1 ").first.id).must_equal first.id
      _(log(source: " garmin", external_id: 9).last).must_equal :updated
    end

    it "keeps no title when none is given, and blank text as nothing" do
      activity, = log(title: "  ", note: "", source: " ")

      _(activity.title).must_be_nil
      _(activity.note).must_be_nil
      _(activity.source).must_be_nil
    end

    it "takes an id at its source as text, whatever it was sent as" do
      activity, = log(source: "garmin", external_id: 1234567)

      _(activity.external_id).must_equal "1234567"
    end

    it "takes a start as ISO 8601 and keeps it in UTC" do
      activity, = log(started_at: "2026-11-01T07:30:00-07:00")

      _(activity.started_at.utc).must_equal Time.utc(2026, 11, 1, 14, 30)
    end

    it "takes a start reported later than now as now" do
      activity, = log(date: "2026-11-02", started_at: "2026-11-02T18:00:00Z")

      _(activity.started_at).must_equal Time.now
    end

    it "refuses a start that isn't ISO 8601" do
      error = _ { log(started_at: "this morning") }.must_raise Sequel::ValidationFailed

      _(error.errors.to_h).must_equal(started_at: ["must be a time as ISO 8601"])
    end

    it "refuses a day after the sender's today, and takes today itself" do
      error = _ { log(date: "2026-11-03") }.must_raise Sequel::ValidationFailed
      _(error.errors.to_h).must_equal(date: ["must not be after today"])

      _(log(date: "2026-11-02").first.date).must_equal today
    end

    it "lets an old activity be changed without checking its day again" do
      activity, = log(date: "2026-10-01")
      activity.today = Date.new(2026, 9, 1)

      _(activity.update(note: "felt good").note).must_equal "felt good"
    end

    it "takes only whole numbers of 0 or more, and an RPE of 1 to 10" do
      error = _ { log(distance_m: -1, moving_seconds: 1.5, avg_hr: "fast", rpe: 11) }.must_raise Sequel::ValidationFailed

      _(error.errors.to_h).must_equal(
        distance_m: ["must be greater than or equal to 0"],
        moving_seconds: ["must be an integer"],
        avg_hr: ["is not a number"],
        rpe: ["must be in 1..10"]
      )
    end

    it "needs a day and a sport, and a source for an id from one" do
      error = _ { Activity.log!({ external_id: "9" }, today:) }.must_raise Sequel::ValidationFailed

      _(error.errors.to_h).must_equal(
        date: ["can't be blank"],
        sport: ["can't be blank"],
        source: ["can't be blank when external_id is given"]
      )
    end
  end

  describe "sent again from its source" do
    it "updates the fields sent and keeps the ones left out or sent as null" do
      first, outcome = log(source: "garmin", external_id: "a1", title: "Lunch run", distance_m: 5000, avg_hr: 150)
      _(outcome).must_equal :created

      again, outcome = log(source: "garmin", external_id: "a1", distance_m: 5120, avg_hr: nil)

      _(outcome).must_equal :updated
      _(again.id).must_equal first.id
      _(again.distance_m).must_equal 5120
      _(again.title).must_equal "Lunch run"
      _(again.avg_hr).must_equal 150
      _(Activity.count).must_equal 1
    end

    it "never overwrites the RPE or note the person gave, but fills them while empty" do
      first, = log(source: "garmin", external_id: "a1")
      log(source: "garmin", external_id: "a1", rpe: 4, note: "from the watch")
      _(first.refresh.rpe).must_equal 4

      first.update(rpe: 7, note: "legs heavy")
      log(source: "garmin", external_id: "a1", rpe: 3, note: "watch says easy")

      _(first.refresh.rpe).must_equal 7
      _(first.note).must_equal "legs heavy"
    end

    it "keeps two sources' ids apart, and two users' too" do
      log(source: "garmin", external_id: "a1")
      log(source: "suunto", external_id: "a1")
      someone = create_user("someone")
      Current.set(user: someone) { Activity.log!({ date: "2026-11-01", sport: "ride", source: "garmin", external_id: "a1" }, today:) }

      _(Activity.count).must_equal 2
      _(Activity.of(someone.id).count).must_equal 1
    end

    it "comes back once deleted, if it is sent again" do
      first, = log(source: "garmin", external_id: "a1")
      first.destroy

      again, outcome = log(source: "garmin", external_id: "a1")

      _(outcome).must_equal :created
      _(again.id).wont_equal first.id
    end

    it "answers a known client_ref with that activity, unchanged" do
      first, = log(client_ref: "activity:1", distance_m: 3000)

      again, outcome = log(client_ref: "activity:1", distance_m: 9000)

      _(outcome).must_equal :known
      _(again.id).must_equal first.id
      _(again.distance_m).must_equal 3000
    end
  end

  describe ".log_all!" do
    it "logs every entry and answers them in the order given" do
      logged = Activity.log_all!([{ date: "2026-10-31", sport: "ride" }, { "date" => "2026-11-01", "sport" => "swim" }], today:)

      _(logged.map { |activity, outcome| [activity.sport, outcome] }).must_equal [["ride", :created], ["swim", :created]]
      _(Activity.count).must_equal 2
    end

    it "matches an id sent as a whole number with a fraction to the same id" do
      Activity.log_all!([{ date: "2026-11-01", sport: "run", source: "garmin", external_id: 18_234_567_890 }], today:)
      logged = Activity.log_all!([{ date: "2026-11-01", sport: "run", source: "garmin", external_id: 18_234_567_890.0, distance_m: 5000 }], today:)

      _(logged.map(&:last)).must_equal [:updated]
      _(Activity.select_map(%i[external_id distance_m])).must_equal [["18234567890", 5000]]
    end

    it "logs a pair sent twice once, the later fields winning" do
      logged = Activity.log_all!([
        { date: "2026-11-01", sport: "run", source: "garmin", external_id: "a1", distance_m: 5000, rpe: 4 },
        { date: "2026-11-01", sport: "run", source: "garmin", external_id: "a1", distance_m: 5100, rpe: 6 }
      ], today:).map(&:first)

      _(logged.map(&:id).uniq.size).must_equal 1
      _(logged.first.distance_m).must_equal 5100
      _(logged.first.rpe).must_equal 6
    end

    it "looks the list up once, finding what it named before and what it logged itself" do
      Activity.log_all!([{ date: "2026-10-30", sport: "run", source: "garmin", external_id: "a1" }, { date: "2026-10-30", sport: "ride", client_ref: "r1" }], today:)
      log = StringIO.new
      logger = Logger.new(log)
      Activity.db.loggers << logger
      logged = begin
        Activity.log_all!([
          { date: "2026-10-30", sport: "run", source: "garmin", external_id: "a1", distance_m: 8000 },
          { date: "2026-10-30", sport: "ride", client_ref: "r1" },
          { date: "2026-10-31", sport: "swim", client_ref: "r2" },
          { date: "2026-10-31", sport: "swim", client_ref: "r2" },
          { date: "2026-10-31", sport: "walk", source: "strava", external_id: "s9" }
        ], today:)
      ensure
        Activity.db.loggers.delete(logger)
      end

      _(logged.map(&:last)).must_equal %i[updated known created known created]
      _(logged[2].first.id).must_equal logged[3].first.id
      _(log.string.scan(/SELECT \* FROM .activities. WHERE/).size).must_equal 2
    end

    it "answers a row found by its pair and by its client_ref as the same" do
      Activity.log_all!([{ date: "2026-10-30", sport: "run", source: "garmin", external_id: "a1", client_ref: "r1" }], today:)

      logged = Activity.log_all!([{ source: "garmin", external_id: "a1", rpe: 7 }, { date: "2026-10-30", sport: "run", client_ref: "r1" }], today:)

      _(logged.map(&:last)).must_equal %i[updated known]
      _(logged.map { it.first.rpe }).must_equal [7, 7]
    end

    it "logs nothing when one entry can't be logged, and names it by its place" do
      error = _ {
        Activity.log_all!([{ date: "2026-11-01", sport: "run" }, { date: "2026-11-01", sport: "run", distance_m: -5 }], today:)
      }.must_raise Activity::EntryInvalid

      _(error.fields).must_equal("activities[1].distance_m" => ["must be greater than or equal to 0"])
      _(Activity.count).must_equal 0
    end

    it "names the first bad entry, and a merged pair by its first place" do
      error = _ {
        Activity.log_all!([{ date: "bad", sport: "run" }, 5], today:)
      }.must_raise Activity::EntryInvalid
      _(error.fields.keys).must_equal ["activities[0].date"]

      error = _ {
        Activity.log_all!([
          { date: "2026-11-01", sport: "run", source: "w", external_id: "1", distance_m: -1 },
          { date: "2026-11-01", sport: "run" },
          { source: "w", external_id: "1", title: "Again" }
        ], today:)
      }.must_raise Activity::EntryInvalid
      _(error.fields.keys).must_equal ["activities[0].distance_m"]
    end

    it "refuses a list or object as an id rather than keeping it as text" do
      error = _ { log(source: "garmin", external_id: { id: 5 }) }.must_raise Sequel::ValidationFailed

      _(error.errors.to_h).must_equal(external_id: ["is invalid"])
    end

    it "names an entry that isn't an object" do
      error = _ { Activity.log_all!([{ date: "2026-11-01", sport: "run" }, "run"], today:) }.must_raise Activity::EntryInvalid

      _(error.fields).must_equal("activities[1]" => ["must be an object"])
    end
  end

  it "keeps a day in the order its activities started, unstarted ones as logged" do
    late, = log(started_at: "2026-11-01T18:00:00Z", sport: "walk")
    early, = log(started_at: "2026-11-01T06:00:00Z")
    yesterday, = log(date: "2026-10-31")

    _(Activity.in_order.select_map(:id)).must_equal [yesterday, early, late].map(&:id)
  end

  it "goes with its user" do
    someone = create_user("someone")
    Current.set(user: someone) { Activity.log!({ date: "2026-11-01", sport: "run" }, today:) }

    User.with_pk(someone.id).destroy

    _(Activity.everyone.count).must_equal 0
  end
end
