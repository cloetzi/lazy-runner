# The part of the session a set was logged in (warmup, workout or cooldown),
# kept on the set like its block and target, so History and the coach can
# tell the main workout from its framing after the workout changes (#265).
# Sets logged before are filled in from their step where it still exists:
# the session's own workout is the main one, anything else is the kind of
# the warm-up or cool-down it framed it with.
Sequel.migration do
  up do
    alter_table(:set_logs) { add_column :part, String }
    from(:set_logs).update(
      part: from(:steps)
        .join(:blocks, id: :block_id)
        .join(:workouts, id: :workout_id)
        .join(Sequel[:sessions].as(:s), id: Sequel[:set_logs][:session_id])
        .where(Sequel[:steps][:id] => Sequel[:set_logs][:step_ref])
        .select(Sequel.case([[Sequel[:workouts][:id] =~ Sequel[:s][:workout_id], "workout"]], Sequel[:workouts][:kind]))
    )
  end

  down do
    alter_table(:set_logs) { drop_column :part }
  end
end
