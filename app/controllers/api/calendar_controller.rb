module Api
  class CalendarController < ApplicationController
    # Everything on the calendar in a date range: sessions, activities, notes and routine days.
    # @description Flat lists, sessions and activities by day and in order within a day:
    #   `sessions` as GET /api/sessions gives them (a planned one on a day
    #   before today reads as `missed`), and `activities` as GET
    #   /api/activities does, and the coach's `notes` dated to a day in it or
    #   about a session or activity on one (a note follows its session when
    #   it moves), in the order written. `routine_days` are the days of `routines` that show
    #   in the range (see GET /api/routines), each with how it reads on
    #   `today`, the device's own date (taken within a day of the server's):
    #   tentative or confirmed from today on, missed before, done or skipped.
    #   Without dates, the past 28 days up to today;
    #   with only `from` the range runs 28 days on, with only `to` 28 days
    #   back. A range is at most 366 days, so a month grid fits.
    #   Each session and routine carries `change`, the latest change an
    #   agent made to it that was not taken back, while the user has not
    #   changed it since (null if none), with
    #   whether it can be taken back now (`undoable`). `plan_changes` are
    #   the sessions an agent moved away from a day in the range or removed
    #   from it, not taken back, for the days of this week on (until their
    #   week is over), by the day they left (`from_date`).
    #   `distance_unit` is the unit distances are shown in (GET /api/settings).
    # @param from? {Date} The first day.
    # @param to? {Date} The last day.
    # @param today? {Date} The device's own date, which routine days read against.
    # @response 200 #/components/schemas/Calendar
    # @response 400 #/components/responses/BadRequest
    def show
      days = DateRange.resolve(params[:from], params[:to])
      today = client_today
      routines = RoutineCalendar.new(days, today:)
      sessions = Session.summarized.where(date: days).in_order.all
      changes = PlanChange::Calendar.new(days, sessions:, routines: routines.routines, today:)
      render json: {
        sessions: sessions.map { it.as_json.merge(change: changes.of(it)) },
        activities: Activity.where(date: days).in_order.all,
        notes: CoachNote.eager(:activity, session: :workout).on_days(days).all,
        routines: routines.routines.map { it.as_json.merge(change: changes.of(it)) },
        routine_days: routines.days,
        plan_changes: changes.lines,
        # The unit distances are shown in, as GET /api/settings gives it.
        distance_unit: Setting.current.distance_unit
      }
    end
  end
end
