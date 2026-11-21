# frozen_string_literal: true

module Api
  class CheckInsController < ApplicationController
    # The user's check-ins in a date range, by day.
    # @description A day has `night` (the night that ended that morning, as
    #   Garmin dates sleep and overnight HRV) and `day` (how the user felt
    #   that day), each null when nothing was logged; a day with neither is
    #   left out. Without dates, the past 28 days up to today; with only
    #   `from` the range runs 28 days on, with only `to` 28 days back; a range
    #   is at most 366 days.
    # @param from? {Date} The first day.
    # @param to? {Date} The last day.
    # @response 200 #/components/schemas/CheckIns
    # @response 400 #/components/responses/BadRequest
    def index
      render json: { check_ins: CheckIn.where(date: DateRange.resolve(params[:from], params[:to])).in_order.all }
    end

    # Write a day's night or day check-in.
    # @description `group` is night or day; the body is that group whole, and
    #   a field left out or sent as null is cleared, so sending nothing
    #   clears the group. Night: `sleep` (poor, ok, good), `drinks` (none,
    #   1-2, 3+), `tags` (late_to_bed, ate_late, travelling, woke_a_lot),
    #   `note`. Day: `feeling` (rough, ok, good), `stress` (low, normal,
    #   high), `sore` (no, a_bit, a_lot), `sore_areas` (knees, calves,
    #   achilles, shins, hamstrings, hips, back, other), `ill`, `note`. Notes
    #   are at most 500 characters. The date may not be after `today`, the
    #   sender's own date (taken within a day of the server's). Answers the
    #   day's check-in, or 204 when nothing is left on it. With an API token,
    #   a group the user logged is refused (403): an agent only fills what is
    #   empty, through MCP `log_check_in`.
    # @request #/components/schemas/CheckInWrite
    # @response 200 #/components/schemas/CheckIn
    # @response 204
    # @response 400 #/components/responses/BadRequest
    # @response 403 #/components/responses/Forbidden
    # @response 422 #/components/responses/Invalid
    def update
      fields = params.slice(*CheckIn::FIELDS.fetch(CheckIn.group!(params[:group])).keys)
      check_in = CheckIn.write!(params[:date], params[:group], fields)
      check_in ? render(json: check_in) : head(:no_content)
    end

    # Clear a day's night or day check-in.
    # @description Answers what is left of the day, or 204 when nothing is.
    # @response 200 #/components/schemas/CheckIn
    # @response 204
    # @response 403 #/components/responses/Forbidden
    # @response 422 #/components/responses/Invalid
    def destroy
      check_in = CheckIn.clear!(params[:date], params[:group])
      check_in ? render(json: check_in) : head(:no_content)
    end
  end
end
