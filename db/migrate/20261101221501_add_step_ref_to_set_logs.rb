# A set log names the step it was logged against in `step_ref`, which stays
# when the step leaves (`step_id` is nulled then). It tells two steps of the
# same exercise in a block apart in history, and lets a set the player logs
# for a step deleted under it (another device edited the workout) be stored
# and logged again without a duplicate. The set's identity moves to it.
Sequel.migration do
  up do
    alter_table(:set_logs) { add_column :step_ref, Integer }
    self[:set_logs].update(step_ref: :step_id)
    alter_table(:set_logs) do
      drop_index nil, name: :index_set_logs_on_set
      add_index [:session_id, :step_ref, :set_number, Sequel.function(:coalesce, :side, "")], unique: true, name: :index_set_logs_on_set
    end
  end

  down do
    alter_table(:set_logs) do
      drop_index nil, name: :index_set_logs_on_set
      add_index [:session_id, :step_id, :set_number, Sequel.function(:coalesce, :side, "")], unique: true, name: :index_set_logs_on_set
      drop_column :step_ref
    end
  end
end
