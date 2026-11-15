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
    # @param from? {Date} The first day.
    # @param to? {Date} The last day.
    # @param today? {Date} The device's own date, which routine days read against.
    # @response 200 #/components/schemas/Calendar
    # @response 400 #/components/responses/BadRequest
    def show
      days = DateRange.resolve(params[:from], params[:to])
      routines = RoutineCalendar.new(days, today: client_today)
      render json: {
        sessions: Session.summarized.where(date: days).in_order.all,
        activities: Activity.where(date: days).in_order.all,
        notes: CoachNote.eager(:activity, session: :workout).on_days(days).all,
        routines: routines.routines,
        routine_days: routines.days
      }
    end
  end
end
