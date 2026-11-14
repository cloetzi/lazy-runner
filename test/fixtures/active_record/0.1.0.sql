-- The schema ActiveRecord left at release 0.1.0 (last migration 20261025010001),
-- for the adoption tests in test/lib/database_test.rb.
CREATE TABLE "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE "sessions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "workout_id" integer NOT NULL, "date" date NOT NULL, "status" varchar DEFAULT 'planned' NOT NULL, "created_by" varchar DEFAULT 'manual' NOT NULL, "started_at" datetime(6), "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "part_kinds" json, "client_ref" varchar, CONSTRAINT "fk_rails_cb1f019098"
FOREIGN KEY ("workout_id")
  REFERENCES "workouts" ("id")
);
CREATE INDEX "index_sessions_on_workout_id" ON "sessions" ("workout_id");
CREATE INDEX "index_sessions_on_date" ON "sessions" ("date");
CREATE TABLE "completions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "session_id" integer NOT NULL, "finished_at" datetime(6) NOT NULL, "rpe" integer, "feedback" varchar, "note" text, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "ended_early" boolean DEFAULT FALSE NOT NULL, CONSTRAINT "fk_rails_56b78d5e1e"
FOREIGN KEY ("session_id")
  REFERENCES "sessions" ("id")
);
CREATE UNIQUE INDEX "index_completions_on_session_id" ON "completions" ("session_id");
CREATE TABLE "weight_suggestions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "exercise_id" integer NOT NULL, "session_id" integer NOT NULL, "direction" varchar NOT NULL, "value" decimal(6,2) NOT NULL, "unit" varchar NOT NULL, "reason" varchar NOT NULL, "status" varchar DEFAULT 'pending' NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_2e3a29386a"
FOREIGN KEY ("exercise_id")
  REFERENCES "exercises" ("id")
, CONSTRAINT "fk_rails_ba58120759"
FOREIGN KEY ("session_id")
  REFERENCES "sessions" ("id")
);
CREATE INDEX "index_weight_suggestions_on_exercise_id" ON "weight_suggestions" ("exercise_id");
CREATE INDEX "index_weight_suggestions_on_session_id" ON "weight_suggestions" ("session_id");
CREATE INDEX "index_weight_suggestions_on_exercise_id_and_status" ON "weight_suggestions" ("exercise_id", "status");
CREATE TABLE "equipment" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "slug" varchar NOT NULL, "name" varchar NOT NULL, "position" integer NOT NULL, "owned" boolean DEFAULT TRUE NOT NULL, "weights" json DEFAULT '[]' NOT NULL, "unit" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_equipment_on_slug" ON "equipment" ("slug");
CREATE TABLE "exercise_equipment" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "exercise_id" integer NOT NULL, "equipment_id" integer NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_7955c0e45b"
FOREIGN KEY ("exercise_id")
  REFERENCES "exercises" ("id")
, CONSTRAINT "fk_rails_c6780b65cb"
FOREIGN KEY ("equipment_id")
  REFERENCES "equipment" ("id")
);
CREATE INDEX "index_exercise_equipment_on_exercise_id" ON "exercise_equipment" ("exercise_id");
CREATE INDEX "index_exercise_equipment_on_equipment_id" ON "exercise_equipment" ("equipment_id");
CREATE UNIQUE INDEX "index_exercise_equipment_on_exercise_id_and_equipment_id" ON "exercise_equipment" ("exercise_id", "equipment_id");
CREATE TABLE "set_logs" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "session_id" integer NOT NULL, "step_id" integer, "set_number" integer NOT NULL, "side" varchar, "reps" integer, "seconds" integer, "weight_value" decimal(6,2), "weight_unit" varchar, "status" varchar DEFAULT 'done' NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "exercise_id" integer NOT NULL, "planned_exercise_id" integer NOT NULL, "block_label" varchar, "target_reps" integer, "target_seconds" integer, "target_weight_value" decimal(6,2), "target_weight_unit" varchar, CONSTRAINT "fk_rails_d7d8d96bbb"
FOREIGN KEY ("planned_exercise_id")
  REFERENCES "exercises" ("id")
, CONSTRAINT "fk_rails_e9a4f66b84"
FOREIGN KEY ("session_id")
  REFERENCES "sessions" ("id")
, CONSTRAINT "fk_rails_a8f6d6ba37"
FOREIGN KEY ("exercise_id")
  REFERENCES "exercises" ("id")
, CONSTRAINT "fk_rails_89946c588e"
FOREIGN KEY ("step_id")
  REFERENCES "steps" ("id")
 ON DELETE SET NULL);
