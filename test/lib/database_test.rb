require "test_helper"

describe Database do
  # A database in memory, migrated by Sequel from scratch, or as ActiveRecord
  # left it at a release (test/fixtures/active_record/*.sql).
  def fresh = Database.connect("sqlite:/").tap { Database.migrate!(it) }

  def left_by_active_record(release)
    sql = File.read(Rage.root.join("test/fixtures/active_record/#{release}.sql"))
    Database.connect("sqlite:/").tap { |db| db.synchronize { it.execute_batch(sql) } }
  end

  # What Sequel and SQLite say about every table: its columns as Sequel types
  # them, its indexes, foreign keys and CHECK constraints by name.
  def shape(db)
    db.tables.sort.to_h do |table|
      columns = db.schema(table, reload: true).map { |name, info| [name, info.values_at(:type, :allow_null, :ruby_default, :primary_key)] }.sort
      indexes = db.fetch("PRAGMA index_list(?)", table.to_s).reject { it[:origin] == "pk" }.to_h do |index|
        keys = db.fetch("PRAGMA index_xinfo(?)", index[:name]).select { it[:key] == 1 }.map { it[:name] || it[:cid] }
        [index[:name], [index[:unique], index[:partial], keys]]
      end
      keys = db.foreign_key_list(table).map { it.values_at(:columns, :table, :on_delete).push(it[:key] || [:id]) }.sort_by(&:inspect)
      checks = db[:sqlite_master].where(name: table.to_s).get(:sql).scan(/CONSTRAINT [`"]?(\w+)[`"]? CHECK/).flatten.sort
      [table, { columns:, indexes: indexes.sort.to_h, keys:, checks: }]
    end
  end

  def migrations(db) = db[:schema_migrations].select_order_map(:filename)

  it "connects with foreign keys, a write-ahead log and immediate transactions" do
    _(DB.fetch("PRAGMA foreign_keys").single_value).must_equal 1
    _(DB.fetch("PRAGMA journal_mode").single_value).must_equal "wal"
    _(DB.fetch("PRAGMA synchronous").single_value).must_equal 1
    _(DB.transaction_mode).must_equal :immediate
  end

  it "takes a DATABASE_URL in Sequel's form or ActiveRecord's" do
    Dir.mktmpdir do |dir|
      %W[sqlite://#{dir}/a.sqlite3 sqlite3:#{dir}/b.sqlite3].each do |url|
        Database.connect(url).then { it.test_connection && it.disconnect }
      end

      _(Dir.children(dir).grep(/\.sqlite3\z/).sort).must_equal %w[a.sqlite3 b.sqlite3]
    end
  end

  # SQLite can't change a column default or add a constraint in place, so
  # Sequel copies the table, and the copy has none of the CHECK constraints
  # or partial indexes: a migration doing that has to make them again.
  # Dropped on purpose: the seed-only rules, when programs became examples (#183).
  DROPPED = { programs: %w[programs_seed_slug index_programs_on_slug], workouts: %w[workouts_seed_slug index_workouts_on_slug] }.freeze

  it "keeps every CHECK constraint and partial index of the baseline through the later migrations" do
    kept = ->(db) { shape(db).transform_values { it[:checks] + it[:indexes].select { |_, (_, partial)| partial == 1 }.keys } }
    db = Database.connect("sqlite:/")
    Sequel::TimestampMigrator.run(db, Database::MIGRATIONS, target: 20261025010001)
    baseline = kept.(db)
    Database.migrate!(db)

    after = kept.(db)
    baseline.each { |table, names| _(names - DROPPED.fetch(table, []) - after.fetch(table)).must_be_empty table }
  end

  it "migrates a new database with every migration, once" do
    db = fresh
    Database.migrate!(db)

    _(Database.current?(db)).must_equal true
    _(migrations(db)).must_equal Dir.children(Database::MIGRATIONS).sort
  end

  describe "data per user" do
    let(:db) { fresh }
    let(:now) { Time.now }

    def add(table, **values) = db[table].insert(created_at: now, updated_at: now, **values)

    it "refuses a reference to another user's record" do
      mine, theirs = %w[mine theirs].map { add(:users, username: it) }
      workout = add(:workouts, user_id: mine, kind: "workout", title: "Mine", position: 1, source: "user")
      warmup = add(:workouts, user_id: theirs, kind: "warmup", title: "Theirs", position: 1, source: "user")

      _ { add(:sessions, user_id: theirs, workout_id: workout, date: Date.today, position: 1) }.must_raise Sequel::ForeignKeyConstraintViolation
      _ { db[:workouts].where(id: workout).update(warmup_id: warmup) }.must_raise Sequel::ForeignKeyConstraintViolation
      session = add(:sessions, user_id: mine, workout_id: workout, date: Date.today, position: 1)
      _ { add(:weight_suggestions, user_id: theirs, session_id: session, exercise_id: add(:exercises, slug: "x", name: "X", category: "strength"), direction: "up", value: 1, unit: "lb", reason: "r") }.must_raise Sequel::ForeignKeyConstraintViolation
    end

    it "deletes a user with everything of theirs" do
      user = add(:users, username: "leaving")
      program = add(:programs, user_id: user, example_slug: "p", name: "P")
      workout = add(:workouts, user_id: user, program_id: program, example_slug: "w", kind: "workout", title: "W", position: 1)
      block = add(:blocks, workout_id: workout, label: "A", position: 1)
      exercise = add(:exercises, slug: "x", name: "X", category: "strength")
      step = add(:steps, block_id: block, exercise_id: exercise, position: 1, reps: 5)
      session = add(:sessions, user_id: user, workout_id: workout, date: Date.today, position: 1)
      add(:set_logs, user_id: user, session_id: session, step_id: step, step_ref: step, exercise_id: exercise, planned_exercise_id: exercise, set_number: 1)
      add(:completions, session_id: session, finished_at: now)
      add(:settings, user_id: user)
      add(:user_equipment, user_id: user, equipment_id: add(:equipment, slug: "e", name: "E", position: 1), owned: true)

      db[:users].where(id: user).delete

      tables = %i[programs workouts blocks steps sessions set_logs completions settings user_equipment]
      _(tables.to_h { [it, db[it].count] }).must_equal(tables.to_h { [it, 0] })
      _(db[:exercises].count).must_equal 1
    end
  end

  it "brings workouts saved before their limits within them" do
    db = Database.connect("sqlite:/")
    Sequel::TimestampMigrator.run(db, Database::MIGRATIONS, target: 20261107000001)
    now = Time.now
    add = ->(table, **values) { db[table].insert(created_at: now, updated_at: now, **values) }
    user = add.(:users, username: "runner")
    workout = add.(:workouts, user_id: user, kind: "workout", title: "T" * 150, subtitle: "S" * 250, position: 1, source: "user")
    huge = add.(:blocks, workout_id: workout, label: "L" * 80, position: 1, rounds: 10**12, rest_seconds: 10**6)
    alike = add.(:blocks, workout_id: workout, label: "#{"L" * 70}x", position: 2, rounds: 3)
    exercise = add.(:exercises, slug: "x", name: "X", category: "strength")
    add.(:steps, block_id: huge, exercise_id: exercise, position: 1, reps: 10**6, note: "N" * 600)
    add.(:steps, block_id: alike, exercise_id: exercise, position: 1, duration_seconds: 10**6)
    Database.migrate!(db)

    _(db[:workouts].select_map(%i[title subtitle])).must_equal [["T" * 100, "S" * 200]]
    _(db[:blocks].order(:id).select_map(%i[label rounds rest_seconds])).must_equal [["#{"L" * (59 - huge.to_s.size)} #{huge}", 20, 600], ["#{"L" * (59 - alike.to_s.size)} #{alike}", 3, 0]]
    _(db[:steps].order(:id).select_map(%i[reps duration_seconds note])).must_equal [[1000, nil, "N" * 500], [nil, 3600, nil]]
  end

  it "keeps the programs the seeds gave a user, as imported examples" do
    db = Database.connect("sqlite:/")
    Sequel::TimestampMigrator.run(db, Database::MIGRATIONS, target: 20261102000003)
    now = Time.now
    user = db[:users].insert(username: "runner", created_at: now, updated_at: now)
    program = db[:programs].insert(user_id: user, slug: "cycle-1", name: "Cycle 1", source: "seed", created_at: now, updated_at: now)
    db[:workouts].insert(user_id: user, program_id: program, slug: "cycle-1-workout-1", kind: "workout", title: "Workout 1", position: 1, source: "seed", created_at: now, updated_at: now)
    Database.migrate!(db)

    _(db[:programs].select_map(%i[example_slug source])).must_equal [%w[cycle-1 user]]
    _(db[:workouts].select_map(%i[example_slug source])).must_equal [%w[cycle-1-workout-1 user]]
    _ { db[:workouts].where(id: 1).update(source: "seed") }.must_raise Sequel::CheckConstraintViolation
  end

  describe "taking over a database ActiveRecord migrated" do
    %w[0.1.0 unreleased].each do |release|
      it "ends with the schema a new one has, from #{release}" do
        db = left_by_active_record(release)
        Database.migrate!(db)

        _(shape(db)).must_equal shape(fresh)
        _(migrations(db)).must_equal migrations(fresh)
        _(db.table_exists?(:ar_internal_metadata)).must_equal false
      end
    end

    it "kept the data up to per-user scoping, numbering each day's sessions by id as the calendar came in" do
      db = left_by_active_record("0.1.0")
      now = "2026-10-19 08:00:00"
      db.run <<~SQL
        INSERT INTO workouts (id, kind, title, position, source, created_at, updated_at) VALUES (1, 'workout', 'Mine', 1, 'user', '#{now}', '#{now}');
        INSERT INTO sessions (id, workout_id, date, status, created_by, created_at, updated_at) VALUES
          (901, 1, '2026-10-19', 'done', 'manual', '#{now}', '#{now}'),
          (903, 1, '2026-10-19', 'planned', 'manual', '#{now}', '#{now}'),
          (902, 1, '2026-10-20', 'planned', 'manual', '#{now}', '#{now}');
        INSERT INTO completions (session_id, finished_at, created_at, updated_at) VALUES (901, '#{now}', '#{now}', '#{now}');
      SQL
      Database.adopt_active_record!(db)
      Sequel::TimestampMigrator.run(db, Database::MIGRATIONS, target: 20261102000002)

      _(db[:sessions].order(:id).select_map(%i[id position note])).must_equal [[901, 1, nil], [902, 1, nil], [903, 2, nil]]
      _(db[:completions].select_map(:session_id)).must_equal [901]
      _ { db[:sessions].where(id: 901).update(position: 0) }.must_raise Sequel::CheckConstraintViolation
    end

    it "refuses one older than release 0.1.0, or with migrations it doesn't know" do
      db = left_by_active_record("0.1.0")
      db[:schema_migrations].where(version: "20261025010001").delete
      _(_ { Database.migrate!(db) }.must_raise(Database::Error).message).must_match "older than release 0.1.0"

      db = left_by_active_record("0.1.0")
      db[:schema_migrations].insert(version: "20991231000001")
      _(_ { Database.migrate!(db) }.must_raise(Database::Error).message).must_match "20991231000001"
    end
  end
end
