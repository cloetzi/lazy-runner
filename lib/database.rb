require "sequel"

# The app's one SQLite file, through Sequel: how it is opened and how its
# schema is brought up to date. config/initializers/database.rb connects and
# migrates on boot, before any model loads, so every model reads the schema
# it is written for.
module Database
  MIGRATIONS = File.expand_path("../db/migrate", __dir__)

  # Releases up to 0.1.0 kept the schema with ActiveRecord. Its migrations
  # map to the Sequel ones that stand for them: everything up to 0.1.0 is the
  # baseline, and the one migration ActiveRecord ran after it is ported as is.
  ACTIVE_RECORD = {
    "20261025010001_create_schema.rb" => %w[
      20261019000001 20261020000001 20261021000001 20261024000001 20261024120001 20261024150001
      20261024160001 20261024160034 20261024170001 20261024180001 20261024200001 20261024200101
      20261024200201 20261024210001 20261024220001 20261024230001 20261024230101 20261025010001
    ],
    "20261025233001_add_calendar_to_sessions.rb" => %w[20261025233001]
  }.freeze

  # A database this code can't bring up to date.
  class Error < StandardError; end

  # Opens the database at DATABASE_URL (a Sequel URL such as
  # sqlite://storage/production.sqlite3, or ActiveRecord's
  # sqlite3:storage/production.sqlite3 as releases up to 0.1.0 took it), else
  # storage/<env>.sqlite3.
  #
  # One connection: SQLite has one writer at a time anyway, so request fibers
  # queue for the connection (cooperatively, see the fiber_concurrency
  # extension in config/initializers/database.rb) rather than for SQLite's
  # file lock. Foreign keys are enforced, the journal is a write-ahead log
  # (readers don't block the writer, and NORMAL sync is safe with it), and
  # transactions begin IMMEDIATE, taking the write lock up front, so one
  # never fails halfway on a lock it can't upgrade.
  def self.connect(url = ENV["DATABASE_URL"].presence || "sqlite://storage/#{Rage.env}.sqlite3")
    Sequel.connect(
      url.sub(%r{\Asqlite3:(//)?}, "sqlite://"),
      max_connections: 1,
      foreign_keys: true,
      synchronous: :normal,
      connect_sqls: ["PRAGMA journal_mode = WAL"],
      # Waits for another process holding the lock (a backup, say) by
      # sleeping in Ruby, which yields to other fibers, rather than in C.
      after_connect: ->(connection) { connection.busy_handler_timeout = 5000 },
      sql_log_level: :debug
    ).tap { it.transaction_mode = :immediate }
  end

  # Runs the migrations db/migrate holds that the database lacks, after
  # taking over the bookkeeping of a database ActiveRecord kept.
  def self.migrate!(db)
    Sequel.extension :migration
    adopt_active_record!(db)
    Sequel::TimestampMigrator.run(db, MIGRATIONS)
  end

  # Whether every migration has run.
  def self.current?(db)
    Sequel.extension :migration
    Sequel::TimestampMigrator.is_current?(db, MIGRATIONS)
  end

  # A database ActiveRecord migrated lists versions in schema_migrations,
  # where Sequel lists file names, and has ar_internal_metadata besides. Its
  # tables are the ones the Sequel migrations make, so only the list changes:
  # it names the Sequel migrations that stand for the versions it has, and
  # the migrator runs the rest. Anything older than release 0.1.0 is refused,
  # since only the migrations after it are ported.
  def self.adopt_active_record!(db)
    return unless db.table_exists?(:schema_migrations) && db[:schema_migrations].columns == [:version]

    versions = db[:schema_migrations].select_order_map(:version)
    unknown = versions - ACTIVE_RECORD.values.flatten
    raise Error, "the database has migrations this release doesn't know: #{unknown.join(", ")}" if unknown.any?

    applied = ACTIVE_RECORD.select { |_, covered| (covered - versions).empty? }.keys
    unless applied.include?(ACTIVE_RECORD.keys.first)
      raise Error, "the database is older than release 0.1.0; run release 0.1.0 on it once to bring it up to " \
                   "that release, then this one"
    end

    db.transaction do
      db.drop_table(:schema_migrations)
      db.drop_table?(:ar_internal_metadata)
      db.create_table(:schema_migrations) { String :filename, primary_key: true }
      db[:schema_migrations].import([:filename], applied.map { [it] })
    end
  end
end
