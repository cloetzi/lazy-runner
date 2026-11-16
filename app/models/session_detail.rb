# frozen_string_literal: true

# One past session as History shows it: the session, how long it took, and
# what was logged per exercise in the order it was done. A swap is grouped
# under the exercise done and names the one planned. Like ExerciseHistory it
# reads only the set logs, so editing the workout later does not change it,
# and weights are in the unit their target was logged in (that of the gear
# the step was done with), else the exercise's. Load the session with
# `set_logs: %i[exercise planned_exercise]` eager.
class SessionDetail
  def initialize(session)
    @session = session
  end

  def as_json(*)
    @session.as_json.merge(minutes:, exercises:)
  end

  # What was logged per step and exercise done, in the order it was done,
  # each set with its target. A block can hold the same exercise twice, so
  # sets group by the step they were logged against (`step_ref`, kept after
  # the step leaves); sets logged before steps were remembered group by
  # block and exercise. `part` says whether it was the main workout or its
  # warm-up or cool-down; a set logged before parts were kept, whose step has
  # gone since, counts as the main workout.
  def exercises
    logs = @session.set_logs.sort_by(&:id)
    logs.group_by { [it.step_ref || [it.block_label, it.planned_exercise_id], it.exercise_id] }.values.map do |sets|
      first = sets.first
      # The unit its target was logged in, that of the gear the step was done
      # with then, else its exercise's.
      unit = sets.filter_map { it.target[:weight] }.first&.dig(:unit) || first.exercise.weight_unit
      {
        exercise: first.exercise.values.slice(:id, :slug, :name),
        instead_of: (first.planned_exercise.values.slice(:id, :slug, :name) if first.swapped?),
        block_label: first.block_label,
        part: first.part || "workout",
        sets: sets.sort_by { [it.set_number, it.side.to_s] }.map do |set|
          {
            set_number: set.set_number, side: set.side, status: set.status,
            reps: set.reps, seconds: set.seconds, weight: Weights.convert(set.weight, unit),
            target: set.target.merge(weight: Weights.convert(set.target[:weight], unit))
          }
        end
      }
    end
  end

  private

  # From the first set or the start to the finish, when both are known.
  def minutes
    finished = @session.completion&.finished_at
    started = @session.started_at
    ((finished - started) / 60.0).round if finished && started && finished > started
  end
end
