module Api
  class TodayController < ApplicationController
    NO_WORKOUTS = "there is no workout to train yet: import an example program or build a workout".freeze

    # What to do today, ready for the player.
    # @description The main card is `session_id` if given, else the day's
    #   first session under way, else its first planned one, else the last
    #   done or skipped, else the main workout after the last one done (the
    #   rotation, `source: default`: the first program's, else the user's
    #   own). It comes with the sets already `logged` in it and the player's
    #   `plan`. With no main workout on the day, a warm-up or cool-down
    #   planned or under way on its own makes the card. Each part (warm-up,
    #   workout, cool-down) says whether this session runs it (`included`); a
    #   session already under way or done keeps its own parts. `day` lists every session on the date in order,
    #   and `next_planned` is the first planned after it. `activities` are the
    #   date's activities, in the order they started, and `routine_days` the
    #   days of `routines` that show on it, read with the date as today
    #   (tentative, confirmed, done or skipped). `trained` says whether any
    #   session was ever done, so a first session can be told apart from a
    #   rest day. `changes` are the edits an agent made to its parts and the
    #   weights it set for their exercises, each item's latest while nothing
    #   was trained since and it was not taken back. With nothing to
    #   suggest (no main workout yet), it is a 404 with the code
    #   `no_workouts`: import an example program or build a workout first.
    # @param date? {Date} The day, the server's today (TZ) by default. The PWA sends its local date.
    # @param session_id? {Integer} One of the day's sessions instead of the one up next; 404 for another day's.
    # @param workout_id? {Integer} Another workout instead of the one up next.
    # @param parts? Which parts to run, such as workout,cooldown; all of them by default.
    # @response 200 #/components/schemas/Today
    # @response 400 #/components/responses/BadRequest
    # @response 404 #/components/responses/NotFound
    def show
      date = date_param
      chosen = params[:session_id].presence
      picked = params[:workout_id].presence unless chosen
      session = chosen ? Session.eager(:set_logs, :completion).where(date:).find!(chosen) : day_session(date, picked)

      main, source =
        if picked
          [Workout.find!(picked), "picked"]
        elsif session
          [session.workout, "session"]
        else
          [Workout.suggested, "default"]
        end
      return render_error(:not_found, "no_workouts", NO_WORKOUTS) unless main
      # Picking a workout again after doing or skipping it starts a new session.
      session = nil unless session&.workout_id == main.id && (source == "session" || %w[planned in_progress].include?(session.status))
      kinds = %w[in_progress done].include?(session&.status) ? session.part_kinds : parts_param
      parts = main.framed(kinds)
      # Summaries read each workout's minutes from its blocks and steps.
      summarized = Session.eager(:set_logs, :completion, workout: { blocks: :steps })
      setting = Setting.current

      render json: {
        date: date.iso8601,
        source:,
        session: session&.as_json(today: date),
        # Every session on the day, and the next one planned after it.
        day: summarized.where(date:).in_order.all.map { it.as_json(today: date) },
        next_planned: summarized.where(status: "planned", date: date.next_day..).in_order.first&.as_json(today: date),
        trained: !Session.where(status: "done").empty?,
        activities: Activity.where(date:).in_order.all,
        **routine_days(date),
        # The sets already logged in the session, so the player can pick up
        # where it was left.
        logged: session ? session.set_logs.map { { step_id: it.step_ref, **it.values.slice(:set_number, :side, :status) } } : [],
        program: main.program && { id: main.program.id, name: main.program.name },
        workout_id: main.id,
        title: main.title,
        subtitle: main.subtitle,
        estimated_minutes: parts.sum(&:estimated_minutes),
        # Every part the workout can have, and whether this session runs it.
        workouts: main.framed.map { it.summary.merge(included: parts.map(&:id).include?(it.id)) },
        plan: PlayerPlan.new(parts),
        changes: PlanChange.standing(
          workout_ids: parts.map(&:id), exercise_ids: parts.flat_map { |part| part.blocks.flat_map { it.steps.map(&:exercise_id) } },
          today: date, untrained: true
        ),
        weight_steps: Coach.weight_steps,
        # The units weights and distances are shown in.
        unit: setting.unit,
        distance_unit: setting.distance_unit
      }
    end

    private

    # The routines with a day on the date, and those days, read with the
    # date as today.
    def routine_days(date)
      calendar = RoutineCalendar.new(date..date, today: date)
      { routines: calendar.routines, routine_days: calendar.days }
    end

    # The day's session for the card: of the picked workout, else of a main
    # workout. A warm-up or cool-down on its own makes the card only while it
    # is planned or under way, as there is nothing else to do that day; done,
    # it isn't a training day, and the rotation is offered as on a rest day.
    def day_session(date, picked)
      sessions = Session.eager(:set_logs, :completion)
      return sessions.where(workout_id: picked).for_day(date) if picked

      sessions.where(workout_id: Workout.where(kind: "workout").select(:id)).for_day(date) ||
        sessions.where(status: %w[planned in_progress]).for_day(date)
    end
  end
end