CREATE INDEX "index_set_logs_on_session_id" ON "set_logs" ("session_id");
CREATE INDEX "index_set_logs_on_step_id" ON "set_logs" ("step_id");
CREATE INDEX "index_set_logs_on_exercise_id" ON "set_logs" ("exercise_id");
CREATE INDEX "index_set_logs_on_planned_exercise_id" ON "set_logs" ("planned_exercise_id");
CREATE UNIQUE INDEX "index_set_logs_on_set" ON "set_logs" (session_id, step_id, set_number, COALESCE(side, ''));
CREATE TABLE "step_equipment" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "step_id" integer NOT NULL, "equipment_id" integer NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_456ad4659b"
FOREIGN KEY ("step_id")
  REFERENCES "steps" ("id")
 ON DELETE CASCADE, CONSTRAINT "fk_rails_e268297739"
FOREIGN KEY ("equipment_id")
  REFERENCES "equipment" ("id")
 ON DELETE CASCADE);
CREATE INDEX "index_step_equipment_on_step_id" ON "step_equipment" ("step_id");
CREATE INDEX "index_step_equipment_on_equipment_id" ON "step_equipment" ("equipment_id");
CREATE UNIQUE INDEX "index_step_equipment_on_step_id_and_equipment_id" ON "step_equipment" ("step_id", "equipment_id");
CREATE TABLE "blocks" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "workout_id" integer NOT NULL, "label" varchar NOT NULL, "position" integer NOT NULL, "rounds" integer DEFAULT 1 NOT NULL, "rest_seconds" integer DEFAULT 0 NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_e1cb8f087e"
FOREIGN KEY ("workout_id")
  REFERENCES "workouts" ("id")
, CONSTRAINT blocks_rounds CHECK (rounds >= 1), CONSTRAINT blocks_rest_seconds CHECK (rest_seconds >= 0));
CREATE INDEX "index_blocks_on_workout_id" ON "blocks" ("workout_id");
CREATE UNIQUE INDEX "index_blocks_on_workout_id_and_label" ON "blocks" ("workout_id", "label");
CREATE TABLE "steps" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "block_id" integer NOT NULL, "exercise_id" integer NOT NULL, "position" integer NOT NULL, "reps" integer, "duration_seconds" integer, "tempo" varchar, "weight_value" decimal(6,2), "weight_unit" varchar, "per_side" boolean DEFAULT FALSE NOT NULL, "note" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "weights_held" integer, CONSTRAINT "fk_rails_752e42e9ab"
FOREIGN KEY ("block_id")
  REFERENCES "blocks" ("id")
, CONSTRAINT "fk_rails_a801966d40"
FOREIGN KEY ("exercise_id")
  REFERENCES "exercises" ("id")
, CONSTRAINT steps_reps CHECK (reps IS NULL OR reps > 0), CONSTRAINT steps_duration_seconds CHECK (duration_seconds IS NULL OR duration_seconds > 0), CONSTRAINT steps_reps_or_seconds CHECK (reps IS NULL OR duration_seconds IS NULL), CONSTRAINT steps_target CHECK (reps IS NOT NULL OR duration_seconds IS NOT NULL OR note IS NOT NULL), CONSTRAINT steps_tempo CHECK (tempo IS NULL OR tempo GLOB '[0-9][0-9][0-9]' OR tempo GLOB '[0-9][0-9][0-9][0-9]'), CONSTRAINT steps_weight_value CHECK (weight_value IS NULL OR weight_value >= 0), CONSTRAINT steps_weight_unit CHECK ((weight_value IS NULL) = (weight_unit IS NULL) AND (weight_unit IS NULL OR weight_unit IN ('lb', 'kg'))));
CREATE INDEX "index_steps_on_block_id" ON "steps" ("block_id");
CREATE INDEX "index_steps_on_exercise_id" ON "steps" ("exercise_id");
CREATE UNIQUE INDEX "index_steps_on_block_id_and_position" ON "steps" ("block_id", "position");
CREATE TABLE "exercises" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "slug" varchar NOT NULL, "name" varchar NOT NULL, "category" varchar NOT NULL, "cues" json DEFAULT '[]' NOT NULL, "mistakes" json DEFAULT '[]' NOT NULL, "unilateral" boolean DEFAULT FALSE NOT NULL, "default_reps" integer, "default_seconds" integer, "video_url" varchar, "animation" json, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "instructions" json DEFAULT '[]' NOT NULL, "retired" boolean DEFAULT FALSE NOT NULL, "areas" json DEFAULT '[]' NOT NULL, "weights_held" integer DEFAULT 1 NOT NULL, "pattern" varchar, CONSTRAINT exercises_one_default CHECK (default_reps IS NULL OR default_seconds IS NULL));
CREATE UNIQUE INDEX "index_exercises_on_slug" ON "exercises" ("slug");
CREATE UNIQUE INDEX "index_sessions_on_client_ref" ON "sessions" ("client_ref");
CREATE TABLE "exercise_weights" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "exercise_id" integer NOT NULL, "value" decimal(6,2) NOT NULL, "unit" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_abe8bf2805"
FOREIGN KEY ("exercise_id")
  REFERENCES "exercises" ("id")
);
CREATE UNIQUE INDEX "index_exercise_weights_on_exercise_id" ON "exercise_weights" ("exercise_id");
CREATE TABLE "programs" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "slug" varchar, "name" varchar NOT NULL, "description" text, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "source" varchar DEFAULT 'seed' NOT NULL, CONSTRAINT programs_source CHECK (source IN ('seed', 'user', 'llm')), CONSTRAINT programs_seed_slug CHECK (source <> 'seed' OR slug IS NOT NULL));
CREATE UNIQUE INDEX "index_programs_on_slug" ON "programs" ("slug") WHERE source = 'seed';
CREATE TABLE "workouts" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "program_id" integer, "slug" varchar, "kind" varchar NOT NULL, "title" varchar NOT NULL, "subtitle" varchar, "position" integer NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "source" varchar DEFAULT 'seed' NOT NULL, "archived_at" datetime(6), "warmup_id" integer, "cooldown_id" integer, "no_warmup" boolean DEFAULT FALSE NOT NULL, "no_cooldown" boolean DEFAULT FALSE NOT NULL, CONSTRAINT "fk_rails_cfa7370d33"
FOREIGN KEY ("cooldown_id")
  REFERENCES "workouts" ("id")
