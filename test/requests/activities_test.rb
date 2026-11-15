require "test_helper"

describe "activities API" do
  include RequestHelpers

  before { travel_to Time.utc(2026, 11, 2, 12) }
  after { travel_back }

  let(:loop_run) { { date: "2026-11-01", sport: "Run", title: "Easy loop", moving_seconds: 1800, distance_m: 5000, climb_m: 40 } }

  def logged(**entry) = Activity.log!({ date: "2026-11-01", sport: "run", **entry }).first

  describe "POST /api/activities" do
    it "logs one activity as sent, with nothing worked out from it" do
      post_json "/api/activities", loop_run

      _(last_response.status).must_equal 201
      _(json.slice("date", "sport", "title", "moving_seconds", "distance_m", "climb_m", "rpe", "created_by"))
        .must_equal("date" => "2026-11-01", "sport" => "run", "title" => "Easy loop", "moving_seconds" => 1800,
          "distance_m" => 5000, "climb_m" => 40, "rpe" => nil, "created_by" => "manual")
      _(Activity.count).must_equal 1
    end

    it "updates an activity its source sends again, keeping the person's RPE and note" do
      post_json "/api/activities", **loop_run, source: "garmin", external_id: "123"
      id = json["id"]
      patch_json "/api/activities/#{id}", rpe: 6, note: "windy"

      post_json "/api/activities", **loop_run, source: "garmin", external_id: "123", distance_m: 5050, rpe: 2, note: nil

      _(last_response.status).must_equal 200
      _(json["id"]).must_equal id
      _(json.slice("distance_m", "rpe", "note", "title")).must_equal("distance_m" => 5050, "rpe" => 6, "note" => "windy", "title" => "Easy loop")
    end

    it "answers a client_ref it has seen with that activity again" do
      post_json "/api/activities", **loop_run, client_ref: "activity:abc"
      id = json["id"]

      post_json "/api/activities", **loop_run, client_ref: "activity:abc", distance_m: 1

      _(last_response.status).must_equal 200
      _(json["id"]).must_equal id
      _(json["distance_m"]).must_equal 5000
    end

    it "refuses a day after the sender's today, counted from their own date" do
      post_json "/api/activities", **loop_run, date: "2026-11-03"
      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal("date" => ["must not be after today"])

      post_json "/api/activities", **loop_run, date: "2026-11-03", today: "2026-11-03"
      _(last_response.status).must_equal 201
    end

    it "says what is wrong with an activity" do
      post_json "/api/activities", date: "soon", rpe: 0, distance_m: 2.5

      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal(
        "date" => ["is invalid"], "sport" => ["can't be blank"], "rpe" => ["must be in 1..10"], "distance_m" => ["must be an integer"]
      )
    end

    describe "a list" do
      it "logs every entry, all at once, and answers them in the order sent" do
        post_json "/api/activities", activities: [loop_run, { date: "2026-10-30", sport: "ride", source: "garmin", external_id: "9" }]

        _(last_response.status).must_equal 200
        _(json["activities"].map { it["sport"] }).must_equal %w[run ride]
        _(Activity.count).must_equal 2
      end

      it "logs nothing when an entry is wrong, and names it by its place" do
        post_json "/api/activities", activities: [loop_run, loop_run.merge(climb_m: -3)]

        _(last_response.status).must_equal 422
        _(json["error"]["fields"]).must_equal("activities[1].climb_m" => ["must be greater than or equal to 0"])
        _(json["error"]["message"]).must_equal "activities[1]: Climb m must be greater than or equal to 0"
        _(Activity.count).must_equal 0
      end

      it "takes at most 500" do
        post_json "/api/activities", activities: Array.new(501) { loop_run }

        _(last_response.status).must_equal 400
        _(json["error"]["fields"]).must_equal("activities" => ["must hold at most 500 activities"])
      end

      it "must be a list" do
        post_json "/api/activities", activities: loop_run

        _(last_response.status).must_equal 400
        _(json["error"]["fields"]).must_equal("activities" => ["must be a list"])
      end
    end
  end

  describe "GET /api/activities" do
    it "lists a range of days in order, of one sport when asked" do
      ride = logged(date: "2026-10-20", sport: "ride")
      walk = logged(date: "2026-10-31", sport: "walk")
      logged(date: "2026-09-01")

      get "/api/activities?from=2026-10-01&to=2026-10-31"
      _(json.map { it["id"] }).must_equal [ride.id, walk.id]

      get "/api/activities?from=2026-10-01&to=2026-10-31&sport=Walk"
      _(json.map { it["id"] }).must_equal [walk.id]
    end

    it "refuses a range it can't read" do
      get "/api/activities?from=2026-11-01&to=2026-10-01"

      _(last_response.status).must_equal 400
    end
  end

  describe "PATCH /api/activities/:id" do
    it "changes what it is sent, clears what is sent as null, and keeps where it came from" do
      activity = logged(source: "garmin", external_id: "1", rpe: 5, title: "Run")

      patch_json "/api/activities/#{activity.id}", note: "hills", rpe: nil, source: "other", external_id: "2"

      _(last_response.status).must_equal 200
      _(json.slice("note", "rpe", "title", "source", "external_id")).must_equal("note" => "hills", "rpe" => nil, "title" => "Run", "source" => "garmin", "external_id" => "1")
    end

    it "moves an activity to another day up to the sender's today" do
      activity = logged

      patch_json "/api/activities/#{activity.id}", date: "2026-11-03"
      _(last_response.status).must_equal 422

      patch_json "/api/activities/#{activity.id}", date: "2026-10-29"
      _(json["date"]).must_equal "2026-10-29"
    end
  end

  describe "DELETE /api/activities/:id" do
    it "deletes an activity" do
      activity = logged

      delete "/api/activities/#{activity.id}"

      _(last_response.status).must_equal 204
      _(Activity.count).must_equal 0
      delete "/api/activities/#{activity.id}"
      _(last_response.status).must_equal 404
    end
  end

  describe "GET /api/calendar" do
    it "gives a range's sessions and activities as two lists, a whole month grid at once" do
      session = Session.plan!(workout: workout("cycle-1-workout-1"), date: Date.new(2026, 11, 20))
      activity = logged(date: "2026-10-27")

      get "/api/calendar?from=2026-10-26&to=2026-12-06"

      _(last_response.status).must_equal 200
      _(json["sessions"].map { it["id"] }).must_equal [session.id]
      _(json["activities"].map { it["id"] }).must_equal [activity.id]
    end

    it "takes at most 366 days" do
      get "/api/calendar?from=2026-01-01&to=2027-01-02"

      _(last_response.status).must_equal 400
    end
  end

  it "goes with today's card, with the unit distances are shown in" do
    activity = logged(date: "2026-11-02")
    logged(date: "2026-11-01")
    Setting.current.update(distance_unit: "mi")

    get "/api/today?date=2026-11-02"

    _(json["activities"].map { it["id"] }).must_equal [activity.id]
    _(json["distance_unit"]).must_equal "mi"
  end

  it "goes on the calendar, with the unit distances are shown in" do
    activity = logged(date: "2026-11-02")
    Setting.current.update(distance_unit: "mi")

    get "/api/calendar?from=2026-11-02&to=2026-11-08"

    _(json["activities"].map { it["id"] }).must_equal [activity.id]
    _(json["distance_unit"]).must_equal "mi"
  end

  describe "another user's" do
    before do
      @someone = create_user("someone")
      Current.set(user: @someone) do
        @theirs = Activity.log!({ date: "2026-11-01", sport: "run", source: "garmin", external_id: "77", client_ref: "activity:shared" }).first
      end
    end

    it "are left out of every list" do
      get "/api/activities?from=2026-10-01&to=2026-11-02"
      _(json).must_be_empty

      get "/api/calendar?from=2026-10-01&to=2026-11-02"
      _(json["activities"]).must_be_empty

      get "/api/today?date=2026-11-01"
      _(json["activities"]).must_be_empty
    end

    it "can't be changed or deleted: 404" do
      patch_json "/api/activities/#{@theirs.id}", note: "mine now"
      _(last_response.status).must_equal 404

      delete "/api/activities/#{@theirs.id}"
      _(last_response.status).must_equal 404
      _(Activity.of(@someone.id).count).must_equal 1
    end

    it "don't match the same source id or client_ref: each user gets their own" do
      post_json "/api/activities", date: "2026-11-01", sport: "ride", source: "garmin", external_id: "77"
      _(last_response.status).must_equal 201
      _(json["id"]).wont_equal @theirs.id

      post_json "/api/activities", date: "2026-11-01", sport: "ride", client_ref: "activity:shared"
      _(last_response.status).must_equal 201
      _(Activity.of(@someone.id).first.sport).must_equal "run"
    end
  end
end
