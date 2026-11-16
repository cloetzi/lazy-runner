# frozen_string_literal: true

require "rack/files"

# The API reference at /api/openapi: Rage's OpenAPI document at /json, and a
# page of our own that reads it with Swagger UI. Rage's own page loads
# swagger-ui-dist@^5 from unpkg, a floating version with no integrity check,
# into the origin that holds the session (#206). This one serves an exact
# release, kept in lib/api_reference/swagger-ui (its package.json says which,
# with its licence), from this server, under a Content-Security-Policy that
# lets nothing else run.
class ApiReference
  ROOT = File.join(__dir__, "api_reference").freeze
  # Swagger UI sets inline styles and draws its icons as data: images.
  POLICY = [
    "default-src 'none'", "script-src 'self'", "style-src 'self' 'unsafe-inline'", "img-src 'self' data:",
    "connect-src 'self'", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'"
  ].join("; ").freeze
  HEADERS = {
    "content-security-policy" => POLICY, "x-content-type-options" => "nosniff",
    "referrer-policy" => "same-origin", "cache-control" => "no-cache"
  }.freeze
  # The page and what it loads; nothing else under ROOT is served.
  FILES = {
    "" => "index.html", "/" => "index.html", "/init.js" => "init.js",
    "/swagger-ui/swagger-ui-bundle.js" => "swagger-ui/swagger-ui-bundle.js",
    "/swagger-ui/swagger-ui.css" => "swagger-ui/swagger-ui.css"
  }.freeze

  def initialize(document)
    @document = document
    @files = Rack::Files.new(ROOT)
  end

  def call(env)
    path = env["PATH_INFO"]
    return @document.call(env) if path == "/json"

    file = FILES[path] or return [404, { "content-type" => "text/plain" }, ["Not Found"]]
    status, headers, body = @files.call(env.merge("PATH_INFO" => "/#{file}"))
    [status, headers.merge(HEADERS), body] # a 304 too
  end
end
