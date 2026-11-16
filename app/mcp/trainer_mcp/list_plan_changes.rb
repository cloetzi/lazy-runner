# frozen_string_literal: true

module TrainerMcp
  class ListPlanChanges < Tool
    description <<~TEXT.squish
      What changed in the plan, newest first: sessions and routines planned, moved, removed, changed or ended,
      workouts edited or archived (`item_kind: workout`, with a `summary` of what changed; get_workout gives the
      workout as it is now) and remembered weights set (`item_kind: weight`, `was` and `now` the value and unit), each
      with who did it (`manual` the user in the app, `llm` you or another agent, named by `agent_name`), when, the
      days it left (`from_date`) and joined (`to_date`), the fields before (`was`) and after (`now`), the reason given,
      and `undone: true` when the user took it back. Start planning with it: it shows what the user changed since you
      last planned. A change of yours they took back is their answer: don't make it again unless they ask. Distances
      are in metres here.
    TEXT
    input_schema(
      properties: {
        since: { type: "string", format: "date",
                 description: "The first day of changes, YYYY-MM-DD; #{PlanChange::DEFAULT_DAYS} days back unless given." },
        by: { type: "string", enum: PlanChange::BY, description: "Only the user's (manual) or agents' (llm) changes." }
      }
    )
    annotations(title: "List plan changes", **READ_ONLY)

    def self.answer(since: nil, by: nil)
      today = Current.today
      from = since ? days(since, since).begin : today - PlanChange::DEFAULT_DAYS
      raise Problem, "since must be today (#{today.iso8601}) or earlier" if from > today
      raise Problem, "since must be within #{DateRange::MAX_DAYS} days of today" if (today - from).to_i >= DateRange::MAX_DAYS

      changes = PlanChange.list(from..today, by:).all
      lookup = PlanChange::Lookup.new(changes, today:)
      { **today_and_weekday, changes: changes.map { change(it, lookup) } }
    end

    # A change, its fields without a value left out but for `was` and `now`,
    # where a null says a field was (or became) empty.
    def self.change(change, lookup)
      compact(
        id: change.id, action: change.action, item_kind: change.item_kind, session_id: change.session_id,
        routine_id: change.routine_id, workout_id: change.workout_id, exercise_id: change.exercise_id,
        title: change.title, summary: change.summary, by: change.changed_by, agent_name: change.agent_name,
        at: change.created_at.iso8601, from_date: change.from_date&.iso8601, to_date: change.to_date&.iso8601,
        reason: change.reason, undoes: change.undoes_id, undone: (true if change.undone?(lookup))
      ).merge(change.before_and_after.compact)
    end
  end
end
