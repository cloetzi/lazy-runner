require "test_helper"

describe "GET /api/history" do
  include RequestHelpers

  it "lists recent sessions newest first with a weekly count" do
    session_on("2026-09-01", "done")
    session_on("2026-10-06", "done")
    session_on("2026-10-08", "skipped")
    session_on("2026-10-13", "done")
    session_on("2026-10-15", "done")

    get "/api/history?days=14&date=2026-10-19"

    _(last_response.status).must_equal 200
    _(json["from"]).must_equal "2026-10-06"
    _(json["sessions"].map { it["date"] }).must_equal %w[2026-10-15 2026-10-13 2026-10-08 2026-10-06]
    _(json["sessions"].first["workout"]["title"]).must_equal "Workout 1"
    _(json["weeks"]).must_equal [
      { "week_start" => "2026-10-19", "done" => 0, "partial" => 0 },
      { "week_start" => "2026-10-12", "done" => 2, "partial" => 0 },
      { "week_start" => "2026-10-05", "done" => 1, "partial" => 0 }
    ]
  end

  it "counts weeks across the turn of the year" do
    session_on("2025-12-29", "done")
    session_on("2026-01-01", "done")
    session_on("2026-01-05", "done")

    get "/api/history?days=14&date=2026-01-06"

    _(json["weeks"]).must_equal [
      { "week_start" => "2026-01-05", "done" => 1, "partial" => 0 },
      { "week_start" => "2025-12-29", "done" => 2, "partial" => 0 },
      { "week_start" => "2025-12-22", "done" => 0, "partial" => 0 }
    ]
  end

  it "does not count a warm-up done on its own as a training day" do
    session_on("2026-10-13", "done", workout: "cycle-1-warmup")
    session_on("2026-10-14", "done")

    get "/api/history?days=7&date=2026-10-19"

    _(json["weeks"].last["done"]).must_equal 1
  end

  it "counts a session ended early apart from the done ones" do
    session_on("2026-10-13", "done")
    early = session_on("2026-10-14", "done")
    Completion.create(session: early, finished_at: Time.now, ended_early: true)

    get "/api/history?days=7&date=2026-10-19"

    _(json["weeks"].last).must_equal({ "week_start" => "2026-10-12", "done" => 1, "partial" => 1 })
    _(json["sessions"].first["completion"]["ended_early"]).must_equal true
  end

  it "includes how each session went" do
    session = session_on("2026-10-19", "in_progress")
    Completion.create(session:, finished_at: Time.now, rpe: 8, feedback: "too_hard")
    SetLog.create(session:, step: step_for("cycle-1-workout-1", "goblet-squat"), set_number: 1, reps: 8)

    get "/api/history?date=2026-10-19"

    _(json["sessions"].first["completion"]["feedback"]).must_equal "too_hard"
    _(json["sessions"].first["sets_done"]).must_equal 1
  end
end
