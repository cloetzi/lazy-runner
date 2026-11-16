# frozen_string_literal: true

# A record of changes to the plan: one row per change to one planned
# session or routine, by the user in the app (`manual`) or an agent over MCP
# (`llm`, named by its token), with what it was before and after, the reason
# given, and the change it takes back when it is an undo. The links to the
# session, the routine and the change undone are plain keys set to null when
# that row goes (a composite key would null user_id too); the model checks
# they are the same user's. A new table, so nothing is copied.
Sequel.migration do
  up do
    create_table(:plan_changes) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :changed_by, null: false
      String :agent_name
      String :item_kind, null: false
      foreign_key :session_id, :sessions, on_delete: :set_null
      foreign_key :routine_id, :routines, on_delete: :set_null
      String :title
      String :action, null: false
      Date :from_date
      Date :to_date
      column :was, :json
      column :now, :json
      String :reason, text: true
      String :batch, null: false
      foreign_key :undoes_id, :plan_changes, on_delete: :set_null
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[user_id created_at], name: :index_plan_changes_on_user_id_and_created_at
      index %i[user_id from_date], name: :index_plan_changes_on_user_id_and_from_date
      index :session_id, name: :index_plan_changes_on_session_id
      index :routine_id, name: :index_plan_changes_on_routine_id
      # A change is taken back once.
      index :undoes_id, unique: true, where: Sequel.~(undoes_id: nil), name: :index_plan_changes_on_undoes_id
      constraint(:plan_changes_changed_by, changed_by: %w[manual llm])
      constraint(:plan_changes_item_kind, item_kind: %w[session routine])
      constraint(:plan_changes_action, action: %w[planned moved removed changed ended])
      constraint(:plan_changes_item) { Sequel.~(item_kind: "session") | (routine_id =~ nil) }
      constraint(:plan_changes_routine_item) { Sequel.~(item_kind: "routine") | (session_id =~ nil) }
    end
  end

  down do
    drop_table(:plan_changes)
  end
end
