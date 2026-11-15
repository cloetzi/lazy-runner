require "omniauth_openid_connect"
require_relative "../oidc"

module Auth
  # Signing in with an OpenID Connect provider (lib/oidc.rb), when one is
  # set: the authorization code flow with PKCE, a state and a nonce, the ID
  # token checked against the provider's keys (omniauth_openid_connect).
  # Rodauth's omniauth_base feature runs it; AuthApp includes this module in
  # its Rodauth class and calls it from the omniauth_* settings.
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
  module OidcCallback
    # The OIDC provider didn't answer: its discovery document, keys or token
    # endpoint. Any other failure is an answer that didn't check out.
    UNREACHABLE = [
      OpenIDConnect::Discovery::DiscoveryFailed, Faraday::Error, SocketError,
      SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
    ].freeze

    # A page of the app to go back to: a path, not another site.
    def self.local_path(value)
      value if value.is_a?(String) && value.length <= 500 && value.match?(%r{\A/(?![/\\])[^\\\x00-\x20\x7f]*\z})
    end

    def route_omniauth!
      return unless Oidc.enabled?

      super
      # The callback, once the provider's answer checked out.
      oidc_callback if omniauth_auth
    end

    private

    # The provider's settings, for each request (omniauth_setup).
    def oidc_setup
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
    # pages: link to the signed-in user, join with an invite, or sign in
    # (omniauth_before_request_phase).
    def oidc_remember_intent
      # The home page is where the sign-in page goes anyway.
      next_page = OidcCallback.local_path(param_or_nil("next"))
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
    # error in its phases into this (omniauth_on_failure).
    def oidc_failed
      type = omniauth_error_type.to_s
      error = omniauth_error
      unreachable = %w[failed_to_connect timeout].include?(type) || UNREACHABLE.any? { error.is_a?(it) }
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
        @oidc_identity_id = identity.id
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
        identity = Current.set(user: User.with_pk!(id)) { UserIdentity.create(issuer:, subject:, username: name, last_used_at: now) }
        @oidc_identity_id = identity.id
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
