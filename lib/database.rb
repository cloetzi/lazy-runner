require "fileutils"
require "sequel"
require "time"

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

  # Backups taken before migrations, kept per database; the oldest go first.
  KEEP_BACKUPS = 5
  # How long a copy at a migration stands for the database at that migration.
  FRESH_BACKUP = 24 * 60 * 60

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
      after_connect: lambda { |connection|
        # Waits for another process holding the lock (a backup, say) by
        # sleeping in Ruby, which yields to other fibers, rather than in C.
        connection.busy_handler_timeout = 5000
        keep_private(connection.filename)
      },
      sql_log_level: :debug
    ).tap { it.transaction_mode = :immediate }
  end

  # The database holds password hashes and everyone's training data, so
  # other users of the machine can't read its file, however an older release
  # or a copy left it, nor the -wal and -shm files beside it (SQLite makes
  # them with the database's permissions). A group the operator gave it (a
  # backup job's) keeps its access, and new files have none (the umask).
  # Files of someone else's are left as they are, and a file system that
  # won't change modes leaves them too. Nothing for a database in memory.
  def self.keep_private(file)
    return if file.to_s.empty?

    [file, "#{file}-wal", "#{file}-shm"].each do |path|
      stat = File.stat(path)
      File.chmod(stat.mode & ~0o007, path) if stat.owned? && stat.mode.anybits?(0o007)
    rescue SystemCallError
      next
    end
  end

  # Runs the migrations db/migrate holds that the database lacks, after
  # taking over the bookkeeping of a database ActiveRecord kept. An existing
  # database with migrations to run is copied aside first (back_up!).
  def self.migrate!(db)
    Sequel.extension :migration
    back_up!(db) if pending?(db)
    adopt_active_record!(db)
    Sequel::TimestampMigrator.run(db, MIGRATIONS)
  end

  # Whether a database that has a schema already is due migrations: an
  # ActiveRecord one always is (its bookkeeping is rewritten).
  def self.pending?(db)
    return false unless db.table_exists?(:schema_migrations)
    return true if db[:schema_migrations].columns == [:version]

    !current?(db)
  end

  # Copies a database file to backups/ beside it, named by the time and the
  # last migration it has (production-20261115T220000Z-20261115400001.sqlite3),
  # so a migration that goes wrong halfway can be undone by putting the copy
  # back. A database copied at that migration in the last FRESH_BACKUP isn't
  # copied again, so a server restarting over a failing migration keeps the
  # copy from before the upgrade rather than rotating it out; an older copy
  # at that migration (a database put back from it, and used since) doesn't
  # stand in for a new one. VACUUM INTO writes a consistent
  # copy without the write-ahead log; it can't run inside a transaction, and
  # boot migrates outside one. The newest KEEP_BACKUPS are kept. A copy that
  # can't be written stops the boot: better no upgrade than one with no way
  # back. Nothing for a database in memory.
  def self.back_up!(db, at: Time.now.utc, keep: KEEP_BACKUPS)
    file = db.opts[:database].to_s
    return if file.empty? || file == ":memory:" || !File.exist?(file)

    dir = File.join(File.dirname(file), "backups")
    name = File.basename(file).delete_suffix(".sqlite3")
    pattern = /\A#{Regexp.escape(name)}-(\d{8}T\d{6}Z)-(\d+)\.sqlite3\z/
    FileUtils.mkdir_p(dir)
    taken = Dir.children(dir).grep(pattern).sort
    level = last_migration(db)
    return if taken.any? { it[pattern, 2] == level && at - Time.strptime("#{it[pattern, 1]} UTC", "%Y%m%dT%H%M%SZ %Z") < FRESH_BACKUP }

    backup = File.join(dir, "#{name}-#{at.strftime("%Y%m%dT%H%M%SZ")}-#{level}.sqlite3")
    begin
      db.run("VACUUM INTO #{db.literal(backup)}")
    rescue Sequel::DatabaseError => e
      FileUtils.rm_f(backup)
      raise Error, "couldn't copy the database to #{backup} before migrating it (#{e.message}); " \
                   "make room in #{dir} and start again"
    end
    (taken + [File.basename(backup)]).sort.reverse.drop(keep).each { File.delete(File.join(dir, it)) }
    backup
  end

  # The version of the last migration a database has, "0" for none; an
  # ActiveRecord one lists versions where Sequel lists file names.
  def self.last_migration(db)
    column = db[:schema_migrations].columns.include?(:filename) ? :filename : :version
    (db[:schema_migrations].select_map(column).map(&:to_i).max || 0).to_s
  rescue Sequel::DatabaseError
    "0"
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
