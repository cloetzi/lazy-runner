module Api
  class ActivitiesController < ApplicationController
    # Activities in a date range, by day and in the order they started.
    # @description Without dates, the past 28 days up to today. With only
    #   `from` the range runs 28 days on, with only `to` 28 days back; a range
    #   is at most 366 days. `sport` keeps one sport, matched as stored
    #   (trimmed, lowercase).
    # @param from? {Date} The first day.
    # @param to? {Date} The last day.
    # @param sport? One sport, such as run.
    # @response 200 #/components/schemas/Activities
    # @response 400 #/components/responses/BadRequest
    def index
      activities = Activity.where(date: DateRange.resolve(params[:from], params[:to])).in_order
      sport = string_param(:sport)
      activities = activities.of_sport(sport) if sport.present?
      render json: activities.all
    end

    # Log an activity, or a list of them.
    # @description The body is one activity, or `{ "activities": [...] }`
    #   with at most 500. `date` (the sender's own day it started on) and
    #   `sport` are required; the date may not be after `today`, the
    #   sender's own date (taken within a day of the server's). `started_at`
    #   is ISO 8601, and a start later than now is taken as now. Distances
    #   and climb are whole metres, times whole seconds, `rpe` 1 to 10.
    #   Nothing is worked out from the numbers. An activity from somewhere
    #   else names its `source` and its id there (`external_id`). Sending a pair the user already has updates that
    #   activity: the fields sent are written, the ones left out or sent as
    #   null are kept, and `rpe` and `note` are written only while empty, so
    #   what the person entered stays. A pair deleted here and sent again
    #   comes back. A `client_ref` the server has seen answers with that
    #   activity, unchanged. One activity answers 201 when it is new, 200
    #   when it updated one or its `client_ref` was known. A list is all or nothing: it answers 200
    #   with every activity in the order sent (a pair sent twice is logged
    #   once, the later fields winning), or 422 naming the first bad entry
    #   by its place, such as `activities[3].distance_m`.
    # @request #/components/schemas/ActivityWrite
    # @response 201 #/components/schemas/Activity
    # @response 200 #/components/schemas/ActivityOrBatch
    # @response 400 #/components/responses/BadRequest
    # @response 403 #/components/responses/Forbidden
    # @response 409 #/components/responses/Conflict
    # @response 422 #/components/responses/Invalid
    def create
      today = client_today
      unless params.key?(:activities)
        activity, outcome = Activity.log!(params, today:)
        return render json: activity, status: outcome == :created ? :created : :ok
      end

      list = params[:activities]
      raise BadRequest.param(:activities, "must be a list") unless list.is_a?(Array)
      raise BadRequest.param(:activities, "must hold at most #{Activity::BATCH_LIMIT} activities") if list.size > Activity::BATCH_LIMIT

      render json: { activities: Activity.log_all!(list, today:).map(&:first) }
    end

    # Change an activity.
    # @description Fields left out are kept; one sent as null is cleared.
    #   `source` and `external_id` stay as they were sent. `date` and
    #   `started_at` are as in POST, with `today` the sender's own date.
    # @request { date?: Date, today?: Date, started_at?: DateTime, sport?: String, title?: String, moving_seconds?: Integer, elapsed_seconds?: Integer, distance_m?: Integer, climb_m?: Integer, avg_hr?: Integer, max_hr?: Integer, rpe?: Integer, note?: String }
    # @response 200 #/components/schemas/Activity
    # @response 400 #/components/responses/BadRequest
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    # @response 422 #/components/responses/Invalid
    def update
      activity = Activity.find!(params[:id])
      activity.today = client_today
      activity.update(params.slice(*Activity::CHANGEABLE))
      render json: activity
    end

    # Delete an activity.
    # @description One from somewhere else comes back if its source sends it again.
    # @response 204
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    def destroy
      Activity.find!(params[:id]).destroy
      head :no_content
    end
  end
end
