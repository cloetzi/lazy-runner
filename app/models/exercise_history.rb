# frozen_string_literal: true

# What the signed-in user did of one exercise over time: every session of
# theirs with a done set of it, newest first, with the sets as logged. Sets done as a swap for another
# exercise count for the exercise actually done. Everything comes from the set
# logs themselves, so editing a workout later does not change it. Weights are
# all in the exercise's unit, whatever they were logged in.
class ExerciseHistory
  def initialize(exercise)
    @exercise = exercise
  end

  # Every exercise with a done set, most recently done first, with the best
  # set of the last day it was done (heaviest, then most reps or seconds).
  def self.logged
    exercise_id = Sequel[:set_logs][:exercise_id]
    date = Sequel[:sessions][:date]
    last = SetLog.done.join(:sessions, id: :session_id).group(exercise_id)
      .select_map([exercise_id, Sequel.function(:max, date).as(:last_date),
                   Sequel.function(:count, Sequel[:sessions][:id]).distinct.as(:sessions)])
      .map { |id, day, count| [id, Date.iso8601(day.to_s), count] }
    exercises = Exercise.eager(:remembered, :equipment).where(id: last.map(&:first)).all.index_by(&:id)
    best = best_sets_of_last_day(exercises)
    last.sort { |(a, a_date), (b, b_date)| [b_date, exercises[a].name] <=> [a_date, exercises[b].name] }.map do |id, day, count|
      exercise = exercises[id]
      remembered = Weights.convert(exercise.remembered&.weight, exercise.weight_unit)
      { id:, slug: exercise.slug, name: exercise.name, last_date: day.iso8601, sessions: count, remembered:, last_set: best[id] }
    end
  end

  def self.best_sets_of_last_day(exercises)
    logs = Sequel[:logs]
    days = Sequel[:days]
    last_day = SetLog.db.from(Sequel.as(:set_logs, :logs)).join(Sequel.as(:sessions, :days), id: logs[:session_id])
      .where(logs[:user_id] => Sequel[:set_logs][:user_id], logs[:exercise_id] => Sequel[:set_logs][:exercise_id],
             logs[:status] => "done")
      .select(Sequel.function(:max, days[:date]))
    SetLog.done.where(Sequel[:set_logs][:exercise_id] => exercises.keys).join(:sessions, id: :session_id)
      .where(Sequel[:sessions][:date] => last_day).select_all(:set_logs).all
      .group_by(&:exercise_id).to_h do |id, logs_of_day|
      unit = exercises[id].weight_unit
      set = logs_of_day.max_by { [Weights.convert(it.weight, unit)&.dig(:value) || 0, it.reps || it.seconds || 0, -it.id] }
      [id, { reps: set.reps, seconds: set.seconds, weight: Weights.convert(set.weight, unit) }]
    end
  end
  private_class_method :best_sets_of_last_day

  def sessions
    logs = SetLog.done.for_exercise(@exercise.id).eager(session: :workout).order(:set_number, :side, :id).all
    logs.group_by(&:session).sort_by { |session, _| [session.date, session.id] }.reverse.map do |session, sets|
      {
        session_id: session.id, date: session.date.iso8601, status: session.status, workout: session.workout.summary,
        sets: sets.map do |set|
          {
            set_number: set.set_number, block_label: set.block_label, side: set.side,
            reps: set.reps, seconds: set.seconds, weight: in_unit(set.weight),
            target: set.target.merge(weight: in_unit(set.target[:weight])), swapped: set.swapped?
          }
        end
      }
    end
  end

  def as_json(*)
    {
      exercise: @exercise.values.slice(:id, :slug, :name).merge(timed: @exercise.timed?, unit:),
      remembered: @exercise.remembered&.then { it.as_json.merge(in_unit(it.weight) || {}) },
      sessions:
    }
  end

  private

  def unit = @exercise.weight_unit

  def in_unit(weight) = Weights.convert(weight, unit)
end
