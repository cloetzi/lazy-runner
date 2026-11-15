require_relative "../../lib/database"
require_relative "../../lib/seed_loader"

# Rage runs each request in a fiber, so Sequel hands out connections per
# fiber rather than per thread: a request keeps its own connection (and
# transaction) while others wait for theirs.
Sequel.extension :fiber_concurrency
# Timestamps are kept in UTC, as they always were; TZ only sets the day
# (config/initializers/time_zone.rb).
Sequel.default_timezone = :utc

# Whatever the app writes (the database, its backups, the session secret)
# is readable by its own user only, whatever umask it was started with.
File.umask(File.umask | 0o077)

DB = Database.connect
# The schema is brought up to date on every boot,
# before the models load and read it, so `docker run` is all it takes.
Database.migrate!(DB)
Sequel::Model.db = DB

Rage.configure do
  config.after_initialize do
    # Tests load the seeds themselves (test/test_helper.rb).
    SeedLoader.load! unless Rage.env.test?
    # A fresh install: the owner account is made with this code, so only
    # whoever can read the server's log can claim it (lib/setup_code.rb).
    # Only the server's: a code a rake task printed would work nowhere.
    if !Rage.env.test? && !defined?(Rake) && DB[:users].empty?
      Rage.logger.warn("No users yet. Create the owner account in the app with the setup code #{SetupCode.generate!}")
    end
    # Queries go to the log at debug level (development), the boot's own
    # migrations and seeding left out.
    DB.loggers << Rage.logger if Rage.logger&.debug?
  ensure
    # The server starts with no connection open; each request fiber opens
    # its own as it needs one.
    DB.disconnect
  end
end
