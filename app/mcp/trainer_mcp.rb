# The MCP server at /mcp: tools for an assistant acting as a personal trainer,
# who reads the exercise library, the equipment owned, the workouts and the
# training history, builds workouts from library exercises and plans them on
# calendar days. The write tools call the same model code as the API
# (Workout.create_with!, Workout#revise!, Session.plan_all!, ...) and mark what
# they make as the assistant's: `source: llm`, `created_by: llm` (sessions, activities, routines), notes
# `author_kind: llm`. Goals are the user's: the assistant only proposes them.
#
# Streamable HTTP in stateless mode with plain JSON answers: every POST stands
# on its own, so the server keeps nothing between requests and runs in the
# Rage process, calling the models directly.
#
# Clients sign in with a personal API token (`Authorization: Bearer lr_...`,
# made in Settings), checked by TokenVerifier; a browser session doesn't
# count. The transport's DNS rebinding guard accepts loopback hosts only;
# MCP_ALLOWED_HOSTS lists the other host names (or host:port) clients reach
# it by, comma-separated.
module TrainerMcp
  BRIEF = File.read(File.join(__dir__, "trainer_mcp/brief.md")).freeze
  BRIEF_URI = "lazy-runner://brief"

  TOOLS = [
    SearchExercises, GetExercise, ListEquipment, ListWorkouts, GetWorkout, TrainingSummary, ListSessions, ListActivities,
    ListRoutines, ListExamples, GetCoachBoard, ListCoachNotes, CreateWorkout, ImportExample, UpdateWorkout, DuplicateWorkout, ArchiveWorkout,
    SetExerciseWeight, UpdateEquipment, PlanSessions, MoveSession, RemoveSession, LogActivities, PlanRoutine, UpdateRoutine, EndRoutine,
    WriteCoachNote, UpdateCoachNote, DeleteCoachNotes, ResolveConcern, ProposeGoal
  ].freeze

  # The brief again, for clients that read prompts or resources rather than
  # the server's instructions.
  BRIEF_PROMPT = MCP::Prompt.define(
    name: "trainer_brief",
    title: "Trainer brief",
    description: "How the Lazy Runner works and the rules for planning with it. Read it before planning."
  ) { MCP::Prompt::Result.new(messages: [MCP::Prompt::Message.new(role: "user", content: MCP::Content::Text.new(BRIEF))]) }

  BRIEF_RESOURCE = MCP::Resource.define(
    uri: BRIEF_URI, name: "trainer_brief", title: "Trainer brief", mime_type: "text/markdown",
    description: "How the Lazy Runner works and the rules for planning with it."
  ) { MCP::Resource::TextContents.new(uri: BRIEF_URI, mime_type: "text/markdown", text: BRIEF) }

  def self.server
    MCP::Server.new(
      name: "lazy-runner", title: "The Lazy Runner", version: Release.id,
      instructions: BRIEF, tools: TOOLS, prompts: [BRIEF_PROMPT], resources: [BRIEF_RESOURCE],
      configuration: MCP::Configuration.new(exception_reporter: ->(error, context) { report(error, context) })
    )
  end

  # The Rack app mounted at /mcp.
  def self.app(allowed_hosts: ENV.fetch("MCP_ALLOWED_HOSTS", ""))
    MCP::Server::Transports::StreamableHTTPTransport.new(
      server, stateless: true, enable_json_response: true, token_verifier: TokenVerifier.new,
      allowed_hosts: allowed_hosts.split(",").map(&:strip).reject(&:empty?)
    )
  end

  # A tool that failed on a bug answers with a bare "internal error"; the log
  # says what it was.
  def self.report(error, context)
    Rage.logger.error("MCP #{context.inspect}: #{error.class}: #{error.message}\n#{Array(error.backtrace).first(5).join("\n")}")
  end
end
