# frozen_string_literal: true

# The schema as release 0.1.0 left it, the last release whose migrations ran
# on ActiveRecord: a database ActiveRecord migrated that far is taken over as
# it is (Database.adopt_active_record!), and a new one starts here. Index and
# foreign key names are the ones ActiveRecord gave them, so both kinds of
# database are the same and later migrations can name them.
#
# Booleans are stored as 0 and 1. JSON columns hold JSON text (the models
# read and write them with the serialization plugin).
Sequel.migration do
  change do
    create_table(:equipment) do
      primary_key :id
      String :slug, null: false
      String :name, null: false
      Integer :position, null: false
      TrueClass :owned, null: false, default: true
      # The weights owned, for fixed-weight equipment such as dumbbells.
      column :weights, :json, null: false, default: "[]"
      String :unit
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :slug, unique: true, name: :index_equipment_on_slug
    end

    create_table(:exercises) do
      primary_key :id
      String :slug, null: false
      String :name, null: false
      String :category, null: false
      column :areas, :json, null: false, default: "[]"
      String :pattern
      column :cues, :json, null: false, default: "[]"
      column :mistakes, :json, null: false, default: "[]"
      column :instructions, :json, null: false, default: "[]"
      TrueClass :unilateral, null: false, default: false
      Integer :weights_held, null: false, default: 1
      Integer :default_reps
      Integer :default_seconds
      String :video_url
      column :animation, :json
      # Dropped from the seeds, kept for the sets logged with it.
      TrueClass :retired, null: false, default: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :slug, unique: true, name: :index_exercises_on_slug
      constraint(:exercises_one_default) { (default_reps =~ nil) | (default_seconds =~ nil) }
    end

    create_table(:exercise_equipment) do
      primary_key :id
      foreign_key :exercise_id, :exercises, null: false, foreign_key_constraint_name: :fk_rails_7955c0e45b
      foreign_key :equipment_id, :equipment, null: false, foreign_key_constraint_name: :fk_rails_c6780b65cb
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :exercise_id, name: :index_exercise_equipment_on_exercise_id
      index :equipment_id, name: :index_exercise_equipment_on_equipment_id
      index %i[exercise_id equipment_id], unique: true, name: :index_exercise_equipment_on_exercise_id_and_equipment_id
    end

    create_table(:programs) do
      primary_key :id
      String :slug
      String :name, null: false
      String :description, text: true
      String :source, null: false, default: "seed"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :slug, unique: true, where: { source: "seed" }, name: :index_programs_on_slug
      constraint(:programs_source, source: %w[seed user llm])
      constraint(:programs_seed_slug) { (source !~ "seed") | (slug !~ nil) }
    end

    create_table(:workouts) do
      primary_key :id
      foreign_key :program_id, :programs, foreign_key_constraint_name: :fk_rails_43fe11990a
      String :slug
      String :kind, null: false
      String :title, null: false
      String :subtitle
      Integer :position, null: false
      String :source, null: false, default: "seed"
      foreign_key :warmup_id, :workouts, foreign_key_constraint_name: :fk_rails_d86ea194e8
      foreign_key :cooldown_id, :workouts, foreign_key_constraint_name: :fk_rails_cfa7370d33
      TrueClass :no_warmup, null: false, default: false
      TrueClass :no_cooldown, null: false, default: false
      DateTime :archived_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :program_id, name: :index_workouts_on_program_id
      index :slug, unique: true, where: { source: "seed" }, name: :index_workouts_on_slug
      index :warmup_id, name: :index_workouts_on_warmup_id
      index :cooldown_id, name: :index_workouts_on_cooldown_id
      constraint(:workouts_source, source: %w[seed user llm])
      constraint(:workouts_seed_slug) { (source !~ "seed") | ((slug !~ nil) & (program_id !~ nil)) }
      constraint(:workouts_framing) { ~(no_warmup & (warmup_id !~ nil)) & ~(no_cooldown & (cooldown_id !~ nil)) }
    end

    create_table(:blocks) do
      primary_key :id
      foreign_key :workout_id, :workouts, null: false, foreign_key_constraint_name: :fk_rails_e1cb8f087e
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
      foreign_key :block_id, :blocks, null: false, foreign_key_constraint_name: :fk_rails_752e42e9ab
      foreign_key :exercise_id, :exercises, null: false, foreign_key_constraint_name: :fk_rails_a801966d40
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
      foreign_key :step_id, :steps, null: false, on_delete: :cascade, foreign_key_constraint_name: :fk_rails_456ad4659b
      foreign_key :equipment_id, :equipment, null: false, on_delete: :cascade, foreign_key_constraint_name: :fk_rails_e268297739
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :step_id, name: :index_step_equipment_on_step_id
      index :equipment_id, name: :index_step_equipment_on_equipment_id
      index %i[step_id equipment_id], unique: true, name: :index_step_equipment_on_step_id_and_equipment_id
    end

    create_table(:sessions) do
      primary_key :id
      foreign_key :workout_id, :workouts, null: false, foreign_key_constraint_name: :fk_rails_cb1f019098
      Date :date, null: false
      String :status, null: false, default: "planned"
      String :created_by, null: false, default: "manual"
      DateTime :started_at
      column :part_kinds, :json
      String :client_ref
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :workout_id, name: :index_sessions_on_workout_id
      index :date, name: :index_sessions_on_date
      index :client_ref, unique: true, name: :index_sessions_on_client_ref
    end

    create_table(:set_logs) do
      primary_key :id
      foreign_key :session_id, :sessions, null: false, foreign_key_constraint_name: :fk_rails_e9a4f66b84
      # Cleared when the step leaves its workout: the log keeps what it needs.
      foreign_key :step_id, :steps, on_delete: :set_null, foreign_key_constraint_name: :fk_rails_89946c588e
      foreign_key :exercise_id, :exercises, null: false, foreign_key_constraint_name: :fk_rails_a8f6d6ba37
      foreign_key :planned_exercise_id, :exercises, null: false, foreign_key_constraint_name: :fk_rails_d7d8d96bbb
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

      index :session_id, name: :index_set_logs_on_session_id
      index :step_id, name: :index_set_logs_on_step_id
      index :exercise_id, name: :index_set_logs_on_exercise_id
      index :planned_exercise_id, name: :index_set_logs_on_planned_exercise_id
      # A set is logged once per step, round and side; no side counts as one.
      index [:session_id, :step_id, :set_number, Sequel.function(:coalesce, :side, "")], unique: true, name: :index_set_logs_on_set
    end

    create_table(:completions) do
      primary_key :id
      foreign_key :session_id, :sessions, null: false, foreign_key_constraint_name: :fk_rails_56b78d5e1e
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
      foreign_key :exercise_id, :exercises, null: false, foreign_key_constraint_name: :fk_rails_abe8bf2805
      BigDecimal :value, size: [6, 2], null: false
      String :unit, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :exercise_id, unique: true, name: :index_exercise_weights_on_exercise_id
    end

    create_table(:weight_suggestions) do
      primary_key :id
      foreign_key :exercise_id, :exercises, null: false, foreign_key_constraint_name: :fk_rails_2e3a29386a
      foreign_key :session_id, :sessions, null: false, foreign_key_constraint_name: :fk_rails_ba58120759
      String :direction, null: false
      BigDecimal :value, size: [6, 2], null: false
      String :unit, null: false
      String :reason, null: false
      String :status, null: false, default: "pending"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index :exercise_id, name: :index_weight_suggestions_on_exercise_id
      index :session_id, name: :index_weight_suggestions_on_session_id
      index %i[exercise_id status], name: :index_weight_suggestions_on_exercise_id_and_status
    end

    create_table(:settings) do
      primary_key :id
      String :unit, null: false, default: "lb"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      constraint(:settings_unit, unit: %w[lb kg])
    end
  end
end
