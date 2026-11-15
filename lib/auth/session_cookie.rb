require "roda/session_middleware"
require_relative "../secrets"

module Auth
  # Roda's encrypted session cookie, read and written on every request
  # (sliding: it is renewed as it is used), as middleware inside Rage's stack
  # in front of AuthApp (config/initializers/sign_in.rb).
  module SessionCookie
    DAY = 86_400

    # Plain http on a LAN can't keep a Secure cookie, so SECURE_COOKIES=false
    # drops it, and the __Host- prefix that requires it. Behind TLS, leave it on.
    def self.secure? = ENV.fetch("SECURE_COOKIES", Rage.env.test? ? "false" : "true") != "false"

    def self.cookie_name = secure? ? "__Host-lazy_runner" : "lazy_runner"

    def self.options
      {
        secret: Secrets.session,
        key: cookie_name,
        # Signed in for 90 days from the last visit, a year at most, so the
        # player still works at the gym on a phone that dropped the app.
        max_idle_seconds: 90 * DAY,
        max_seconds: 365 * DAY,
        cookie_options: { path: "/", httponly: true, same_site: :lax, secure: secure?, max_age: 90 * DAY }
      }
    end

    def self.middleware = [RodaSessionMiddleware, options]
  end
end
