require "test_helper"
require "open3"

# The production boot (config/initializers/database.rb) migrates and seeds
# before the server starts. This runs it for real, in a separate process
# against a database the last release left, the way a deploy meets it.
describe "booting against an existing database" do
  # Runs Ruby in a fresh process with the app loaded against `database`, and
  # returns what the script prints after the marker, parsed as JSON. The
  # rest of what it printed (the log) is kept in @output.
  def run_app(database, script)
    code = <<~RUBY
      require "./config/application"
      require "json"
      result = begin
        #{script}
      end
      puts "RESULT " + JSON.generate(result)
    RUBY
    output, status = Open3.capture2e(
      { "RAGE_ENV" => "production", "DATABASE_URL" => "sqlite://#{database}", "SESSION_SECRET" => SecureRandom.hex(64) },
      RbConfig.ruby, "-e", code, chdir: Rage.root.to_s
    )
    _(status.success?).must_equal true, output
    @output = output
    JSON.parse(output.lines.reverse.find { it.start_with?("RESULT ") }.delete_prefix("RESULT "))
  end

  it "takes over a 0.1.0 database, seeds it, copies the one-user data aside, keeps both private and opens no connection" do
    Dir.mktmpdir do |dir|
      database = File.join(dir, "production.sqlite3")
      # Release 0.1.0 as ActiveRecord left it, with a workout of the user's
      # and a session of it done.
      Sequel.sqlite(database) do |db|
        db.synchronize { it.execute_batch(File.read(Rage.root.join("test/fixtures/active_record/0.1.0.sql"))) }
        db.run <<~SQL
          INSERT INTO workouts (id, kind, title, position, source, created_at, updated_at) VALUES (900, 'workout', 'Mine', 1, 'user', '2026-10-19', '2026-10-19');
          INSERT INTO sessions (id, workout_id, date, status, created_by, created_at, updated_at) VALUES (900, 900, '2026-10-19', 'done', 'manual', '2026-10-19', '2026-10-19');
        SQL
      end

      after = run_app(database, <<~RUBY)
        connections = DB.pool.size
        { connections:, current: Database.current?(DB), exercises: Exercise.count, sessions: DB[:sessions].count,
          max_body: Iodine::DEFAULT_SETTINGS[:max_body] }
      RUBY

      # Request bodies of 1 MB at most.
      _(after).must_equal("current" => true, "connections" => 0, "exercises" => Exercise.count, "sessions" => 0, "max_body" => 1)
      # Data from before users is nobody's: it goes, kept in a copy, which
      # like the database itself only the app's user can read.
      copy = File.join(dir, "production.before-per-user.sqlite3")
      Sequel.sqlite(copy) do |db|
        _(db[:sessions].select_map(:id)).must_equal [900]
      end
      _([database, copy].map { File.stat(it).mode & 0o777 }).must_equal [0o600, 0o600]
      # No users yet: the log carries the code that makes the owner.
      _(@output).must_match(/the setup code [A-Z0-9]{5}(-[A-Z0-9]{1,5}){5}\b/)
    end
  end
end
