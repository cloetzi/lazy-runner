module TrainerMcp
  class TrainingSummary < Tool
    description <<~TEXT.squish
      What the user trained over a date range (the last 28 days by default): every session, oldest
      first, with its status, workout and how it felt (RPE 1-10, feedback too_easy, right or
      too_hard, a note, whether it ended early), and per exercise its `part` (warmup, workout or
      cooldown: the main workout or what framed it), the target and what was done
      (sets done and skipped, reps or seconds per set, the weights used; a `per_side` exercise
      counts a set once for both sides and lists reps left then right; `instead_of` names the
      exercise planned when it was swapped). Planned sessions in the range are listed too, and a planned one whose day has gone by reads as missed. `weeks`
      counts the main workouts done per week (Monday to Sunday). Also the remembered weight of every
      exercise (0 for done without one). The app suggests no weights: the sets, RPE and feedback are what to
      recommend a change from. Weights are in each
      exercise's unit. A week only partly in the range says how many of its `days` it covers.
    TEXT
    input_schema(
      properties: {
        from: { type: "string", format: "date", description: "First day, YYYY-MM-DD. Default: 27 days before `to`." },
        to: { type: "string", format: "date", description: "Last day, YYYY-MM-DD; may be in the future. Default: today, or 27 days after `from` when only that is given." }
      }
    )
    annotations(title: "Training summary", **READ_ONLY)

    def self.answer(from: nil, to: nil)
      range = days(from, to)
      from, to = range.begin, range.end

      sessions = Session.eager({ workout: { blocks: :steps } }, :completion, set_logs: [{ exercise: :equipment }, :planned_exercise])
        .where(date: from..to).in_order.all

      compact(
        **today_and_weekday, from: from.iso8601, to: to.iso8601,
        weeks: weeks(sessions, from, to),
        sessions: sessions.map { session(it) },
        remembered_weights: remembered_weights
      )
    end

    def self.session(session)
      shown = session.as_json
      shown.except(:client_ref, :started_at, :sets_done).merge(
        workout: shown[:workout].slice(:id, :title, :kind, :archived),
        completion: session.completion&.as_json&.except(:finished_at),
        exercises: exercises(session).presence
      )
    end

    # Done sessions per week as History counts them; a week the range only
    # partly covers says how many of its days it covers.
    def self.weeks(sessions, from, to)
      Session.weeks(sessions, from, to).map do |week|
        start = Date.iso8601(week[:week_start])
        days = ([start + 6, to].min - [start, from].max).to_i + 1
        days < 7 ? week.merge(days:) : week
      end
    end

    # What was logged per exercise, as History shows it (a swap under the
    # exercise done, naming the one planned), each summed up: the first set's
    # target, the sets done and skipped (a set is done when a side of it is),
    # and what the done ones were.
    def self.exercises(session)
      SessionDetail.new(session).exercises.map do |logged|
        sets = logged[:sets]
        done = sets.select { it[:status] == "done" }
        per_side = sets.any? { it[:side] }
        rounds = ->(list) { list.map { it[:set_number] }.uniq }
        {
          exercise: logged[:exercise][:slug], name: logged[:exercise][:name],
          instead_of: logged[:instead_of]&.dig(:slug),
          block: logged[:block_label], part: logged[:part],
          per_side: (true if per_side),
          target: sets.first[:target],
          sets_done: rounds.(done).size,
          sets_skipped: (rounds.(sets) - rounds.(done)).size,
          reps: done.filter_map { it[:reps] }.presence,
          seconds: done.filter_map { it[:seconds] }.presence,
          weights: done.filter_map { it[:weight] }.uniq.presence
        }
      end
    end

    def self.remembered_weights
      ExerciseWeight.eager(exercise: :equipment).all.sort_by { it.exercise.name }.map do
        { exercise: it.exercise.slug, name: it.exercise.name, **remembered_weight(it, it.exercise.weight_unit), updated: it.updated_at.in_time_zone.to_date.iso8601 }
      end
    end
  end
end
