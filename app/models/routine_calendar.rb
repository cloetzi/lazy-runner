# The days of the user's routines that show on a range of days, each with
# how it reads on `today` and what fulfils it. Nothing of this is stored but
# the days the user changed (RoutineDay) and the links sessions and
# activities keep to a day.
#
# A day shows `on` its own date, the day it was moved to, or the date of the
# session planned for it. It reads as:
#
# - `done`: fulfilled. A sport routine by an activity linked to the day by
#   hand, else by the earliest activity on its day of the same sport family
#   (Sport) that no other day took: the day's routines choose in id order,
#   after the hand links, and an activity linked by hand never fulfils
#   another day. A workout routine by its session once done, else by a done
#   session of its workout on its day that no other day took.
# - `skipped`: the user said not this week (or skipped its session).
# - `confirmed`: the user said they're going (a workout routine's session
#   planned or under way), from today on.
# - `tentative`: nothing said, from today on.
# - `missed`: tentative or confirmed, on a day before today: it didn't happen.
class RoutineCalendar
  STATES = %w[tentative confirmed done skipped missed].freeze

  # `date` is the routine's own day; `stored` the RoutineDay, `session` the
  # one planned for it, `activity` (or `fulfilled_by`, a session) what
  # fulfilled it; `linked` when the activity was linked by hand.
  Day = Struct.new(:routine, :date, :on, :state, :confirmed, :stored, :session, :activity, :fulfilled_by, :linked, keyword_init: true) do
    def as_json(*)
      {
        routine_id: routine.id, date: date.iso8601, on: on.iso8601, state:, confirmed:,
        moved: on != date, session_id: (session || fulfilled_by)&.id, activity_id: activity&.id, linked:
      }
    end

    def to_json(*args) = as_json.to_json(*args)
  end

  # How one day of `routine` reads.
  def self.day(routine, date, today: Time.zone.today)
    on = Session.first(routine_id: routine.id, routine_date: date)&.date ||
         RoutineDay.first(routine_id: routine.id, date:)&.moved_to || date
    new(on..on, today:).days.find { it.routine.id == routine.id && it.date == date } ||
      raise(Record::NotFound.new(RoutineDay, date.iso8601, "routine #{routine.id} has no day #{date.iso8601}"))
  end

  attr_reader :range, :today

  def initialize(range, today: Time.zone.today)
    @range = range
    @today = today
  end

  # The routines with days that show in the range, by id.
  def routines = days && @routines

  # The days that show in the range, by the day they show on, then routine.
  def days
    @days ||= build
  end

  private

  def build
    moved_in = RoutineDay.where(moved_to: range).all
    sessions_in = Session.exclude(routine_id: nil).where(date: range).all
    ids = Routine.running_in(range).select_map(:id) | moved_in.map(&:routine_id) | sessions_in.map(&:routine_id)
    @routines = Routine.where(id: ids).eager(:workout).order(:id).all.each { it.today = today }
    by_id = @routines.to_h { [it.id, it] }

    # Every (routine, date) that may show in the range.
    candidates = @routines.flat_map { |routine| routine.dates_in(range).map { [routine.id, it] } }
    candidates |= moved_in.map { [it.routine_id, it.date] } | sessions_in.map { [it.routine_id, it.routine_date] }
    candidates.select! { |id, date| by_id[id]&.day?(date) }
    dates = candidates.map(&:last).uniq

    stored = RoutineDay.where(routine_id: ids, date: dates).all.to_h { [[it.routine_id, it.date], it] }
    sessions = Session.where(routine_id: ids, routine_date: dates).eager(:workout).all.to_h { [[it.routine_id, it.routine_date], it] }
    hand = Activity.where(routine_id: ids, routine_date: dates).all.to_h { [[it.routine_id, it.routine_date], it] }

    days = candidates.map do |id, date|
      session = sessions[[id, date]]
      kept = stored[[id, date]]
      Day.new(routine: by_id[id], date:, on: session&.date || kept&.moved_to || date, stored: kept, session:, activity: hand[[id, date]], linked: hand.key?([id, date]))
    end
    days.select! { range.cover?(it.on) }
    days.sort_by! { [it.on, it.routine.id, it.date] }
    fulfil(days)
    days
  end

  # Works out each day's state, giving activities and sessions to the days
  # they fulfil.
  def fulfil(days)
    ons = days.map(&:on).uniq
    activities = Activity.where(date: ons, routine_id: nil).in_order.all
    workouts = days.filter_map { it.routine.workout_id }.uniq
    done_sessions = workouts.empty? ? [] : Session.where(date: ons, workout_id: workouts, routine_id: nil, status: "done").order(:id).all

    days.each do |day|
      routine = day.routine
      if routine.workout_id
        workout_day(day, done_sessions)
      else
        day.activity ||= (claim(activities) { it.date == day.on && Sport.same?(it.sport, routine.sport) } unless day.stored&.status == "skipped")
        day.state = if day.activity then "done"
                    elsif day.stored&.status == "skipped" then "skipped"
                    else open_state(day, day.stored&.status == "confirmed")
                    end
      end
      day.confirmed = false if day.confirmed.nil?
    end
  end

  def workout_day(day, done_sessions)
    if (session = day.session)
      day.state =
        case session.status
        when "done" then "done"
        when "skipped" then "skipped"
        else open_state(day, true)
        end
      day.confirmed = %w[planned in_progress].include?(session.status)
      day.state = "confirmed" if session.status == "in_progress"
    elsif day.stored&.status == "skipped"
      day.state = "skipped"
    elsif (done = claim(done_sessions) { it.date == day.on && it.workout_id == day.routine.workout_id })
      day.fulfilled_by = done
      day.state = "done"
    else
      day.state = open_state(day, day.stored&.status == "confirmed")
    end
  end

  # Tentative or confirmed, missed once its day has gone by.
  def open_state(day, confirmed)
    day.confirmed = confirmed
    return "missed" if day.on < today

    confirmed ? "confirmed" : "tentative"
  end

  # Takes the first item that matches out of `items`.
  def claim(items, &matches)
    index = items.index(&matches)
    index && items.delete_at(index)
  end
end
