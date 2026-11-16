# frozen_string_literal: true

# The Coach tab (#179): the user's goals, which anchor it, and the coach's
# notes (status, focus, concerns and a journal), written by the user, a
# coach they name, or an agent.
#
# Only the user writes active goals. An agent proposes one (status
# `proposed`, maybe replacing `replaces_id`), and the user accepts or
# dismisses it; a dismissed one stays, so the agent sees it was turned down.
#
# The current status or focus is the newest note of its kind, so nothing
# marks which one replaced which, and two written at once can't both be
# current. A note may name the day, activity or session it is about. Those
# links are plain foreign keys set to null when what they name is deleted
# (a composite one with the user's id would set user_id to null too); the
# models check they are the same user's.
Sequel.migration do
  up do
    create_table(:goals) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :title, null: false
      String :why, text: true
      Date :target_date
      String :status, null: false, default: "active"
      Integer :position, null: false, default: 0
      String :created_by, null: false, default: "user"
      # For a proposal: why the agent proposes it, and the goal it would change.
      String :proposed_reason, text: true
      foreign_key :replaces_id, :goals, on_delete: :set_null
      # When a proposal was accepted or dismissed, or a goal achieved or dropped.
      DateTime :decided_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[user_id status position], name: :index_goals_on_user_id_and_status
      index :replaces_id, name: :index_goals_on_replaces_id
      constraint(:goals_title) { Sequel.function(:length, Sequel.function(:trim, :title)) > 0 }
      constraint(:goals_status, status: %w[active achieved dropped proposed dismissed])
      constraint(:goals_created_by, created_by: %w[user llm])
    end

    create_table(:coach_notes) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :kind, null: false
      String :title
      String :body, text: true, null: false
      String :author_kind, null: false
      String :author_name
      Date :date
      foreign_key :activity_id, :activities, on_delete: :set_null
      foreign_key :session_id, :sessions, on_delete: :set_null
      # A concern's: when it was resolved, and how.
      DateTime :resolved_at
      String :resolution, text: true
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[user_id kind id], name: :index_coach_notes_on_user_id_and_kind
      index %i[user_id date], name: :index_coach_notes_on_user_id_and_date
      index :activity_id, name: :index_coach_notes_on_activity_id
      index :session_id, name: :index_coach_notes_on_session_id
      constraint(:coach_notes_kind, kind: %w[status focus concern note])
      constraint(:coach_notes_author_kind, author_kind: %w[user human llm])
      constraint(:coach_notes_body) { Sequel.function(:length, Sequel.function(:trim, :body)) > 0 }
      constraint(:coach_notes_resolved) { (resolved_at =~ nil) | (kind =~ "concern") }
    end
  end

  down do
    drop_table(:coach_notes)
    drop_table(:goals)
  end
end
