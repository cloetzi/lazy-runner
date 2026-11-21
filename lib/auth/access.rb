# frozen_string_literal: true

module Auth
  # Who may ask for what under /api, by the path's first segment after /api:
  # one row per resource in config/routes.rb (test/requests/access_test.rb
  # fails when a route has no row, or a row no route). lib/auth/gate.rb acts
  # on it. Outside /api the gate stands aside: /mcp checks its own tokens
  # (TrainerMcp::TokenVerifier) and the PWA's files are public.
  #
  # - public: anyone, and no session or token is read.
  # - sign_in: Rodauth's own routes (lib/auth_app.rb): signing in and out,
  #   making an account, changing the password. No token is read.
  # - optional: answers signed in or not (/api/me says who, or whether to
  #   set up); a token without REST access, or a bad one, reads as signed out.
  #   Only at the row's own path: anything longer (/api/me/) is signed_in.
  # - browser: a signed-in browser only. Managing the account (devices,
  #   tokens) and the install's users and invites can't be done with an API
  #   token, so a leaked one can't make itself another, or another way in.
  #   Which of these only the owner may use is the controllers' to say
  #   (ApplicationController#owner_only!).
  # - signed_in: a session, or an API token with REST access (ApiToken#rest?).
  #
  # Every write under /api, public ones included, passes the CSRF check
  # (lib/auth/csrf.rb) unless it carries an API token.
  module Access
    REQUIREMENTS = %i[public sign_in optional browser signed_in].freeze
    # Rodauth's own routes (AuthApp's prefix), the "auth" row.
    SIGN_IN = "/api/auth"

    RULES = {
      "version" => :public,
      "openapi" => :public,
      "auth" => :sign_in,
      "me" => :optional,
      "account" => :browser,
      "users" => :browser,
      "invites" => :browser,
      "today" => :signed_in,
      "settings" => :signed_in,
      "exercises" => :signed_in,
      "equipment" => :signed_in,
      "programs" => :signed_in,
      "examples" => :signed_in,
      "workouts" => :signed_in,
      "sessions" => :signed_in,
      "activities" => :signed_in,
      "calendar" => :signed_in,
      "check_ins" => :signed_in,
      "plan_changes" => :signed_in,
      "routines" => :signed_in,
      "goals" => :signed_in,
      "coach" => :signed_in,
      "history" => :signed_in
    }.freeze

    API = %r{\A/api(?:/([^/]*))?(?:/|\z)}

    # A path's requirement, nil outside /api. A path under /api that no row
    # names (no route has it, so Rage answers 404) needs what most do.
    # Where a Bearer API token is read in place of the session.
    READS_TOKEN = %i[optional browser signed_in].freeze
    # The routes that answer someone signed out, so a session cookie left
    # from a device signed out elsewhere is forgotten first.
    ANSWERS_SIGNED_OUT = %i[optional sign_in].freeze

    def self.for(path)
      match = API.match(path) or return nil
      segment = match[1]
      requirement = RULES.fetch(segment, :signed_in)
      requirement == :optional && path != "/api/#{segment}" ? :signed_in : requirement
    end

    def self.reads_token?(requirement) = READS_TOKEN.include?(requirement)
    def self.answers_signed_out?(requirement) = ANSWERS_SIGNED_OUT.include?(requirement)

    # The row a path under /api falls under, nil for none (for the test that
    # every route has one).
    def self.segment(path) = API.match(path)&.[](1)
  end
end
