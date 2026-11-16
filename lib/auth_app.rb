# frozen_string_literal: true

require "roda"
require_relative "secrets"
require_relative "setup_code"
require_relative "hashing"
require_relative "auth/session_cookie"
require_relative "auth/gate"
require_relative "auth/oidc_callback"

# Accounts and sign-in: Rodauth, on the app's own Sequel connection.
#
# Two middlewares inside Rage's stack (config/initializers/sign_in.rb), after
# Rage::FiberWrapper, so they run in the request's fiber and take their turn
# on the one connection like any request: the session cookie
# (lib/auth/session_cookie.rb), then this app, which answers Rodauth's JSON
# routes under /api/auth (sign in, sign out, set up the owner, change the
# password, and signing in with an OpenID Connect provider when lib/oidc.rb
# has one) and runs the gate in front of the API (lib/auth/gate.rb). What it
# lets through goes on to Rage with the user's id in
# env["lazy_runner.user_id"]. /mcp checks its own tokens
# (TrainerMcp::TokenVerifier).
#
# By concern, in lib/auth/:
# - access.rb: who may ask for what, a table of /api routes.
# - gate.rb: acts on it: the session or an API token, a 401 for anyone else.
# - csrf.rb: writes with the session cookie come from the app's own pages.
# - token.rb: reading a personal API token.
# - throttles.rb: how often a password may be tried.
# - oidc_callback.rb: signing in with an OpenID Connect provider.
#
# Rodauth keeps the account (users) apart from the ways of proving who you
# are (a password, an identity at the OIDC provider in user_identities), so
# a user can have either or both.
class AuthApp < Roda
  include Auth::Gate

  # Rodauth's own routes.
  PREFIX = Auth::Access::SIGN_IN
  INVITE_GONE = "This invite link has expired, been used or been revoked; ask for a new one"
  WRONG_SETUP_CODE = "Wrong setup code. It is the newest one in the server's log; a restart prints a new one"
  # Argon2id at the cost real passwords are hashed with: verifying against
  # it takes as long as verifying a real one.
  HASH_COST = (Rage.env.test? ? { t_cost: 1, m_cost: 5, p_cost: 1 } : { t_cost: 2, m_cost: 16, p_cost: 1 }).freeze
  DUMMY_HASH = Argon2::Password.create("never a password", **HASH_COST)

  # The app's error shape, { error: { code, message, fields } }, by status.
  CODES = {
    400 => "bad_request", 401 => "unauthorized", 403 => "forbidden", 404 => "not_found", 405 => "bad_request",
    406 => "bad_request", 409 => "conflict", 422 => "invalid", 429 => "too_many_requests", 502 => "unavailable"
  }.freeze

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

  class << self
    attr_reader :hash_seconds
  end

  # Measured warm: the first verify in a process also maps Argon2's memory.
  dummy_verify("never a password either")
  @hash_seconds = nil
  dummy_verify("never a password either")

  # True at most once a minute: time to remove devices past their deadline.
  def self.sweep_due?(now = Process.clock_gettime(Process::CLOCK_MONOTONIC))
    return false if @swept_at && now - @swept_at < 60

    @swept_at = now
  end

  # Where a password's hash made ahead waits for Rodauth to ask for it.
  PREHASHED = :lazy_runner_password_hash

  # Runs the block with the password's hash made already, so the block can
  # hold a transaction (and with it the one connection) without hashing
  # inside it: Argon2 takes about 100 ms, and every other request would
  # wait for it (User#set_password!).
  def self.with_password_hashed(password)
    hash = rodauth.internal_request_eval { password_hash(password) }
    Fiber[PREHASHED] = [password, hash]
    yield
  ensure
    Fiber[PREHASHED] = nil
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
    already_an_account_with_this_login_message "That username is taken. Try another."
    # The reason alone, as a sentence, not "invalid login, " before it.
    login_does_not_meet_requirements_message do
      message = login_requirement_message.to_s
      message.empty? ? "That username can't be used" : message[0].upcase + message[1..]
    end
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
    session_inactivity_deadline 90 * Auth::SessionCookie::DAY
    session_lifetime_deadline 365 * Auth::SessionCookie::DAY

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
        throw_error_status(404, "invite", INVITE_GONE) unless Invite.usable?(invite, now: @invited_at)
        @invite = invite
      else
        unless first
          set_response_error_status(404)
          throw_error("setup_code", "This install already has an owner; sign in instead")
        end
        throw_error_status(403, "setup_code", WRONG_SETUP_CODE) unless SetupCode.match?(param("setup_code"))
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
      if Auth::Throttles::DUMMY_HASHES.hit("hash")
        Hashing.run { sleep AuthApp.hash_seconds }
      else
        AuthApp.dummy_verify(param(password_param))
      end
    end

    # The identity at the OIDC provider it signed in with, if it did, so
    # unlinking that identity signs the device out (UserIdentity#unlink!).
    active_sessions_insert_hash do
      super().merge(device: request.user_agent.to_s[0, 200].presence, user_identity_id: @oidc_identity_id)
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

    # The flow is in lib/auth/oidc_callback.rb. OmniAuth runs under /api/auth
    # (its SCRIPT_NAME), so /api/auth/oidc.
    omniauth_prefix ""
    # origin_param: false, so OmniAuth doesn't keep the Referer in the
    # cookie, which nothing reads and a long URL would overfill.
    omniauth_provider Oidc::Strategy, name: :oidc, discovery: true, pkce: true, response_type: "code",
                                      scope: %i[openid profile email], origin_param: false
    omniauth_setup { oidc_setup }
    omniauth_before_request_phase { oidc_remember_intent }
    omniauth_on_failure { oidc_failed }

    auth_class_eval do
      include Auth::OidcCallback

      # Argon2 off the worker's thread (lib/hashing.rb), or the hash made
      # already for this password (AuthApp.with_password_hashed).
      private def password_hash(password)
        hashed = Fiber[AuthApp::PREHASHED]
        return hashed.last if hashed && hashed.first == password

        Hashing.run { super(password) }
      end

      # A password set from code (a reset) isn't compared with the one it
      # replaces: that is one more hash, and a reset may give the same one.
      private def new_password_matches_current_password?(password) = !internal_request? && super
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
    end
  end

  route do |r|
    access = Auth::Access.for(r.path_info)
    # Outside /api (the PWA's files, /mcp): on to Rage.
    return nil unless access
    # A request with an API token, answered or let through.
    return nil if gate_before_sign_in(r, access)

    r.on("api", "auth") do
      # Whether an invite link still works, asked before the join form is
      # shown: 204, else a 404 that reads the same whether the token is
      # unknown, used, revoked or expired, as joining with it would. A token
      # is too long to guess (256 bits) and checking one hashes no
      # password, so this isn't counted (a total shared by everyone could
      # be used up to keep invitees out).
      r.post("invite-check") do
        halt_json(404, INVITE_GONE) unless Invite.usable?(rodauth.param_or_nil("invite"))
        response.status = 204
        request.halt
      end
      r.rodauth
    end

    gate_after_sign_in(r, access)
    # Anything else goes on to Rage.
    nil
  end
end
