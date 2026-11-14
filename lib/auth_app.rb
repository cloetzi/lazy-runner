require "roda"
require "roda/session_middleware"
require "omniauth_openid_connect"
require_relative "secrets"
require_relative "setup_code"
require_relative "oidc"
require_relative "throttle"
require_relative "hashing"

# Accounts and sign-in: Rodauth, on the app's own Sequel connection.
#
# Two middlewares inside Rage's stack (config/initializers/sign_in.rb), after
# Rage::FiberWrapper, so they run in the request's fiber and take their turn
# on the one connection like any request:
#
# - SessionCookie.middleware: Roda's encrypted session cookie, read and written on
#   every request (sliding: it is renewed as it is used).
# - AuthApp: Rodauth's JSON routes under /api/auth (sign in, sign out, set up
#   the owner, change the password, and signing in with an OpenID Connect
#   provider when lib/oidc.rb has one), and the gate in front of the API: the
#   CSRF check on writes, the signed-in user (or an API token's) for /api, a
#   401 for anyone else. What it lets through goes on to Rage with the user's
#   id in env["lazy_runner.user_id"]. /mcp checks its own tokens
#   (TrainerMcp::TokenVerifier).
#
# Rodauth keeps the account (users) apart from the ways of proving who you
# are (a password, an identity at the OIDC provider in user_identities), so
# a user can have either or both.
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

