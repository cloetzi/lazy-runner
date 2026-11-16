# frozen_string_literal: true

require_relative "access"
require_relative "csrf"
require_relative "token"
require_relative "throttles"

module Auth
  # The gate in front of the API, in AuthApp's route block: what a request
  # under /api needs (lib/auth/access.rb), checked before Rodauth's routes
  # and Rage see it. What it lets through goes on with the user's id in
  # env["lazy_runner.user_id"] (and a token's name in
  # env["lazy_runner.agent_name"]), which ApplicationController reads.
  # Included in AuthApp, a Roda app: it uses Roda's request, response and
  # env, and AuthApp's rodauth.
  module Gate
    USER_MISMATCH = "This change was made by another user, who is no longer signed in here"

    private

    # Before Rodauth's routes: a token request answered or let through
    # (true), the CSRF check on writes, the throttles, and a stale session
    # forgotten.
    def gate_before_sign_in(r, access) # rubocop:disable Naming/PredicateMethod -- the gate, not a question
      # A personal API token stands in for the session: no cookie, so nothing
      # for another site to ride on, and no CSRF check. Rodauth's routes and
      # the public ones don't read one.
      if Access.reads_token?(access) && Token.bearer?(r.env)
        token_request(r, access)
        return true
      end

      if Csrf.unsafe?(r) && (refusal = Csrf.refusal(r))
        halt_json(403, refusal)
      end

      # Every route that checks a password, so none can be used to guess one.
      if r.post? && (limit = Throttles.for(r.path_info, rodauth))
        throttle, key = limit
        wait = throttle.hit(key)
        halt_json(429, "Too many attempts; try again in #{wait} seconds", headers: { "retry-after" => wait.to_s }) if wait
      end

      # A device signed out elsewhere still carries its cookie: forget it, so
      # signing in again works, and /api/me answers as for anyone signed out.
      rodauth.clear_session if Access.answers_signed_out?(access) && rodauth.logged_in? && !rodauth.currently_active_session?
      false
    end

    # After Rodauth's routes: the signed-in user for the rest of /api, a 401
    # for anyone else.
    def gate_after_sign_in(r, access)
      return if access == :public

      # /api/me answers for itself: who is signed in, or whether to set up.
      unless access == :optional
        rodauth.check_active_session
        rodauth.require_authentication
      end
      env["lazy_runner.user_id"] = rodauth.session_value
      env["rodauth"] = rodauth
      refuse_other_user(r)
    end

    # Lets a request with a valid token through as its user, else answers it.
    # /api/me answers a token it can't take for itself, as signed out.
    def token_request(r, access)
      # Refused before the token is looked at, so a refused try isn't a use.
      halt_json(403, Token::REFUSED) if access == :browser
      token = Token.authenticate(r.env)

      # A token is good for /api only with REST access (ApiToken#rest?);
      # without it, for /mcp alone.
      unless token.claims["rest"]
        return if access == :optional

        halt_json(403, Token::MCP_ONLY)
      end

      env["lazy_runner.user_id"] = token.subject.to_i
      # What a script or agent writes with the token carries its name.
      env["lazy_runner.agent_name"] = token.claims["agent_name"]
      refuse_other_user(r)
    rescue MCP::Server::OAuth::Error => error
      return if access == :optional

      halt_json(401, Token::INVALID, headers: { "www-authenticate" => Token.challenge(error) }.compact)
    end

    # A write the PWA queued for one user (X-Lazy-Runner-User, see
    # public/js/outbox.js) is refused while someone else is signed in: another
    # tab may send it in the moment between the next person's sign-in and
    # the device dropping the queue (#205).
    def refuse_other_user(r)
      meant = r.env["HTTP_X_LAZY_RUNNER_USER"]
      return if meant.nil? || !Csrf.unsafe?(r) || meant == env["lazy_runner.user_id"].to_s

      halt_json(409, USER_MISMATCH, code: "user_mismatch")
    end

    # Answers the request now, in the app's error shape.
    def halt_json(status, message, headers: {}, code: nil)
      response.status = status
      response["content-type"] = "application/json"
      headers.each { |key, value| response[key] = value }
      response.write(JSON.generate(AuthApp.error_body(status, message, code:)))
      request.halt
    end
  end
end
