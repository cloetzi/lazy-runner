# frozen_string_literal: true

module Api
  class PlanChangesController < ApplicationController
    # Changes to the plan, newest first: sessions and routines planned, moved, removed, changed or ended.
    # @description By the user in the app (`manual`) or an agent with an API
    #   token (`llm`, named in `agent_name`), on the days they were made
    #   (the server's days): without dates the past 28 days up to today,
    #   with only `from` 28 days on, with only `to` 28 days back, at most
    #   366 days. `undoable` says whether POST
    #   /api/plan_changes/:id/undo can take it back on `today`, the
    #   device's own date (taken within a day of the server's).
    # @param from? {Date} The first day changes were made on.
    # @param to? {Date} The last day.
    # @param by? Only changes by manual (the user) or llm (an agent).
    # @param today? {Date} The device's own date, which undo counts from.
    # @response 200 #/components/schemas/PlanChanges
    # @response 400 #/components/responses/BadRequest
    def index
      by = params[:by].presence
      raise BadRequest.param(:by, "must be manual or llm") if by && !PlanChange::BY.include?(by)

      changes = PlanChange.list(DateRange.resolve(params[:from], params[:to]), by:).all
      lookup = PlanChange::Lookup.new(changes, today: client_today)
      render json: { changes: changes.map { it.as_json(lookup:) } }
    end

    # Take a change back.
    # @description Runs the same change the other way, recorded as the
    #   user's change with `undoes_id` naming this one: a moved session goes
    #   back to its day and place, a removed one is planned again as a new
    #   session (same workout, day, note, parts and planner), a note, parts
    #   or routine changed get their old values, and an ended routine is
    #   planned again from `today`. Only the latest change to an item, once,
    #   and only into a day from `today` on (the device's own date, as in
    #   GET); a planned item is removed or ended instead. Otherwise 409, with
    #   a sentence saying why, and nothing changes. An ended routine's
    #   sessions that went with it come back on it while their days are to
    #   come. Only the user takes a change back, in the app: with an API
    #   token, 403.
    # @request { today?: Date }
    # @response 200 #/components/schemas/PlanUndo
    # @response 400 #/components/responses/BadRequest
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    def undo
      change = PlanChange.find!(params[:id])
      today = client_today
      taken_back = change.undo!(today:)
      lookup = PlanChange::Lookup.new([change, taken_back], today:)
      render json: { change: taken_back.as_json(lookup:), undone: change.as_json(lookup:) }
    end
  end
end