class AuthApp < Roda
  # Signed-in data: everything under /api but these. /mcp checks its own
  # tokens (TrainerMcp::TokenVerifier) and takes no session.
  PUBLIC = %r{\A/api/(version|openapi)(/|\z)}
  GUARDED = %r{\A/api(/|\z)}
  # Managing the account (devices, tokens) and the install's users and
  # invites takes a signed-in browser, so a leaked token can't make itself
  # another one, or another way in.
  ACCOUNT = %r{\A/api/(account|users|invites)(/|\z)}
  # The Bearer scheme as the mcp gem reads it: "Bearer" then a space or nothing.
  BEARER = /\ABearer(?: |\z)/i
  # Rodauth's own routes.
  PREFIX = "/api/auth".freeze
  UNSAFE = %w[POST PUT PATCH DELETE].freeze
  # The CSRF check's refusals, by reason.
  REFUSED = "Refused: the request didn't come from this app".freeze
  NOT_JSON = "Send the body as application/json".freeze
  TOKEN_REFUSED = "Manage the account from a signed-in browser, not with an API token".freeze
  USER_MISMATCH = "This change was made by another user, who is no longer signed in here".freeze
  INVITE_GONE = "This invite link has expired, been used or been revoked; ask for a new one".freeze
  # Argon2id at the cost real passwords are hashed with: verifying against
  # it takes as long as verifying a real one.
  HASH_COST = (Rage.env.test? ? { t_cost: 1, m_cost: 5, p_cost: 1 } : { t_cost: 2, m_cost: 16, p_cost: 1 }).freeze
  DUMMY_HASH = Argon2::Password.create("never a password", **HASH_COST)

  # Sign-in attempts, ten a minute per username. They count apart from each
  # other, so a stream of made-up usernames can't use up the attempts of
  # real users, whose hashing is bounded by how few they are (#207).
  THROTTLE = Throttle.new(per_key: Throttle::Limit.new(10, 60))
  # The dummy hash a sign-in with an unknown username costs: 60 a minute in
  # all. Past that, such a sign-in waits as long as a hash takes instead, so
  # it answers as before, in the same time, without the work.
  DUMMY_HASHES = Throttle.new(per_key: Throttle::Limit.new(60, 60))
  # Setup and invite attempts, per username. A wrong setup code or invite
  # hashes nothing, and both are too long to guess (130 and 256 bits), so
  # there is no total for a stream of them to use up.
  ACCOUNTS = Throttle.new(per_key: Throttle::Limit.new(10, 60))
  # Changing the password checks the current one, and wrong ones don't lock
  # the account: five tries per account in 15 minutes.
  PASSWORD_CHANGES = Throttle.new(per_key: Throttle::Limit.new(5, 900), total: Throttle::Limit.new(60, 60))
  # Starting an OIDC sign-in to link an identity: ten a minute per signed-in
  # user. Signed out it isn't counted: a start only redirects, with the
  # provider's cached discovery document and the state in the session
  # cookie, and a count shared by everyone signed out would let anyone keep
  # the provider's users out.
  OIDC_STARTS = Throttle.new(per_key: Throttle::Limit.new(10, 60))

  # The app's error shape, { error: { code, message, fields } }, by status.
  CODES = {
    400 => "bad_request", 401 => "unauthorized", 403 => "forbidden", 404 => "not_found", 405 => "bad_request",
    406 => "bad_request", 409 => "conflict", 422 => "invalid", 429 => "too_many_requests", 502 => "unavailable"
  }.freeze
  # The OIDC provider didn't answer: its discovery document, keys or token
  # endpoint. Any other failure is an answer that didn't check out.
  OIDC_UNREACHABLE = [
    OpenIDConnect::Discovery::DiscoveryFailed, Faraday::Error, SocketError,
    SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
  ].freeze

  @swept_at = nil

  # Verifies against the dummy hash, and keeps a running average of how long
  # that takes, for a sign-in past the dummy hashes' budget to wait as long.
  # Only the hash is timed, not the wait for a hashing thread.
  def self.dummy_verify(password)
    took = Hashing.run do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Argon2::Password.verify_password(password.to_s, DUMMY_HASH)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end
    @hash_seconds = @hash_seconds ? (@hash_seconds * 0.9) + (took * 0.1) : took
  end

  def self.hash_seconds = @hash_seconds

  # Measured warm: the first verify in a process also maps Argon2's memory.
  dummy_verify("never a password either")
  @hash_seconds = nil
  dummy_verify("never a password either")

  # True at most once a minute: time to remove devices past their deadline.
  def self.sweep_due?(now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
    return false if @swept_at && now - @swept_at < 60

    @swept_at = now
  end

  # The mcp gem's bearer check, with the app's verifier: one reading of a
  # token for /api and /mcp alike.
  def self.authenticator
    @authenticator ||= MCP::Server::OAuth::Authenticator.new(token_verifier: TrainerMcp::TokenVerifier.new)
  end

  # A page of the app to go back to: a path, not another site.
  def self.local_path(value)
    value if value.is_a?(String) && value.length <= 500 && value.match?(%r{\A/(?![/\\])[^\\\x00-\x20\x7f]*\z})
  end

  def self.error_body(status, message, fields: nil, code: nil, **extra)
    { error: { code: code || CODES.fetch(status, "bad_request"), message:, fields: }.compact, **extra }
  end

  opts[:sessions_convert_symbols] = true

  # A path under /api/auth that Rodauth doesn't know goes on to Rage, to be its 404.
  plugin :middleware, next_if_not_found: true
  plugin :halt
  plugin :json_parser, content_type_regexp: %r{\Aapplication/json\b}i
  plugin :rodauth, json: :only do
    enable :json, :login, :logout, :create_account, :change_password, :lockout, :active_sessions, :argon2,
           :internal_request, :omniauth_base

    db DB
    prefix PREFIX
    hmac_secret Secrets.derive("rodauth hmac")

    accounts_table :users
    login_column :username
    login_param "username"
    login_label "Username"
    skip_status_checks? true
    require_email_address_logins? false
    require_login_confirmation? false
    require_password_confirmation? false
    require_bcrypt? false
    require_mail? false
    login_minimum_length 3
    login_maximum_length 40
    password_minimum_length 8
    password_hash_cost HASH_COST

    # POST /api/auth/create-account makes the owner account once, with the
    # setup code from the log, and everyone else's with an invite.
    # The owner made in the app is signed in; an account made from code (a
    # rake task, a test) signs nobody in, so it leaves no signed-in device.
    create_account_autologin? { !internal_request? }
    # Signing in after a change of password: the field is "new_password".
    new_password_param "new_password"
    # Someone who signs in only with the OIDC provider has no password to
    # give: they can set one, signed in.
    change_password_requires_password? { has_password? }

    # One answer for an unknown user, a wrong password and a locked account,
    # so the answer doesn't tell which usernames exist.
    no_matching_login_message "Wrong username or password"
    invalid_password_message "Wrong username or password"
    login_lockout_error_flash "Wrong username or password"
    lockout_error_status 401
    require_login_error_flash "Sign in to continue"
    active_sessions_error_flash "This device has been signed out"

    # Ten wrong passwords lock the account for 15 minutes, then it unlocks on
    # its own. There is no mailer, so the unlock-by-email routes go.
    max_invalid_logins 10
    # The deadline is worked out in Ruby: the table has no default for it.
    set_deadline_values? true
    account_lockouts_deadline_interval({ minutes: 15 }.freeze)
    unlock_account_route nil
    unlock_account_request_route nil

    # Devices stay signed in for 90 days since last use, a year at most.
    session_inactivity_deadline 90 * SessionCookie::DAY
    session_lifetime_deadline 365 * SessionCookie::DAY

    # Every request checks its device is still signed in (a read). Its last
    # use is written at most hourly (the cookie remembers when), and devices
    # past their deadline are removed at most once a minute, so a page's
    # burst of GETs doesn't queue writes on the one connection.
    update_current_session? do
      now = Time.now.to_i
      next false if now - session["last_use"].to_i < 3600

      set_session_value("last_use", now)
      true
    end

    remove_inactive_sessions do
      super() if AuthApp.sweep_due?
    end

    # Inside the transaction, which begins IMMEDIATE: two setups racing take
    # turns, and the second finds the owner the first made; two people on
    # one invite link, and the second finds it used. Accounts made from code
    # (rake users:create_owner, tests) need neither a code nor an invite.
    before_create_account do
      first = db[:users].empty?
      if internal_request?
        nil
      elsif (invite = param_or_nil("invite").presence)
        # An invite is an owner's: on an install without one, none counts.
        # One time for the check and its use, so it can't expire in between.
        @invited_at = Time.now
        throw_error_status(404, "invite", INVITE_GONE) if first || !Invite.pending_token?(invite, now: @invited_at)
        @invite = invite
      else
        unless first
          set_response_error_status(404)
          throw_error("setup_code", "This install already has an owner; sign in instead")
        end
        throw_error_status(403, "setup_code", "Wrong setup code") unless SetupCode.match?(param("setup_code"))
      end

      account[:owner] = first
      account[:created_at] = account[:updated_at] = Time.now
    end

    # A new user starts with nothing of their own: settings are made on first
    # use, and they pick their gear and import example programs in the app.
    # The invite is used up once the account is saved: a sign-up refused
    # before then (a username taken) leaves it to try again, since Rodauth
    # leaves its transaction by throw, which commits.
    after_create_account do
      if @invite
        raise "invite used by another sign-up in this transaction" unless Invite.redeem!(@invite, now: @invited_at)
      elsif !internal_request?
        SetupCode.consume!
      end
    end

    # A new password signs out every other device and revokes the API
    # tokens: whoever knew the old one is out too, tokens they made included.
    # The user can keep them (`sign_out_others: false`), but not when
    # leaving a temporary password, nor on a reset (from code, by the owner).
    # Rodauth's active sessions sign the other devices out on every change
    # of password; after_change_password decides instead.
    clear_tokens do |reason|
      super(reason) unless reason == :change_password
    end

    # Whether there was a password to know: setting a first one (signed in
    # with the OIDC provider) has no one to lock out of a linked sign-in.
    before_change_password do
      @had_password = has_password?
    end

    after_change_password do
      users = db[:users].where(id: account_id)
      temporary = users.get(:password_change_required)
      users.update(password_change_required: false) if temporary && !internal_request?
      if internal_request? || temporary || Record.boolean(raw_param("sign_out_others")) != false
        remove_all_active_sessions_except_current
        ApiToken.of(account_id).delete
        # A sign-in at the OIDC provider linked with the old password goes
        # too: whoever knew it could have linked their own.
        UserIdentity.of(account_id).delete if @had_password || internal_request?
      end
    end

    # The browser drops what it cached for this user (the PWA drops its own
    # copies too, see public/js/account.js).
    after_logout do
      response["clear-site-data"] = '"cache"'
    end

    # Signed in already: sign out first, so one device never mixes two users.
    already_logged_in do
      set_response_error_status(409)
      set_error_flash("Already signed in; sign out first")
      return_json_response
    end

    # No links are built from the request's host (there are no emails), so
    # the domain is whatever the request says.
    domain { request.host }

    # Usernames: letters, digits, dots, dashes and underscores.
    login_meets_requirements? do |login|
      next false unless super(login)
      next true if login.match?(/\A[A-Za-z0-9._-]+\z/)

      set_login_requirement_error_message(:invalid_username, "Use letters, digits, dots, dashes and underscores only")
      false
    end

    # An unknown username costs as much as a wrong password, so the time an
    # answer takes doesn't tell which usernames exist either. Past the dummy
    # hashes' budget it waits as long instead, on a hashing thread like a
    # hash, which costs nothing.
    after_no_matching_login do
      if AuthApp::DUMMY_HASHES.hit("hash")
        Hashing.run { sleep AuthApp.hash_seconds }
      else
        AuthApp.dummy_verify(param(password_param))
      end
    end

    active_sessions_insert_hash do
      super().merge(device: request.user_agent.to_s[0, 200].presence)
    end

    # Rodauth's { "error": ..., "field-error": [field, message] } in the
    # app's one error shape, so the PWA reads every error the same way.
    json_response_body do |hash|
      body =
        if (message = hash["error"])
          field, problem = hash["field-error"]
          status = response.status || 400
          # A failed sign-in names no field: which one would tell an unknown
          # username from a wrong password.
          field = nil if status == 401 && request.path_info == "#{PREFIX}/login"
          AuthApp.error_body(status, problem || message, fields: field && { field => [problem] })
        else
          # The OIDC request phase answers with the provider's authorize_url.
          { message: hash["success"], authorize_url: hash["authorize_url"] }.compact
        end
      JSON.generate(body)
    end

    # Signing in with an OpenID Connect provider (lib/oidc.rb), when one is
    # set: the authorization code flow with PKCE, a state and a nonce, the ID
    # token checked against the provider's keys (omniauth_openid_connect).
    #
    # 1. The PWA posts to /api/auth/oidc, as JSON like every write here (the
    #    gate's CSRF check), with an `invite` to join with or a `next` page,
    #    and gets back the provider's `authorize_url` to send the browser to.
    #    Signed in, it links the identity to the signed-in user instead.
    # 2. The provider sends the browser back to /api/auth/oidc/callback (a
    #    plain GET from another site, which is why the cookie is
    #    SameSite=Lax and not Strict), which signs the user in or links the
    #    identity and redirects to the sign-in page or Settings with the
    #    outcome. The state in the session ties the callback to the browser
    #    that started it, so nobody can sign you in as them, or link their
    #    identity to your account.
    #
    # An identity signs in the user it is linked to, never one with a
    # matching username or email: a provider's names are the user's to pick.
    # OmniAuth runs under /api/auth (its SCRIPT_NAME), so /api/auth/oidc.
    omniauth_prefix ""
    # origin_param: false, so OmniAuth doesn't keep the Referer in the
    # cookie, which nothing reads and a long URL would overfill.
    omniauth_provider Oidc::Strategy, name: :oidc, discovery: true, pkce: true, response_type: "code",
                                      scope: %i[openid profile email], origin_param: false

    omniauth_setup do
      settings = Oidc.settings
      options = omniauth_strategy.options
      options.issuer = settings.issuer
      options.client_signing_alg = settings.signing_alg
      options.client_auth_method = settings.auth_method
      client = options.client_options
      client.identifier = settings.client_id
      client.secret = settings.client_secret
      # The callback URL is OIDC_REDIRECT_URI, the same on the way out and
      # back, never this request's Host or X-Forwarded-Host: those come from
      # the client, which could send the provider's code to its own host (#209).
      options.full_host = URI.join(settings.redirect_uri, "/").to_s.chomp("/")
      client.redirect_uri = settings.redirect_uri
    end

    # What the callback is for, kept in the session across the provider's
    # pages: link to the signed-in user, join with an invite, or sign in.
    omniauth_before_request_phase do
      # The home page is where the sign-in page goes anyway.
      next_page = AuthApp.local_path(param_or_nil("next"))
      intent = { "next" => (next_page unless next_page == "/") }
      if logged_in?
        # A temporary password leaves nothing but choosing a new one.
        if db[:users].where(id: session_value, password_change_required: true).any?
          set_response_error_status(401)
          set_error_flash("Choose a new password first: the one you signed in with was temporary")
          return_json_response
        end
        intent["link"] = session_value
      elsif (invite = param_or_nil("invite"))
        intent["invite"] = invite
      end
      set_session_value("oidc", intent.compact)
    end

    # The provider refused, the person cancelled, the answer didn't check
    # out (state, nonce, signature, a code it won't exchange), or the
    # provider couldn't be reached: nobody is signed in. OmniAuth turns any
    # error in its phases into this.
    omniauth_on_failure do
      type = omniauth_error_type.to_s
      error = omniauth_error
      unreachable = %w[failed_to_connect timeout].include?(type) || OIDC_UNREACHABLE.any? { error.is_a?(it) }
      Rage.logger.warn("OIDC sign-in failed: #{type}#{": #{error.class}: #{error.message}" if error}")
      unless omniauth_strategy.on_callback_path?
        set_response_error_status(502)
        set_error_flash(
          if unreachable then "Can't reach #{Oidc.settings.name}; try again, or sign in with your password"
          else "Couldn't start signing in with #{Oidc.settings.name}; the server's log says why"
          end
        )
        return_json_response
      end

      outcome = if type == "access_denied" then "cancelled"
                elsif unreachable then "unavailable"
                else "failed"
                end
      oidc_finish(outcome, remove_session_value("oidc") || {})
    end

    auth_class_eval do
      # Argon2 off the worker's thread (lib/hashing.rb).
      private def password_hash(password) = Hashing.run { super(password) }
      private def password_hash_match?(hash, password) = Hashing.run { super(hash, password) }

      # A locked account is turned away before its password is checked, and
      # one that signs in only with the OIDC provider has no password to
      # check (Rodauth then hashes nothing): hash anyway, so either answers
      # in the time any other sign-in takes (#208). Defined here, not as the
      # before_login_attempt setting, which runs after the lockout feature
      # has already turned a locked account away.
      def before_login_attempt
        AuthApp.dummy_verify(param(password_param)) if locked_out? || !has_password?
        super
      end

      def route_omniauth!
        return unless Oidc.enabled?

        super
        # The callback, once the provider's answer checked out.
        oidc_callback if omniauth_auth
      end

      private

      def oidc_callback
        intent = remove_session_value("oidc") || {}
        issuer = Oidc.settings.issuer
        subject = omniauth_uid.to_s
        claims = omniauth_extra&.dig("raw_info")&.to_h || {}
        name = claims.values_at("preferred_username", "email", "name").find(&:present?)&.to_s&.slice(0, 100)
        identity = UserIdentity.find_identity(issuer, subject)
        now = Time.now

        if (user_id = intent["link"])
          oidc_finish("signed_out", intent) unless logged_in? && session_value == user_id
          oidc_finish(identity.user_id == user_id ? "linked" : "linked_elsewhere", intent) if identity
          Current.set(user: User.with_pk!(user_id)) do
            oidc_finish("already_linked", intent) unless UserIdentity.where(issuer:).empty?
            UserIdentity.create(issuer:, subject:, username: name, last_used_at: now)
          end
          oidc_finish("linked", intent)
        end

        # Signed in meanwhile (in another tab): sign out first.
        oidc_finish("signed_in", intent) if logged_in?

        if identity
          user_id = identity.user_id
          Current.set(user: User.with_pk!(user_id)) { identity.update(username: name || identity.username, last_used_at: now) }
        else
          user_id, refusal = oidc_new_account(intent, claims, issuer:, subject:, name:, now:)
          oidc_finish(refusal, intent) if refusal
        end

        account_from_id(user_id)
        transaction { login_session("oidc") }
        oidc_finish(nil, intent)
      rescue Sequel::UniqueConstraintViolation
        # Another callback for the same identity (a second tab) linked it
        # or made its account first.
        oidc_finish("failed", intent)
      end

      # An account for an identity no one has linked: with an invite, or
      # for anyone with OIDC_AUTO_SIGNUP, and only once the install has its
      # owner (made with the setup code). Returns the user's id, or why not.
      def oidc_new_account(intent, claims, issuer:, subject:, name:, now:)
        invite = intent["invite"]
        transaction do
          next [nil, "no_account"] if db[:users].empty?

          if invite
            next [nil, "invite_gone"] unless Invite.redeem!(invite, now:)
          elsif !Oidc.settings.auto_signup
            next [nil, "no_account"]
          end

          username = Oidc.username(claims, taken: ->(candidate) { !db[:users].where(username: candidate).empty? })
          id = db[:users].insert(username:, owner: false, created_at: now, updated_at: now)
          Current.set(user: User.with_pk!(id)) { UserIdentity.create(issuer:, subject:, username: name, last_used_at: now) }
          [id, nil]
        end
      end

      # Back to the app with the outcome: Settings for a link, else the
      # sign-in page, which carries on as for any sign-in (`next`, the
      # welcome screen) or says what went wrong.
      def oidc_finish(outcome, intent)
        query =
          if intent["link"] then { oidc: outcome }
          else { oidc_error: outcome, next: intent["next"] }
          end
        page = intent["link"] ? "/settings.html" : "/signin.html"
        query = URI.encode_www_form(query.compact)
        request.redirect("#{page}#{"?#{query}" unless query.empty?}#{"#account" if intent["link"]}")
      end
    end
  end

  route do |r|
    path = r.path_info

    # A personal API token stands in for the session: no cookie, so nothing
    # for another site to ride on, and no CSRF check. Another scheme (a
    # proxy's Basic sign-in passed through, say) is left alone.
    if GUARDED.match?(path) && !PUBLIC.match?(path) && !path.start_with?(PREFIX) &&
       r.env["HTTP_AUTHORIZATION"].to_s.b.match?(BEARER)
      token_request(r, path)
      return nil
    end

    if UNSAFE.include?(r.request_method) && GUARDED.match?(path) && (refusal = csrf_refusal(r))
      halt_json(403, refusal)
    end

    # Every route that checks a password, so none can be used to guess one.
    if r.post? && (limit = throttle_for(path))
      throttle, key = limit
      wait = throttle.hit(key)
      halt_json(429, "Too many attempts; try again in #{wait} seconds", headers: { "retry-after" => wait.to_s }) if wait
    end

    # A device signed out elsewhere still carries its cookie: forget it, so
    # signing in again works, and /api/me answers as for anyone signed out.
    me = path == "/api/me"
    if (me || path.start_with?(PREFIX)) && rodauth.logged_in? && !rodauth.currently_active_session?
      rodauth.clear_session
    end
    r.on("api", "auth") { r.rodauth }

    if GUARDED.match?(path) && !PUBLIC.match?(path)
      # /api/me answers for itself: who is signed in, or whether to set up.
      unless me
        rodauth.check_active_session
        rodauth.require_authentication
      end
      env["lazy_runner.user_id"] = rodauth.session_value
      env["rodauth"] = rodauth
      refuse_other_user(r)
    end

    # Anything else goes on to Rage.
    nil
  end

  private

  # Lets a request with a valid token through as its user, else answers it.
  # The token is read and checked as /mcp checks it (the mcp gem's bearer
  # parsing, TrainerMcp::TokenVerifier), so the two can't drift apart.
  # /api/me answers a bad token for itself, as signed out.
  def token_request(r, path)
    # Refused before the token is looked at, so a refused try isn't a use.
    halt_json(403, TOKEN_REFUSED) if ACCOUNT.match?(path)
    token = AuthApp.authenticator.authenticate(r.env)

    env["lazy_runner.user_id"] = token.subject.to_i
    # What a script or agent writes with the token carries its name.
    env["lazy_runner.agent_name"] = token.claims["agent_name"]
    refuse_other_user(r)
  rescue MCP::Server::OAuth::Error => e
    return if path == "/api/me"

    _, headers, = AuthApp.authenticator.challenge_response(e)
    challenge = headers.find { |key, _| key.casecmp?("www-authenticate") }&.last
    halt_json(401, "Send a valid API token: Authorization: Bearer lr_...", headers: { "www-authenticate" => challenge }.compact)
  end

  # A write the PWA queued for one user (X-Lazy-Runner-User, see
  # public/js/outbox.js) is refused while someone else is signed in: another
  # tab may send it in the moment between the next person's sign-in and
  # the device dropping the queue (#205).
  def refuse_other_user(r)
    meant = r.env["HTTP_X_LAZY_RUNNER_USER"]
    return if meant.nil? || !UNSAFE.include?(r.request_method) || meant == env["lazy_runner.user_id"].to_s

    halt_json(409, USER_MISMATCH, code: "user_mismatch")
  end

  # Writes made with the session cookie must come from the app's own pages:
  # a same-origin request (Sec-Fetch-Site, or else Origin), with a JSON body.
  # SameSite=Lax alone would let another app on a sibling subdomain post a
  # form here, since the browser counts that as the same site.
  def csrf_refusal(r)
    site = r.env["HTTP_SEC_FETCH_SITE"]
    origin = r.env["HTTP_ORIGIN"]
    same =
      if site then site == "same-origin"
      elsif origin then origin == r.base_url
      else false
      end
    return REFUSED unless same

    has_body = r.env["IODINE_HAS_BODY"] || r.content_length.to_i.positive?
    return NOT_JSON if has_body && !r.media_type.to_s.match?(%r{\Aapplication/json\z}i)

    nil
  end

  # Sign-in, setup and invites count per username, read as Rodauth reads
  # it; a change of password per account; an OIDC start per signed-in user.
  def throttle_for(path)
    case path
    when "#{PREFIX}/login" then [THROTTLE, rodauth.param("username").downcase[0, 100]]
    when "#{PREFIX}/create-account" then [ACCOUNTS, rodauth.param("username").downcase[0, 100]]
    when "#{PREFIX}/change-password" then [PASSWORD_CHANGES, rodauth.session_value.to_s]
    when "#{PREFIX}/oidc"
      [OIDC_STARTS, rodauth.session_value.to_s] if rodauth.logged_in?
    end
  end

  def halt_json(status, message, headers: {}, code: nil)
    response.status = status
    response["content-type"] = "application/json"
    headers.each { |key, value| response[key] = value }
    response.write(JSON.generate(AuthApp.error_body(status, message, code:)))
    request.halt
  end
end
