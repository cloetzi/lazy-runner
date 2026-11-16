# frozen_string_literal: true

require "rack/files"
require "rack/mime"

# Serves the PWA in public/ with `Cache-Control: no-cache`, so browsers check
# for a newer version on every load (a cheap 304 when nothing changed) and a
# plain reload picks up a new release. Iodine's built-in file server would
# cache for an hour with no way to configure it. Anything that is not a file
# falls through to the API.
#
# Every file goes out with a Content-Security-Policy: the PWA is plain ES
# modules and styles from this origin, so nothing from anywhere else runs in
# the origin that holds the session, and no other site frames it.
class StaticFiles
  POLICY = [
    "default-src 'self'", "script-src 'self'", "style-src 'self' 'unsafe-inline'", "img-src 'self' data:",
    "connect-src 'self'", "object-src 'none'", "base-uri 'none'", "form-action 'self'", "frame-ancestors 'none'"
  ].join("; ").freeze
  HEADERS = {
    "cache-control" => "no-cache", "content-security-policy" => POLICY,
    "x-content-type-options" => "nosniff", "referrer-policy" => "same-origin"
  }.freeze

  # Rack does not know the web app manifest yet; browsers want this type to install the app.
  Rack::Mime::MIME_TYPES[".webmanifest"] ||= "application/manifest+json"

  def initialize(app, root)
    @app = app
    @files = Rack::Files.new(root, HEADERS)
  end

  def call(env)
    return @app.call(env) unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

    path = env["PATH_INFO"]
    response = @files.call(env.merge("PATH_INFO" => path == "/" ? "/index.html" : path))
    response[0] == 404 ? @app.call(env) : response
  end
end
