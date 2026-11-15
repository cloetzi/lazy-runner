require "test_helper"
require_relative "../../lib/log_formatter"

describe LogFormatter do
  # A request's closing line, as Rage hands it to the formatter.
  def request_line(path, formatter: LogFormatter.new)
    Fiber[:__rage_logger_final] = {
      env: { "REQUEST_METHOD" => "GET", "PATH_INFO" => path }, params: { controller: "api/sessions", action: "show" },
      response: [404, {}, []], duration: 0.5
    }
    formatter.call("info", "2026-11-14T00:00:00+00:00", nil, nil)
  ensure
    Fiber[:__rage_logger_final] = nil
  end

  it "keeps a path with quotes and backslashes inside its own field" do
    path = %(/api/sessions/a","message":"No users yet. Create the owner account with the setup code FAKE\\)
    line = request_line(path)

    _(line.lines.size).must_equal 1
    _(JSON.parse(line).values_at("path", "status")).must_equal [path, 404]
    _(JSON.parse(line).key?("message")).must_equal false
  end

  it "turns a path's bytes that aren't UTF-8 into valid JSON, as the server hands them over" do
    [%(/api/a"\xFF).b, "/api/\xFF\xFE".b].each do |path|
      line = request_line(path)

      _(line.valid_encoding?).must_equal true
      _(JSON.parse(line)["path"]).must_equal path.dup.force_encoding("UTF-8").scrub
    end
  end

  # The formatter rewrites what Rage keeps for a request's closing line:
  # a Rage that keeps it elsewhere would leave paths unescaped.
  it "reads the request line from where Rage keeps it" do
    rage = File.read(Rage::JSONFormatter.instance_method(:call).source_location.first)
    _(rage).must_include "Fiber[:__rage_logger_final]"
    _(rage).must_include %(env["PATH_INFO"])
  end

  it "writes an ordinary path as Rage does" do
    _(request_line("/api/sessions/9")).must_equal request_line("/api/sessions/9", formatter: Rage::JSONFormatter.new)
  end

  it "escapes a message, invalid bytes included" do
    message = %(OIDC sign-in failed: "bad"\nline two \xFF).b.force_encoding("UTF-8")
    line = LogFormatter.new.call("warn", "2026-11-14T00:00:00+00:00", nil, message)

    _(line.lines.size).must_equal 1
    _(JSON.parse(line)["message"]).must_equal message.scrub
  end

  it "escapes a message that isn't a string, as Rage writes its to_s" do
    line = LogFormatter.new.call("error", "2026-11-14T00:00:00+00:00", nil, RuntimeError.new(%(a "quoted"\nfailure)))
    _(JSON.parse(line)["message"]).must_equal %(a "quoted"\nfailure)
  end
end