, CONSTRAINT "fk_rails_43fe11990a"
FOREIGN KEY ("program_id")
  REFERENCES "programs" ("id")
, CONSTRAINT "fk_rails_d86ea194e8"
FOREIGN KEY ("warmup_id")
  REFERENCES "workouts" ("id")
, CONSTRAINT workouts_source CHECK (source IN ('seed', 'user', 'llm')), CONSTRAINT workouts_seed_slug CHECK (source <> 'seed' OR (slug IS NOT NULL AND program_id IS NOT NULL)), CONSTRAINT workouts_framing CHECK (NOT (no_warmup AND warmup_id IS NOT NULL) AND NOT (no_cooldown AND cooldown_id IS NOT NULL)));
CREATE INDEX "index_workouts_on_program_id" ON "workouts" ("program_id");
CREATE INDEX "index_workouts_on_warmup_id" ON "workouts" ("warmup_id");
CREATE INDEX "index_workouts_on_cooldown_id" ON "workouts" ("cooldown_id");
CREATE UNIQUE INDEX "index_workouts_on_slug" ON "workouts" ("slug") WHERE source = 'seed';
CREATE TABLE "settings" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "unit" varchar DEFAULT 'lb' NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT settings_unit CHECK (unit IN ('lb', 'kg')));
INSERT INTO schema_migrations (version) VALUES ('20261019000001');
INSERT INTO schema_migrations (version) VALUES ('20261020000001');
INSERT INTO schema_migrations (version) VALUES ('20261021000001');
INSERT INTO schema_migrations (version) VALUES ('20261024000001');
INSERT INTO schema_migrations (version) VALUES ('20261024120001');
INSERT INTO schema_migrations (version) VALUES ('20261024150001');
INSERT INTO schema_migrations (version) VALUES ('20261024160001');
INSERT INTO schema_migrations (version) VALUES ('20261024160034');
INSERT INTO schema_migrations (version) VALUES ('20261024170001');
INSERT INTO schema_migrations (version) VALUES ('20261024180001');
INSERT INTO schema_migrations (version) VALUES ('20261024200001');
INSERT INTO schema_migrations (version) VALUES ('20261024200101');
INSERT INTO schema_migrations (version) VALUES ('20261024200201');
INSERT INTO schema_migrations (version) VALUES ('20261024210001');
INSERT INTO schema_migrations (version) VALUES ('20261024220001');
INSERT INTO schema_migrations (version) VALUES ('20261024230001');
INSERT INTO schema_migrations (version) VALUES ('20261024230101');
INSERT INTO schema_migrations (version) VALUES ('20261025010001');
INSERT INTO ar_internal_metadata (key, value, created_at, updated_at) VALUES ('environment', 'production', '2026-10-26 00:00:00', '2026-10-26 00:00:00');
