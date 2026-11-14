module Api
  class HistoryController < ApplicationController
    # Recent sessions, and per week the sessions done and those ended early.
    # @description Sessions from `days` days up to `date`, newest first, and
    #   per week (Monday to Sunday) how many were `done` and how many ended
    #   early (`partial`). A warm-up or cool-down done on its own is not a
    #   training day.
    # @param date? {Date} The last day, the server's today (TZ) by default.
    # @param days? {Integer} How many days back, 1 to 366; 28 by default.
    # @response 200 #/components/schemas/History
    # @response 400 #/components/responses/BadRequest
    def show
      days = Integer(params[:days] || 28, exception: false)
      raise BadRequest.param(:days, "must be between 1 and 366") unless days&.between?(1, 366)

      to = date_param
      from = to - days + 1
      sessions = Session.summarized.where(date: from..to).reverse(:date, :position, :id).all

      render json: { from: from.iso8601, to: to.iso8601, sessions:, weeks: Session.weeks(sessions, from, to) }
    end

    # Every exercise logged so far, most recently done first.
    # @description Each with the best set of the last day it was done.
    # @response 200 #/components/schemas/LoggedExercises
    def exercises
      render json: ExerciseHistory.logged
    end

    # One exercise's weight and reps per session, newest first.
    # @description Plus the remembered weight.
    # @response 200 #/components/schemas/ExerciseHistory
    # @response 404 #/components/responses/NotFound
    def exercise
      render json: ExerciseHistory.new(Exercise.eager(:remembered, :equipment).find!(params[:id]))
    end
  end
end
