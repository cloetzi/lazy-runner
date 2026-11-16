# frozen_string_literal: true

module Api
  class RoutinesController < ApplicationController
    # The user's routines: what they mean to do, tentatively.
    # @description Each is a sport (fulfilled by an activity of the same
    #   family: run, running and trail run are all runs) or one of the user's
    #   workouts (fulfilled by a session of it), weekly on its `weekdays` or
    #   a one-off on `starts_on`. Their days are on GET /api/calendar. Those
    #   ended before `today` are left out unless `ended` is true. By start,
    #   then as planned.
    # @param ended? {Boolean} Routines that ended too.
    # @param today? {Date} The device's own date.
    # @response 200 #/components/schemas/Routines
    # @response 400 #/components/responses/BadRequest
    def index
      routines = Routine.eager(:workout).in_order
      routines = routines.current(client_today) unless boolean_param(:ended)
      render json: { routines: routines.all }
    end

    # Plan a routine.
    # @description Weekly on `weekdays` from `starts_on` (today or later,
    #   today when left out), or a one-off on `starts_on` when `weekdays` is
    #   empty. A one-off sent with `confirmed: true` has its day confirmed at
    #   once (Planned rather than Maybe); for a workout routine that plans
    #   the session.
    # @request #/components/schemas/RoutineInput
    # @response 201 #/components/schemas/Routine
    # @response 400 #/components/responses/BadRequest
    # @response 403 #/components/responses/Forbidden
    # @response 409 #/components/responses/Conflict
    # @response 422 #/components/responses/Invalid
    def create
      routine = Routine.plan!(params.slice(*Routine::FIELDS), today: client_today, confirmed: boolean_param(:confirmed) || false)
      render json: routine, status: :created
    end

    # Change a routine.
    # @description Fields left out are kept; one sent as null is cleared.
    #   Days gone by never change: changing when a routine runs (`weekdays`,
    #   `sport`, `workout_id` or `starts_on`) once it has days before today
    #   ends it yesterday and starts a new routine today with the change,
    #   which is what this answers. Its days from today on that the user
    #   changed, and the sessions planned for them, move to it while they are
    #   still among its days (a session only for the same workout); else
    #   they go, and sessions still planned come off the calendar. Title,
    #   note, effort, minutes, distance and `ends_on` change in place;
    #   `ends_on` may not be before yesterday. A one-off on a day gone by, or
    #   an ended routine's schedule, can't change (409).
    # @request #/components/schemas/RoutineInput
    # @response 200 #/components/schemas/Routine
    # @response 400 #/components/responses/BadRequest
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    # @response 422 #/components/responses/Invalid
    def update
      routine = Routine.find!(params[:id])
      routine.today = client_today
      render json: routine.revise!(params.slice(*Routine::FIELDS))
    end

    # End a routine.
    # @description One with days before today ends yesterday and keeps
    #   them, and answers 200 with it; one without is deleted (204). Its days
    #   from today on go, and sessions still planned for them come off the
    #   calendar. A routine that has already ended is deleted with its
    #   history (204); what fulfilled its days stays on the calendar.
    # @param today? {Date} The device's own date.
    # @response 200 #/components/schemas/Routine
    # @response 204
    # @response 400 #/components/responses/BadRequest
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    def destroy
      routine = Routine.find!(params[:id])
      routine.today = client_today
      return head :no_content if routine.end!(erase: routine.ended?) == :deleted

      render json: routine
    end

    # Confirm, skip or move a day of a routine.
    # @description `date` is one of the routine's own days. `confirmed`
    #   ("I'm going") needs the day (or the day it moved to) to be today or
    #   later; for a workout routine it plans a session of its workout on
    #   that day. `skipped` ("Not this week") skips its session too. `moved`
    #   puts it on `moved_to`, today or later, where it reads as before; its
    #   own date takes the move back. A day already done answers 409, as
    #   does a session that is no longer planned.
    # @request #/components/schemas/RoutineDayChange
    # @response 200 #/components/schemas/RoutineDay
    # @response 400 #/components/responses/BadRequest
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    # @response 422 #/components/responses/Invalid
    def update_day
      routine = Routine.find!(params[:id])
      routine.today = client_today
      day =
        case params[:status]
        when "confirmed" then routine.confirm!(params[:date])
        when "skipped" then routine.skip!(params[:date])
        when "moved" then routine.move!(params[:date], required!(:moved_to))
        else raise BadRequest.param(:status, "must be confirmed, skipped or moved")
        end
      render json: day
    end

    # Make a day of a routine tentative again.
    # @description On its own date, with nothing confirmed, skipped or
    #   moved; a session planned for it comes off the calendar (409 once it
    #   has started).
    # @param today? {Date} The device's own date.
    # @response 200 #/components/schemas/RoutineDay
    # @response 400 #/components/responses/BadRequest
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    def reset_day
      routine = Routine.find!(params[:id])
      routine.today = client_today
      render json: routine.reset!(params[:date])
    end
  end
end
