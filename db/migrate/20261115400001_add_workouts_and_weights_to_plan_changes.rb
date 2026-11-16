# frozen_string_literal: true

# Workout edits and remembered weights join the record of plan changes:
# a workout changed or archived (`item_kind` workout, `workout_id`) and
# an exercise's remembered weight set (`weight`, `exercise_id`), with a
# readable `summary` of what a workout edit changed. Both links are plain
# keys going null with their row, as the session and routine ones are.
# Changing the CHECKs copies the table on SQLite, and the copy keeps none of
# them nor the partial index on `undoes_id`, so all are made again.
Sequel.migration do
  up do
    alter_table(:plan_changes) do
      add_foreign_key :workout_id, :workouts, on_delete: :set_null
      add_foreign_key :exercise_id, :exercises, on_delete: :set_null
      add_column :summary, String, text: true
    end
    alter_table(:plan_changes) do
      drop_constraint :plan_changes_item_kind
      drop_constraint :plan_changes_action
    end
    alter_table(:plan_changes) do
      add_constraint(:plan_changes_changed_by, changed_by: %w[manual llm])
      add_constraint(:plan_changes_item_kind, item_kind: %w[session routine workout weight])
      add_constraint(:plan_changes_action, action: %w[planned moved removed changed ended archived])
      add_constraint(:plan_changes_item) do
        Sequel.~(item_kind: "session") | ((routine_id =~ nil) & (workout_id =~ nil) & (exercise_id =~ nil))
      end
      add_constraint(:plan_changes_routine_item) do
        Sequel.~(item_kind: "routine") | ((session_id =~ nil) & (workout_id =~ nil) & (exercise_id =~ nil))
      end
      add_constraint(:plan_changes_workout_item) do
        Sequel.~(item_kind: "workout") | ((session_id =~ nil) & (routine_id =~ nil) & (exercise_id =~ nil))
      end
      add_constraint(:plan_changes_weight_item) do
        Sequel.~(item_kind: "weight") | ((session_id =~ nil) & (routine_id =~ nil) & (workout_id =~ nil))
      end
    end
    # Apart: Sequel adds CHECKs in one copy only when nothing else is in the block.
    alter_table(:plan_changes) do
      add_index :undoes_id, unique: true, where: Sequel.~(undoes_id: nil), name: :index_plan_changes_on_undoes_id
      add_index :workout_id, name: :index_plan_changes_on_workout_id
      add_index :exercise_id, name: :index_plan_changes_on_exercise_id
    end
  end

  down do
    self[:plan_changes].where(item_kind: %w[workout weight]).delete
    alter_table(:plan_changes) do
      drop_index :workout_id, name: :index_plan_changes_on_workout_id
      drop_index :exercise_id, name: :index_plan_changes_on_exercise_id
      drop_constraint :plan_changes_workout_item
      drop_constraint :plan_changes_weight_item
      drop_column :summary
      drop_foreign_key :workout_id
      drop_foreign_key :exercise_id
    end
    alter_table(:plan_changes) do
      add_constraint(:plan_changes_changed_by, changed_by: %w[manual llm])
      add_constraint(:plan_changes_item_kind, item_kind: %w[session routine])
      add_constraint(:plan_changes_action, action: %w[planned moved removed changed ended])
      add_constraint(:plan_changes_item) { Sequel.~(item_kind: "session") | (routine_id =~ nil) }
      add_constraint(:plan_changes_routine_item) { Sequel.~(item_kind: "routine") | (session_id =~ nil) }
    end
    alter_table(:plan_changes) do
      add_index :undoes_id, unique: true, where: Sequel.~(undoes_id: nil), name: :index_plan_changes_on_undoes_id
    end
  end
end
