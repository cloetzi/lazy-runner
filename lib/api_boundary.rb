# frozen_string_literal: true

require "json"

# What every request to the API and the MCP server goes through before the
# app sees it, and every answer after (config/initializers/sign_in.rb).
module ApiBoundary
  PATHS = %r{\A/(api|mcp)(/|\z)}

  # The answers hold the user's data and are JSON: no cache along the way
  # keeps one (the service worker keeps its own copies, by its own rules),
  # and no browser reads one as anything else. A route that says how it is
  # cached (the API reference page) keeps its own.
  class Headers
    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      return [status, headers, body] unless PATHS.match?(env["PATH_INFO"])

      headers = headers.dup if headers.frozen?
      headers["cache-control"] ||= "no-store"
      headers["x-content-type-options"] ||= "nosniff"
      [status, headers, body]
    end
  end

  # A JSON body under /api is an object, or the request is answered 400 in
  # the API's error shape. Rage would answer one it can't read (bad JSON, an
  # array, a number) with an empty 400, and Rodauth's routes with a 500.
  # /mcp reads its own body (the mcp gem answers JSON-RPC errors).
  class JsonBody
    NOT_AN_OBJECT = "Send the body as a JSON object"

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless env["PATH_INFO"].start_with?("/api/") && json?(env)

      input = env["rack.input"]
      raw = input&.read
      input&.rewind
      return @app.call(env) if raw.nil? || raw.empty?

      parsed = begin
        JSON.parse(raw)
      rescue JSON::ParserError, EncodingError
        nil
      end
      return @app.call(env) if parsed.is_a?(Hash)

      body = JSON.generate(error: { code: "bad_request", message: NOT_AN_OBJECT })
      [400, { "content-type" => "application/json" }, [body]]
    end

    private

    def json?(env) = env["CONTENT_TYPE"].to_s.match?(%r{\Aapplication/json\b}i)
  end
end
