module Api
  class SessionsController < ApplicationController
    # Statuses a client may set directly; "done" comes from /complete.
    SETTABLE_STATUSES = %w[planned in_progress skipped].freeze
    # Sessions in a date range, by day and in order within a day.
    # @description Without dates, the past 28 days up to today, or with
    #   `status=planned` alone the next 28 days from today, to ask what is
    #   planned. With only `from` the range runs 28 days on, with only `to`
    #   28 days back. Future dates are fine; a range is at most 366 days.
    #   A session planned on a day before today reads as `missed`.
    # @param from? {Date} The first day.
    # @param to? {Date} The last day.
    # @param status? Statuses to keep, comma-separated: planned, missed, in_progress, done, skipped.
    # @response 200 #/components/schemas/Sessions
    # @response 400 #/components/responses/BadRequest
    def index
      statuses = status_filter
      days = DateRange.resolve(params[:from], params[:to], back: (0 if statuses == ["planned"]))
      sessions = Session.summarized.where(date: days).in_order
      sessions = sessions.with_status(statuses) if statuses
      render json: sessions.all
    end

    # One session with what was logged in it, exercise by exercise.
    # @description With its length, and swaps named.
    # @response 200 #/components/schemas/SessionDetail
    # @response 404 #/components/responses/NotFound
    def show
      render json: SessionDetail.new(Session.eager(:workout, :completion, set_logs: [{ exercise: :equipment }, :planned_exercise]).find!(params[:id]))
    end

    # Plan or start a session of a workout on a date.
    # @description `status` is planned by default, and a planned session
    #   needs a date of today or later and a workout not archived. `today` is
    #   the client's own date, used for that check when it is within a day of
    #   the server's (TZ), and the day it goes on when `date` is left out.
    #   `started_at` is when a session started `in_progress` began on the
    #   device (now by default, never later). It goes last on its day, or at
    #   `position` (1 first), moving the ones from there on down. `note` is
    #   the planner's reason for it. A `client_ref` the server has seen
    #   answers with that session again (200, not 201), so a client can retry
    #   a create whose response it never got.
    # @request { workout_id: Integer, date?: Date, today?: Date, position?: Integer, status?: [planned, in_progress, skipped], parts?: String, note?: String, created_by?: [manual, llm], client_ref?: String, started_at?: DateTime }
    # @response 201 #/components/schemas/SessionWithPlan
    # @response 200 #/components/schemas/SessionWithPlan
    # @response 400 #/components/responses/BadRequest
    # @response 404 #/components/responses/NotFound
    # @response 422 #/components/responses/Invalid
    def create
      status = params[:status].presence || "planned"
      settable!(status)

      client_ref = params[:client_ref].presence
      today = client_today
      if client_ref && (session = Session.first(client_ref:))
        session.today = today
        return render_with_plan(session)
      end

      begin
        session = Session.add!(
          today:,
          workout: Workout.find!(required!(:workout_id)),
          date: params[:date].present? ? date_param : today,
          position: position_param,
          status:,
          part_kinds: parts_param,
          note: params[:note].presence,
          created_by: params[:created_by].presence || "manual",
          started_at: (client_time(:started_at) || Time.now if status == "in_progress"),
          client_ref:
        )
      rescue Sequel::UniqueConstraintViolation
        # A concurrent create with the same client_ref got there first.
        raise unless client_ref && (session = Session.first(client_ref:))
        session.today = today
        return render_with_plan(session)
      end
      render_with_plan(session, status: :created)
    end

    # Move a session, or change its status, parts or note.
    # @description Fields left out are kept. `date` and `position` move a
    #   session only while it is planned (or missed), the status sent
    #   included, else 409; its own date and place sent again change nothing.
    #   A planned session's new date, or a session made planned again, must
    #   be today or later, counted from `today` as in POST; one made planned
    #   again forgets its start. `started_at` is as in POST. The days it
    #   leaves and joins are renumbered. Finishing goes through
    #   POST /api/sessions/:id/complete. A done session keeps its status and
    #   parts, except that one ended early can be picked up again
    #   (`in_progress`), which takes back its finish.
    # @request { status?: [planned, in_progress, skipped], date?: Date, today?: Date, position?: Integer, parts?: String, note?: String, started_at?: DateTime }
    # @response 200 #/components/schemas/Session
    # @response 400 #/components/responses/BadRequest
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    # @response 422 #/components/responses/Invalid
    def update
      session = Session.find!(params[:id])
      session.today = client_today
      changes = {}
      if params.key?(:status)
        status = params[:status].to_s
        if status == "done"
          raise BadRequest.new("finish a session with POST /api/sessions/:id/complete", fields: { status: ["is set by POST /api/sessions/:id/complete"] })
        end
        settable!(status)
        # Planned again, it hasn't started; started, it keeps its first start.
        given = client_time(:started_at)
        started_at =
          case status
          when "planned" then nil
          when "skipped" then session.started_at
          else session.started_at || given || Time.now
          end
        changes.merge!(status:, started_at:)
        # Picking a run up again marks it active, so it holds its workout.
        resumed = status == "in_progress" && session.status == "in_progress"
      end
      changes[:part_kinds] = parts_param if params.key?(:parts)
      changes[:note] = params[:note].presence if params.key?(:note)
      move = { date: (date_param if params[:date].present?), position: position_param }.compact
      # Its own day and place sent back (a client resending what GET gave)
      # are no move, so they don't refuse a settled session's other changes.
      move.delete(:date) if move[:date] == session.date
      move.delete(:position) if move[:position] == session.position && !move.key?(:date)

      # A move saves the other changes with it, so a session made planned
      # again is checked on its new day.
      Session.db.transaction do
        session.set(changes)
        move.any? ? session.move!(**move) : session.save_changes
        session.update_columns(updated_at: Time.now) if resumed
      end
      render json: session
    end

    # Delete a session and its sets.
    # @description Remembered weights it set fall back to the remaining
    #   history. With `only=planned` (the calendar's Remove) it deletes a
    #   session only while it is planned (or missed), else 409, so a removal
    #   sent late can't erase a session started elsewhere in the meantime.
    # @param only? Set to planned to delete only a planned or missed session.
    # @response 204
    # @response 400 #/components/responses/BadRequest
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    def destroy
      session = Session.find!(params[:id])
      case params[:only].presence
      when nil then session.erase!
      when "planned" then session.remove!
      else raise BadRequest.param(:only, "must be planned")
      end
      head :no_content
    end

    # Log a set: 201 when it is new, 200 when it updates one logged before.
    # @description A set is named by its step, round (`set_number`) and
    #   `side`, so logging it again (after a reload or a retry) updates it. A
    #   set done as a swap names the exercise done in `exercise_id`. The first
    #   set starts a planned session. The player also sends what it showed:
    #   `planned_exercise_id`, `block_label`, `part` and `target`. Those keep a set
    #   whose step the session no longer runs (the workout was edited
    #   elsewhere, or the step's part was left out): it is stored without the
    #   step link, as a set whose step left later is. Without
    #   `planned_exercise_id` such a set is refused (404 for a step that is
    #   gone, 400 for one of a part left out). A step of another workout is
    #   always a 400.
    # @request { step_id: Integer, set_number: Integer, side?: [left, right], reps?: Integer, seconds?: Integer, weight?: { value: Numeric, unit: [lb, kg] }, status?: [done, skipped], exercise_id?: Integer, planned_exercise_id?: Integer, block_label?: String, part?: [warmup, workout, cooldown], target?: { reps?: Integer, seconds?: Integer, weight?: { value: Numeric, unit: [lb, kg] } } }
    # @response 201 #/components/schemas/SetLog
    # @response 200 #/components/schemas/SetLog
    # @response 400 #/components/responses/BadRequest
    # @response 404 #/components/responses/NotFound
    # @response 422 #/components/responses/Invalid
    def sets
      session = Session.find!(params[:id])
      step_ref = Record.id(required!(:step_id)) || raise(BadRequest.param(:step_id, "must be a whole number"))
      step = Step.eager(:block).first(id: step_ref)
      # The step as the session runs it now, or nil when it no longer does. A
      # step of none of the parts its workout can have is no set of it.
      if step && !session.workout.framed_ids.include?(step.block.workout_id)
        raise BadRequest.new("step #{step.id} is not part of this session", fields: { step_id: ["is not part of this session"] })
      end
      linked = step if step && session.workout.framed_ids(session.part_kinds).include?(step.block.workout_id)
      shown = shown_plan(step, step_ref) unless linked

      # A swap names the exercise done instead.
      exercise = params[:exercise_id].present? ? Exercise.find!(params[:exercise_id]) : (linked&.exercise || shown[0])
      weight = exercise.in_weight_unit(params.dig(:weight, :value), params.dig(:weight, :unit))
      attempts = 0
      begin
        log = SetLog.find_or_new(user_id: session.user_id, session_id: session.id, step_ref:, set_number: params[:set_number], side: params[:side].presence)
        created = log.new?
        # The target is the one shown when the set was first logged.
        if created && linked
          log.step_id = linked.id
          log.plan_from(linked, linked.target(ExerciseWeight.first(exercise_id: linked.exercise_id)))
        elsif created
          log.record_plan(*shown)
        end
        # From the step while it exists, else as the player sent it.
        log.part = step ? SetLog.part_of(session, step) : params[:part].presence if created
        log.update(
          exercise_id: exercise.id,
          reps: params[:reps], seconds: params[:seconds],
          weight_value: weight[:value], weight_unit: weight[:value] && weight[:unit],
          status: params[:status].presence || "done"
        )
      rescue Sequel::UniqueConstraintViolation
        # A concurrent post of the same set inserted it between the lookup and
        # the insert; looking it up again finds it and updates it.
        raise if (attempts += 1) > 1
        retry
      end
      session.update(status: "in_progress", started_at: session.started_at || Time.now) if session.status == "planned"
      render json: log, status: created ? :created : :ok
    end

    # Finish a session.
    # @description `ended_early` marks a session finished from End session
    #   before the main workout was through. Calling it again (a retry) keeps
    #   the fields it leaves out; send a field as null to clear it.
    #   `finished_at` is when it finished on the device (now by default,
    #   never later than now nor before its start), so a finish synced late
    #   keeps its place in the day; the first finish stays.
    # @request { rpe?: Integer, feedback?: [too_easy, right, too_hard], note?: String, ended_early?: Boolean, finished_at?: DateTime }
    # @response 200 #/components/schemas/CompletedSession
    # @response 400 #/components/responses/BadRequest
    # @response 404 #/components/responses/NotFound
    # @response 422 #/components/responses/Invalid
    def complete
      session = Session.find!(params[:id])
      completion = Completion.find_or_new(session_id: session.id)
      # A device's finish never goes before the start the server has.
      finished_at = completion.finished_at || [client_time(:finished_at) || Time.now, session.started_at].compact.max
      changes = { finished_at:, **completion_fields(%i[rpe feedback note]) }
      changes[:ended_early] = Record.boolean(params[:ended_early]) || false if params.key?(:ended_early)
      # Together, so a failure leaves the session unfinished and a retry starts over.
      Session.db.transaction do
        completion.update(changes)
        session.update(status: "done")
      end
      # `suggestions` stays, always empty, for a page still on a release from
      # before the app stopped suggesting weights (#264).
      render json: { session: session.refresh, completion:, suggestions: [] }
    end

    # Change a finished session's RPE or note, such as a note added later.
    # @description Fields left out are kept. The feedback is part of the
    #   finish, so it changes through POST /api/sessions/:id/complete.
    # @request { rpe?: Integer, note?: String }
    # @response 200 #/components/schemas/Completion
    # @response 400 #/components/responses/BadRequest
    # @response 404 #/components/responses/NotFound
    # @response 422 #/components/responses/Invalid
    def completion
      if params.key?(:feedback)
        raise BadRequest.new("change the feedback with POST /api/sessions/:id/complete", fields: { feedback: ["is set by POST /api/sessions/:id/complete"] })
      end

      session = Session.find!(params[:id])
      completion = session.completion || raise(Record::NotFound.new(Completion, nil, "session #{session.id} is not finished yet"))
      completion.update(completion_fields(%i[rpe note]))
      render json: completion
    end

    private

    # What the player showed for a set whose step the session no longer runs:
    # the planned exercise, its block and the target, as record_plan takes
    # them. Raises when the request doesn't say which exercise was planned.
    def shown_plan(step, step_ref)
      if params[:planned_exercise_id].blank?
        raise Record::NotFound.new(Step, step_ref) unless step

        raise BadRequest.new("step #{step.id} is not part of this session", fields: { step_id: ["is not part of this session"] })
      end

      planned = Exercise.find!(params[:planned_exercise_id])
      target = params[:target].is_a?(Hash) ? params[:target] : {}
      given = target[:weight].is_a?(Hash) ? target[:weight] : {}
      weight = planned.in_weight_unit(given[:value], given[:unit])
      weight = nil unless weight[:value].is_a?(Numeric) && ExerciseWeight::UNITS.include?(weight[:unit])
      reps, seconds = target.values_at(:reps, :seconds).map { Integer(it.to_s, exception: false) }
      [planned, params[:block_label].presence || step&.block&.label, { reps:, seconds:, weight: }]
    end

    # Where on its day a session goes, 1 first; nil when not given.
    def position_param
      return if params[:position].blank?

      position = Integer(params[:position].to_s, exception: false)
      raise BadRequest.param(:position, "must be a whole number from 1") unless position&.positive?

      position
    end

    def settable!(status)
      raise BadRequest.param(:status, "must be one of #{SETTABLE_STATUSES.join(", ")}") unless SETTABLE_STATUSES.include?(status)
    end

    def render_with_plan(session, status: :ok)
      render json: session.as_json.merge(plan: session.plan), status:
    end

    # The completion fields among `keys` the request sends; blank clears one.
    def completion_fields(keys)
      keys.select { params.key?(it) }.to_h { [it, params[it].presence] }
    end

    # `status=planned,in_progress`, or nil for every status.
    def status_filter
      Session.statuses(params[:status])
    rescue ArgumentError => error
      raise BadRequest.new(error.message, fields: { status: ["must be among #{Session::SHOWN_STATUSES.join(", ")}"] })
    end
  end
end
