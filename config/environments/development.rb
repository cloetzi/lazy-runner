# frozen_string_literal: true

Rage.configure do
  # Specify the number of server processes to run. Defaults to number of CPU cores.
  config.server.workers_count = 1

  # Specify the port the server will listen on.
  config.server.port = 3000

  # Specify the logger. Unbuffered, so lines reach the container's log as
  # they are written (the setup code among them), not when the buffer fills.
  $stdout.sync = true
  config.logger = Rage::Logger.new($stdout)

  config.middleware.use Rage::Reloader
end
