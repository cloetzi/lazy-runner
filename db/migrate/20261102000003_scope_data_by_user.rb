# frozen_string_literal: true

# Every user's data is their own. The personal tables are dropped and
# made again with a `user_id` (deleted with its user), so nothing kept from
# before belongs to anyone: the data of the one-user install goes. The
# exercise library and the equipment catalogue stay, shared and seeded; what
# each user owns of the equipment moves to `user_equipment`.
#
# Composite foreign keys keep a reference within one user: a session's
# workout, a workout's program, warm-up and cool-down, and a set log's or
# suggestion's session are the same user's, so another user's id can't be
# stored even by a bug. Blocks, steps and completions belong to a user
# through their workout or session, and go with it.
#
# Before the tables go, a database with data in them is copied aside to
# storage/<name>.before-per-user.sqlite3 (VACUUM INTO, outside a transaction).
Sequel.migration do
  no_transaction

  up do
    personal = %i[weight_suggestions completions set_logs sessions exercise_weights step_equipment steps blocks workouts programs settings]
    file = opts[:database].to_s
    if file != "" && file != ":memory:" && File.exist?(file) && personal.any? { !self[it].empty? }
      backup = file.sub(/(\.sqlite3)?\z/, ".before-per-user.sqlite3")
      run("VACUUM INTO #{literal(backup)}") unless File.exist?(backup)
    end

    transaction do
      personal.each { drop_table(it) }

      alter_table(:equipment) do
        drop_column :owned
        drop_column :weights
        # Dropped from the seeds while users still list it as theirs.
        add_column :retired, TrueClass, null: false, default: false
      end

      create_table(:user_equipment) do
        primary_key :id
        foreign_key :user_id, :users, null: false, on_delete: :cascade
        foreign_key :equipment_id, :equipment, null: false, on_delete: :cascade
        TrueClass :owned, null: false
        # The weights owned, in the equipment's unit, for fixed-weight
        # equipment such as dumbbells.
        column :weights, :json, null: false, default: "[]"
        DateTime :created_at, null: false
        DateTime :updated_at, null: false

        index %i[user_id equipment_id], unique: true, name: :index_user_equipment_on_user_id_and_equipment_id
        index :equipment_id, name: :index_user_equipment_on_equipment_id
      end

      create_table(:settings) do
        primary_key :id
        foreign_key :user_id, :users, null: false, on_delete: :cascade
        String :unit, null: false, default: "lb"
        DateTime :created_at, null: false
        DateTime :updated_at, null: false

        index :user_id, unique: true, name: :index_settings_on_user_id
        constraint(:settings_unit, unit: %w[lb kg])
      end

      create_table(:programs) do
        primary_key :id
        foreign_key :user_id, :users, null: false, on_delete: :cascade
        String :slug
        String :name, null: false
        String :description, text: true
        String :source, null: false, default: "seed"
        DateTime :created_at, null: false
        DateTime :updated_at, null: false

        index %i[user_id id], unique: true, name: :index_programs_on_user_id_and_id
        index %i[user_id slug], unique: true, where: { source: "seed" }, name: :index_programs_on_slug
        constraint(:programs_source, source: %w[seed user llm])
        constraint(:programs_seed_slug) { (source !~ "seed") | (slug !~ nil) }
      end

      create_table(:workouts) do
        primary_key :id
        foreign_key :user_id, :users, null: false, on_delete: :cascade
        Integer :program_id
        String :slug
        String :kind, null: false
        String :title, null: false
        String :subtitle
        Integer :position, null: false
        String :source, null: false, default: "seed"
        Integer :warmup_id
        Integer :cooldown_id
        TrueClass :no_warmup, null: false, default: false
        TrueClass :no_cooldown, null: false, default: false
        DateTime :archived_at
        DateTime :created_at, null: false
        DateTime :updated_at, null: false

        foreign_key %i[user_id program_id], :programs, key: %i[user_id id], name: :fk_workouts_program
        foreign_key %i[user_id warmup_id], :workouts, key: %i[user_id id], name: :fk_workouts_warmup
        foreign_key %i[user_id cooldown_id], :workouts, key: %i[user_id id], name: :fk_workouts_cooldown
        index %i[user_id id], unique: true, name: :index_workouts_on_user_id_and_id
        index %i[user_id program_id], name: :index_workouts_on_program_id
        index %i[user_id slug], unique: true, where: { source: "seed" }, name: :index_workouts_on_slug
        index %i[user_id warmup_id], name: :index_workouts_on_warmup_id
        index %i[user_id cooldown_id], name: :index_workouts_on_cooldown_id
        constraint(:workouts_source, source: %w[seed user llm])
        constraint(:workouts_seed_slug) { (source !~ "seed") | ((slug !~ nil) & (program_id !~ nil)) }
        constraint(:workouts_framing) { ~(no_warmup & (warmup_id !~ nil)) & ~(no_cooldown & (cooldown_id !~ nil)) }
      end

      create_table(:blocks) do
        primary_key :id
        foreign_key :workout_id, :workouts, null: false, on_delete: :cascade
        String :label, null: false
        Integer :position, null: false
        Integer :rounds, null: false, default: 1
        Integer :rest_seconds, null: false, default: 0
        DateTime :created_at, null: false
        DateTime :updated_at, null: false

        index :workout_id, name: :index_blocks_on_workout_id
        index %i[workout_id label], unique: true, name: :index_blocks_on_workout_id_and_label
        constraint(:blocks_rounds) { rounds >= 1 }
        constraint(:blocks_rest_seconds) { rest_seconds >= 0 }
      end

      create_table(:steps) do
        primary_key :id
        foreign_key :block_id, :blocks, null: false, on_delete: :cascade
        foreign_key :exercise_id, :exercises, null: false
        Integer :position, null: false
        Integer :reps
        Integer :duration_seconds
        String :tempo
        BigDecimal :weight_value, size: [6, 2]
        String :weight_unit
        Integer :weights_held
        TrueClass :per_side, null: false, default: false
        String :note
        DateTime :created_at, null: false
        DateTime :updated_at, null: false

        index :block_id, name: :index_steps_on_block_id
        index :exercise_id, name: :index_steps_on_exercise_id
        index %i[block_id position], unique: true, name: :index_steps_on_block_id_and_position
        constraint(:steps_reps) { (reps =~ nil) | (reps > 0) }
        constraint(:steps_duration_seconds) { (duration_seconds =~ nil) | (duration_seconds > 0) }
        constraint(:steps_reps_or_seconds) { (reps =~ nil) | (duration_seconds =~ nil) }
        constraint(:steps_target) { (reps !~ nil) | (duration_seconds !~ nil) | (note !~ nil) }
        constraint(:steps_tempo, Sequel.lit("tempo IS NULL OR tempo GLOB '[0-9][0-9][0-9]' OR tempo GLOB '[0-9][0-9][0-9][0-9]'"))
        constraint(:steps_weight_value) { (weight_value =~ nil) | (weight_value >= 0) }
        constraint(:steps_weight_unit) do
          ((weight_value =~ nil) =~ (weight_unit =~ nil)) & ((weight_unit =~ nil) | { weight_unit: %w[lb kg] })
        end
      end

      create_table(:step_equipment) do
        primary_key :id
        foreign_key :step_id, :steps, null: false, on_delete: :cascade
        foreign_key :equipment_id, :equipment, null: false, on_delete: :cascade

        index :step_id, name: :index_step_equipment_on_step_id
        index :equipment_id, name: :index_step_equipment_on_equipment_id
        index %i[step_id equipment_id], unique: true, name: :index_step_equipment_on_step_id_and_equipment_id
      end

      create_table(:sessions) do
        primary_key :id
        foreign_key :user_id, :users, null: false, on_delete: :cascade
        Integer :workout_id, null: false
        Date :date, null: false
        Integer :position, null: false
        String :status, null: false, default: "planned"
        String :created_by, null: false, default: "manual"
        DateTime :started_at
        column :part_kinds, :json
        String :note, text: true
        String :client_ref
        DateTime :created_at, null: false
        DateTime :updated_at, null: false

        foreign_key %i[user_id workout_id], :workouts, key: %i[user_id id], name: :fk_sessions_workout
        index %i[user_id id], unique: true, name: :index_sessions_on_user_id_and_id
        index %i[user_id workout_id], name: :index_sessions_on_workout_id
        # The calendar and Today read days in order; this covers lookups by date too.
        index %i[user_id date position], name: :index_sessions_on_date_and_position
        index %i[user_id client_ref], unique: true, name: :index_sessions_on_client_ref
        constraint(:sessions_position) { position >= 1 }
      end

      create_table(:set_logs) do
        primary_key :id
        foreign_key :user_id, :users, null: false, on_delete: :cascade
        Integer :session_id, null: false
        # Cleared when the step leaves its workout: the log keeps what it needs.
        foreign_key :step_id, :steps, on_delete: :set_null
        Integer :step_ref
        foreign_key :exercise_id, :exercises, null: false
        foreign_key :planned_exercise_id, :exercises, null: false
        String :block_label
        Integer :set_number, null: false
        String :side
        Integer :reps
        Integer :seconds
        BigDecimal :weight_value, size: [6, 2]
        String :weight_unit
        Integer :target_reps
        Integer :target_seconds
        BigDecimal :target_weight_value, size: [6, 2]
        String :target_weight_unit
        String :status, null: false, default: "done"
        DateTime :created_at, null: false
        DateTime :updated_at, null: false

        foreign_key %i[user_id session_id], :sessions, key: %i[user_id id], on_delete: :cascade, name: :fk_set_logs_session
        index :session_id, name: :index_set_logs_on_session_id
        index :step_id, name: :index_set_logs_on_step_id
        index %i[user_id exercise_id], name: :index_set_logs_on_exercise_id
        index :planned_exercise_id, name: :index_set_logs_on_planned_exercise_id
        # A set is logged once per step, round and side; no side counts as one.
        index [:session_id, :step_ref, :set_number, Sequel.function(:coalesce, :side, "")], unique: true, name: :index_set_logs_on_set
      end

      create_table(:completions) do
        primary_key :id
        foreign_key :session_id, :sessions, null: false, on_delete: :cascade
        DateTime :finished_at, null: false
        Integer :rpe
        String :feedback
        String :note, text: true
        TrueClass :ended_early, null: false, default: false
        DateTime :created_at, null: false
        DateTime :updated_at, null: false

        index :session_id, unique: true, name: :index_completions_on_session_id
      end

      create_table(:exercise_weights) do
        primary_key :id
        foreign_key :user_id, :users, null: false, on_delete: :cascade
        foreign_key :exercise_id, :exercises, null: false
        BigDecimal :value, size: [6, 2], null: false
        String :unit, null: false
        DateTime :created_at, null: false
        DateTime :updated_at, null: false

        index %i[user_id exercise_id], unique: true, name: :index_exercise_weights_on_exercise_id
        index :exercise_id, name: :index_exercise_weights_on_exercise
      end

      create_table(:weight_suggestions) do
        primary_key :id
        foreign_key :user_id, :users, null: false, on_delete: :cascade
        foreign_key :exercise_id, :exercises, null: false
        Integer :session_id, null: false
        # The session whose finish superseded it. A composite key would null
        # user_id with it, so this one is the session's id alone; the model
        # reads it within the user.
        foreign_key :superseded_by_id, :sessions, on_delete: :set_null
        String :direction, null: false
        BigDecimal :value, size: [6, 2], null: false
        String :unit, null: false
        String :reason, null: false
        String :status, null: false, default: "pending"
        DateTime :created_at, null: false
        DateTime :updated_at, null: false

        foreign_key %i[user_id session_id], :sessions, key: %i[user_id id], on_delete: :cascade, name: :fk_weight_suggestions_session
        index %i[user_id exercise_id status], name: :index_weight_suggestions_on_exercise_id_and_status
        index :exercise_id, name: :index_weight_suggestions_on_exercise_id
        index :session_id, name: :index_weight_suggestions_on_session_id
        index :superseded_by_id, name: :index_weight_suggestions_on_superseded_by_id
      end
    end
  end

  down do
    raise Sequel::Error, "per-user data can't be put back into one user's tables; restore the copy in storage/ instead"
  end
end
