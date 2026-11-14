# Routines (#178): what the user means to do, tentatively. A weekly routine
# ("run every Wednesday") or a one-off ("maybe a hike on Saturday") is either
# a sport, fulfilled by a logged activity of that sport on its day, or one of
# the user's workouts, fulfilled by a session of it.
#
# Days are worked out from the routine when the calendar is read; only the
# days the user changed are stored (`routine_days`: confirmed, skipped, or
# moved to another day). A workout routine's confirmed day is a planned
# session, linked by `sessions.routine_id` + `routine_date`, which is the only
# link between the two. An activity linked to a day by hand names it the same
# way. Those links are plain keys set to null when the routine is deleted (a
# composite key would null user_id too); the models check they are the same
# user's. Each is an ADD COLUMN, so no table is copied.
Sequel.migration do
  up do
    create_table(:routines) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :title
      # A sport (kept as Activity.sport keeps it), or one of the user's workouts.
      String :sport
      Integer :workout_id
      # ISO weekdays, Monday 1 to Sunday 7, as JSON; empty for a one-off.
      column :weekdays, :json, null: false, default: "[]"
      Date :starts_on, null: false
      # A one-off starts and ends on its day.
      Date :ends_on
      Integer :minutes
      Integer :distance_m
      String :effort
      String :note, text: true
      String :created_by, null: false, default: "manual"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      foreign_key %i[user_id workout_id], :workouts, key: %i[user_id id], name: :fk_routines_workout
      index %i[user_id starts_on], name: :index_routines_on_user_id_and_starts_on
      index %i[user_id workout_id], name: :index_routines_on_workout_id
      constraint(:routines_what, Sequel.lit("(sport IS NULL) <> (workout_id IS NULL)"))
      constraint(:routines_sport) { (sport =~ nil) | (Sequel.function(:length, Sequel.function(:trim, :sport)) > 0) }
      constraint(:routines_effort) { (effort =~ nil) | Sequel.expr(effort: %w[easy moderate hard]) }
      constraint(:routines_created_by, created_by: %w[manual llm])
      constraint(:routines_ends) { (ends_on =~ nil) | (ends_on >= starts_on) }
      constraint(:routines_numbers) { ((minutes =~ nil) | (minutes > 0)) & ((distance_m =~ nil) | (distance_m > 0)) }
    end

    create_table(:routine_days) do
      primary_key :id
      foreign_key :routine_id, :routines, null: false, on_delete: :cascade
      # The routine's own day, as its weekdays give it.
      Date :date, null: false
      String :status, null: false
      # The day it was moved to; a confirmed or skipped day may have been
      # moved first.
      Date :moved_to
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[routine_id date], unique: true, name: :index_routine_days_on_routine_id_and_date
      index :moved_to, name: :index_routine_days_on_moved_to
      constraint(:routine_days_status, status: %w[confirmed skipped moved])
      constraint(:routine_days_moved) { Sequel.~(status: "moved") | Sequel.~(moved_to: nil) }
    end

    alter_table(:sessions) do
      add_foreign_key :routine_id, :routines, on_delete: :set_null
      add_column :routine_date, Date
      add_index %i[routine_id routine_date], unique: true, where: Sequel.~(routine_id: nil), name: :index_sessions_on_routine_day
    end

    alter_table(:activities) do
      add_foreign_key :routine_id, :routines, on_delete: :set_null
      add_column :routine_date, Date
      add_index %i[routine_id routine_date], unique: true, where: Sequel.~(routine_id: nil), name: :index_activities_on_routine_day
    end
  end

  down do
    alter_table(:activities) do
      drop_index %i[routine_id routine_date], name: :index_activities_on_routine_day
      drop_foreign_key :routine_id
      drop_column :routine_date
    end
    alter_table(:sessions) do
      drop_index %i[routine_id routine_date], name: :index_sessions_on_routine_day
      drop_foreign_key :routine_id
      drop_column :routine_date
    end
    drop_table(:routine_days)
    drop_table(:routines)
  end
end
