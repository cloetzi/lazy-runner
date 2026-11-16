# frozen_string_literal: true

require "test_helper"
require "fake_oidc_provider"

describe "signing in with an OpenID Connect provider" do
  include RequestHelpers
  include UserHelpers

  PROVIDER = FakeOidcProvider.new
  Oidc.http_adapter = PROVIDER.adapter

  before do
    PROVIDER.reset!
    @saved_settings = Oidc.settings
    Oidc.settings = PROVIDER.settings
  end

  after { Oidc.settings = @saved_settings }

  # The PWA starts the flow: the provider's URL to send the browser to.
  def start(body = {})
    post_json "/api/auth/oidc", body
    _(last_response.status).must_equal 200, last_response.body
    json.fetch("authorize_url")
  end

  # The browser comes back from the provider, which sent it here from
  # another site. Returns where the app sends it next.
  def come_back(params)
    @fetch_site = "cross-site"
    get "/api/auth/oidc/callback", params
    @fetch_site = "same-origin"
    _(last_response.status).must_equal 302, last_response.body
    last_response.location
  end

  def sign_in_at_provider(sub:, claims: {}, **)
    code, state = PROVIDER.authorize(start(**), sub:, claims:)
    come_back(code:, state:)
  end

  def start_with(**body) = start(body)

  def signed_in_as
    get "/api/me"
    json.dig("user", "username")
  end

  def link(user, sub, username: nil)
    Current.set(user:) { UserIdentity.create(issuer: FakeOidcProvider::ISSUER, subject: sub, username:) }
  end

  def oidc_only_user(username)
    create_user(username, bare: true).tap { DB[:account_password_hashes].where(id: it.id).delete }
  end

  def signing_out
    sign_out!
    yield
  end

  describe "the sign-in page" do
    it "names the provider to offer, signed out" do
      sign_out!
      get "/api/me"
      _(json["sign_in_with"]).must_equal "Test ID"
    end

    it "offers nothing when the install has no provider" do
      Oidc.settings = nil
      sign_out!
      get "/api/me"
      _(json["sign_in_with"]).must_be_nil
      post_json "/api/auth/oidc"
      _(last_response.status).must_equal 404
    end
  end

  describe "the start" do
    before { sign_out! }

    it "hands out the provider's URL with a state, a nonce and a PKCE challenge" do
      url = URI(start)
      query = URI.decode_www_form(url.query).to_h

      _("#{url.scheme}://#{url.host}#{url.path}").must_equal "#{FakeOidcProvider::ISSUER}/authorize"
      _(query.values_at("client_id", "response_type", "redirect_uri")).must_equal [
        FakeOidcProvider::CLIENT_ID, "code", "http://example.org/api/auth/oidc/callback"
      ]
      _(query["scope"].split).must_equal %w[openid profile email]
      _(query.keys).must_include "state"
      _(query.keys).must_include "nonce"
      _(query["code_challenge_method"]).must_equal "S256"
    end

    it "takes the redirect URI it is given" do
      Oidc.settings = PROVIDER.settings(redirect_uri: "https://runner.example.test/api/auth/oidc/callback")
      _(URI.decode_www_form(URI(start).query).to_h["redirect_uri"]).must_equal "https://runner.example.test/api/auth/oidc/callback"
    end

    # A client chooses its request's Host and forwarded headers, so they
    # can't choose where the provider sends the code (#209).
    it "keeps to its redirect URI whatever host the request names" do
      Oidc.settings = PROVIDER.settings(redirect_uri: "https://runner.example.test/api/auth/oidc/callback")
      header "Host", "attacker.example"
      header "X-Forwarded-Host", "attacker.example"
      header "Forwarded", "host=attacker.example;proto=https"
      _(URI.decode_www_form(URI(start).query).to_h["redirect_uri"]).must_equal "https://runner.example.test/api/auth/oidc/callback"
    end

    it "refuses a start from another site, as any write" do
      @fetch_site = "cross-site"
      post_json "/api/auth/oidc"
      _(last_response.status).must_equal 403
    end

    it "says when the provider can't be reached" do
      PROVIDER.down = true
      post_json "/api/auth/oidc"

      _(last_response.status).must_equal 502
      _(json["error"]["code"]).must_equal "unavailable"
      _(json["error"]["message"]).must_match(/Can't reach Test ID/)
    end

    it "doesn't ask a provider that just failed again at once" do
      PROVIDER.down = true
      calls = 0
      adapter = Oidc.http_adapter
      Oidc.http_adapter = lambda { |faraday|
        calls += 1
        adapter.call(faraday)
      }
      3.times do
        post_json "/api/auth/oidc"
        _(last_response.status).must_equal 502
      end
      _(calls).must_equal 1
    ensure
      Oidc.http_adapter = adapter
    end

    it "asks the provider for its discovery document once, not on every sign-in" do
      calls = 0
      adapter = Oidc.http_adapter
      Oidc.http_adapter = lambda { |faraday|
        calls += 1
        adapter.call(faraday)
      }
      2.times { start }
      _(calls).must_equal 1
    ensure
      Oidc.http_adapter = adapter
    end

    # Counted per signed-in user linking an identity; signed out, a count
    # everyone shares would let a script keep the provider's users out.
    it "limits how often a signed-in user starts linking, and nobody signed out" do
      50.times { start }

      sign_in(user)
      10.times { start }
      post_json "/api/auth/oidc"
      _(last_response.status).must_equal 429
    end

    it "says when the provider's settings don't add up" do
      Oidc.settings = PROVIDER.settings(issuer: "https://id.example.test/other")
      post_json "/api/auth/oidc"

      _(last_response.status).must_equal 502
      _(json["error"]["message"]).must_match(/Couldn't start signing in with Test ID/)
    end
  end

  describe "signing in" do
    before { sign_out! }

    it "signs in the user the identity is linked to, and goes on to the page asked for" do
      link(user, "sub-1")
      location = sign_in_at_provider(sub: "sub-1", claims: { "preferred_username" => "Run Ner" }, next: "/calendar.html")

      _(location).must_equal "/signin.html?next=%2Fcalendar.html"
      _(signed_in_as).must_equal "runner"
      _(SignedInDevice.of(user).count).must_equal 1
      identity = UserIdentity.first!(subject: "sub-1")
      _(identity.username).must_equal "Run Ner"
      _(identity.last_used_at).wont_be_nil
    end

    it "keeps only a page of the app to go on to" do
      link(user, "sub-1")
      _(sign_in_at_provider(sub: "sub-1", next: "//elsewhere.example/")).must_equal "/signin.html"
      sign_out!
      _(sign_in_at_provider(sub: "sub-1", next: "/\t/elsewhere.example/")).must_equal "/signin.html"
    end

    it "keeps the name it had when the provider leaves it out" do
      link(user, "sub-1", username: "Runner")
      sign_in_at_provider(sub: "sub-1")
      _(UserIdentity.first!(subject: "sub-1").username).must_equal "Runner"
    end

    it "sends the client secret in the body with client_secret_post" do
      Oidc.settings = PROVIDER.settings(auth_method: :client_secret_post)
      PROVIDER.auth = :post
      link(user, "sub-1")
      _(sign_in_at_provider(sub: "sub-1")).must_equal "/signin.html"
      _(signed_in_as).must_equal "runner"
    end

    it "never signs in a user by a username or an email the provider gives" do
      location = sign_in_at_provider(sub: "someone", claims: { "preferred_username" => "runner", "email" => "runner" })

      _(location).must_equal "/signin.html?oidc_error=no_account"
      _(signed_in_as).must_be_nil
      _(User.count).must_equal 1
      _(UserIdentity.everyone.count).must_equal 0
    end

    it "doesn't take an identity from another issuer" do
      Current.set(user:) { UserIdentity.create(issuer: "https://old.example.test", subject: "sub-1") }
      _(sign_in_at_provider(sub: "sub-1")).must_equal "/signin.html?oidc_error=no_account"
    end

    it "refuses a callback whose state isn't this browser's" do
      link(user, "sub-1")
      code, = PROVIDER.authorize(start, sub: "sub-1")
      _(come_back(code:, state: "not-the-state")).must_equal "/signin.html?oidc_error=failed"
      _(signed_in_as).must_be_nil
    end

    it "refuses a callback no sign-in started" do
      link(user, "sub-1")
      _(come_back(code: "abc", state: "abc")).must_equal "/signin.html?oidc_error=failed"
      _(signed_in_as).must_be_nil
    end

    it "refuses an ID token not signed by the provider" do
      link(user, "sub-1")
      PROVIDER.signing_key = OpenSSL::PKey::RSA.new(2048)
      _(sign_in_at_provider(sub: "sub-1")).must_equal "/signin.html?oidc_error=failed"
      _(signed_in_as).must_be_nil
    end

    it "refuses an ID token for another sign-in (its nonce)" do
      link(user, "sub-1")
      code, state = PROVIDER.authorize(start, sub: "sub-1", nonce: "another")
      _(come_back(code:, state:)).must_equal "/signin.html?oidc_error=failed"
      _(signed_in_as).must_be_nil
    end

    it "takes the nonce and the PKCE verifier from the session, never the callback's query" do
      link(user, "sub-1")
      code, state = PROVIDER.authorize(start, sub: "sub-1", nonce: "forged")
      _(come_back(code:, state:, nonce: "forged")).must_equal "/signin.html?oidc_error=failed"
      _(signed_in_as).must_be_nil
      verifier = SecureRandom.hex(32)
      url = start.sub(/code_challenge=[^&]+/, "code_challenge=#{Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)}")
      code, state = PROVIDER.authorize(url, sub: "sub-1")
      _(come_back(code:, state:, code_verifier: verifier)).must_equal "/signin.html?oidc_error=failed"
      _(signed_in_as).must_be_nil
    end

    it "keeps the page asked for when it didn't work" do
      state = URI.decode_www_form(URI(start(next: "/calendar.html")).query).to_h["state"]
      _(come_back(error: "access_denied", state:)).must_equal "/signin.html?oidc_error=cancelled&next=%2Fcalendar.html"
    end

    it "refuses a code the provider won't exchange" do
      link(user, "sub-1")
      _, state = PROVIDER.authorize(start, sub: "sub-1")
      _(come_back(code: "made-up", state:)).must_equal "/signin.html?oidc_error=failed"
    end

    it "says the person cancelled at the provider" do
      state = URI.decode_www_form(URI(start).query).to_h["state"]
      _(come_back(error: "access_denied", state:)).must_equal "/signin.html?oidc_error=cancelled"
    end

    it "says when the provider can't be reached on the way back" do
      link(user, "sub-1")
      code, state = PROVIDER.authorize(start, sub: "sub-1")
      PROVIDER.down = true
      _(come_back(code:, state:)).must_equal "/signin.html?oidc_error=unavailable"
    end

    it "makes an account for anyone the provider admits with OIDC_AUTO_SIGNUP" do
      Oidc.settings = PROVIDER.settings(auto_signup: true)
      location = sign_in_at_provider(sub: "new", claims: { "preferred_username" => "runner", "email" => "r@example.test" })

      _(location).must_equal "/signin.html"
      _(signed_in_as).must_equal "runner-2"
      newcomer = User.first!(username: "runner-2")
      _(newcomer.owner).must_equal false
      _(newcomer.welcomed_at).must_be_nil
      _(newcomer.password?).must_equal false
      identity = UserIdentity.everyone.first!(subject: "new")
      _(identity.user_id).must_equal newcomer.id
      # The device is signed in with it, for unlinking to sign it out.
      _(SignedInDevice.of(newcomer).select_map(:user_identity_id)).must_equal [identity.id]
    end

    it "makes no account before the install has its owner, auto sign-up or not" do
      Oidc.settings = PROVIDER.settings(auto_signup: true)
      User.dataset.delete
      _(sign_in_at_provider(sub: "new")).must_equal "/signin.html?oidc_error=no_account"
      _(User.count).must_equal 0
    end
  end

  describe "joining with an invite" do
    before do
      _, @token = Invite.issue!
      sign_out!
    end

    it "makes the account, named as the provider names them, and uses the invite up" do
      location = sign_in_at_provider(sub: "sub-9", claims: { "preferred_username" => "Sam Smith" }, invite: @token)

      _(location).must_equal "/signin.html"
      _(signed_in_as).must_equal "SamSmith"
      _(Invite.count).must_equal 0
      sam = User.first!(username: "SamSmith")
      _(sam.owner).must_equal false
      _(UserIdentity.everyone.first!(subject: "sub-9").user_id).must_equal sam.id
    end

    it "refuses an invite that was used or revoked" do
      Invite.dataset.delete
      _(sign_in_at_provider(sub: "sub-9", invite: @token)).must_equal "/signin.html?oidc_error=invite_gone"
      _(User.count).must_equal 1
    end

    it "signs in a linked identity as its user, leaving the invite" do
      link(user, "sub-1")
      _(sign_in_at_provider(sub: "sub-1", invite: @token)).must_equal "/signin.html"
      _(signed_in_as).must_equal "runner"
      _(Invite.count).must_equal 1
    end
  end

  describe "linking, signed in" do
    it "links the identity to the signed-in user" do
      location = sign_in_at_provider(sub: "sub-1", claims: { "email" => "runner@example.test" })

      _(location).must_equal "/settings.html?oidc=linked#account"
      get "/api/account/identities"
      _(json["provider"]).must_equal({ "name" => "Test ID" })
      _(json["password"]).must_equal true
      _(json["identities"].map { it["username"] }).must_equal ["runner@example.test"]
      _(signed_in_as).must_equal "runner"
      # Still the one device: linking isn't another sign-in.
      _(SignedInDevice.of(user).count).must_equal 1
    end

    it "refuses an identity linked to someone else" do
      link(create_user("other", bare: true), "sub-1")
      _(sign_in_at_provider(sub: "sub-1")).must_equal "/settings.html?oidc=linked_elsewhere#account"
      _(UserIdentity.count).must_equal 0
    end

    it "keeps one identity per user" do
      link(user, "sub-1")
      _(sign_in_at_provider(sub: "sub-2")).must_equal "/settings.html?oidc=already_linked#account"
      _(UserIdentity.select_map(:subject)).must_equal ["sub-1"]
    end

    it "links nothing while the password is a temporary one" do
      DB[:users].where(id: user.id).update(password_change_required: true)
      post_json "/api/auth/oidc"
      _(last_response.status).must_equal 401
      _(json["error"]["message"]).must_match(/Choose a new password first/)
    end

    it "links nothing when the device was signed out in between" do
      code, state = PROVIDER.authorize(start, sub: "sub-1")
      DB[:account_active_session_keys].where(account_id: user.id).delete
      # Signed out, its session is gone, and the state with it.
      _(come_back(code:, state:)).must_equal "/signin.html?oidc_error=failed"
      _(UserIdentity.count).must_equal 0
    end
  end

  describe "the linked identities" do
    it "unlinks one" do
      identity = link(user, "sub-1")
      delete "/api/account/identities/#{identity.id}"

      _(last_response.status).must_equal 204
      _(UserIdentity.count).must_equal 0
    end

    it "signs out the other devices that signed in with it, and keeps this one" do
      identity = link(user, "sub-1")
      devices = -> { SignedInDevice.of(user).order(:id).select_map(:user_identity_id) }
      2.times do
        sign_out!
        sign_in_at_provider(sub: "sub-1")
      end
      sign_out!
      sign_in(user)
      _(devices.call).must_equal [identity.id, identity.id, nil]

      sign_out!
      sign_in_at_provider(sub: "sub-1")
      delete "/api/account/identities/#{identity.id}"

      _(last_response.status).must_equal 204
      # The one asking stays signed in, and with its identity gone it names none.
      _(devices.call).must_equal [nil, nil]
      _(signed_in_as).must_equal user.username
    end

    it "revokes the API tokens made on a device signed in with it" do
      identity = link(user, "sub-1")
      post_json "/api/account/tokens", name: "made with a password"
      sign_out!
      sign_in_at_provider(sub: "sub-1")
      post_json "/api/account/tokens", name: "made with the identity"
      _(ApiToken.order(:id).select_map(:user_identity_id)).must_equal [nil, identity.id]

      delete "/api/account/identities/#{identity.id}"

      _(last_response.status).must_equal 204
      _(ApiToken.select_map(:name)).must_equal ["made with a password"]
    end

    it "won't unlink the only way in" do
      sam = oidc_only_user("sam")
      identity = link(sam, "sub-9")
      sign_out!
      sign_in_at_provider(sub: "sub-9")
      delete "/api/account/identities/#{identity.id}"

      _(last_response.status).must_equal 409
      _(json["error"]["message"]).must_match(/Set a password first/)
      get "/api/account/identities"
      _(json["password"]).must_equal false
    end

    it "lets someone without a password set one, without a current one" do
      oidc_only_user("sam").then { link(it, "sub-9") }
      sign_out!
      sign_in_at_provider(sub: "sub-9")
      post_json "/api/auth/change-password", new_password: "a brand new password"

      _(last_response.status).must_equal 200, last_response.body
      sign_out!
      post_json "/api/auth/login", username: "sam", password: "a brand new password"
      _(last_response.status).must_equal 200
    end

    it "still asks for the current password of someone with one" do
      post_json "/api/auth/change-password", new_password: "a brand new password"
      _(last_response.status).must_equal 401
    end

    it "hides another user's" do
      identity = link(create_user("other", bare: true), "sub-1")
      delete "/api/account/identities/#{identity.id}"
      _(last_response.status).must_equal 404
    end

    it "takes a signed-in browser, not an API token" do
      _, secret = ApiToken.issue!(user, "script")
      sign_out!
      header "Authorization", "Bearer #{secret}"
      get "/api/account/identities"
      _(last_response.status).must_equal 403
    end

    it "unlinks them all on a change of password that signs the other devices out, or a reset" do
      link(user, "sub-1")
      post_json "/api/auth/change-password", password: RequestHelpers::TEST_PASSWORD, new_password: "a brand new password",
                                             sign_out_others: false
      _(UserIdentity.count).must_equal 1
      post_json "/api/auth/change-password", password: "a brand new password", new_password: "another new password"
      _(last_response.status).must_equal 200
      _(UserIdentity.count).must_equal 0

      other = create_user("other", bare: true)
      link(other, "sub-2")
      Current.set(user:) { other.reset_password! }
      _(UserIdentity.everyone.where(user_id: other.id).count).must_equal 0
    end

    it "keeps them when setting a first password: there was none to know" do
      oidc_only_user("sam").then { link(it, "sub-9") }
      sign_out!
      sign_in_at_provider(sub: "sub-9")
      post_json "/api/auth/change-password", new_password: "a brand new password"
      _(UserIdentity.everyone.where(subject: "sub-9").count).must_equal 1
    end

    it "lists and unlinks one at a provider the install no longer uses" do
      old = Current.set(user:) { UserIdentity.create(issuer: "https://old.example.test", subject: "sub-1") }
      get "/api/account/identities"
      _(json["identities"].map { it["current"] }).must_equal [false]
      delete "/api/account/identities/#{old.id}"
      _(last_response.status).must_equal 204
    end

    it "removes them with their user" do
      other = create_user("other", bare: true)
      link(other, "sub-1")
      Current.set(user:) { other.remove! }
      _(UserIdentity.everyone.count).must_equal 0
    end
  end

  # A failed password sign-in costs one Argon2 verification whoever it names,
  # so its time doesn't tell an account that signs in only here (#208).
  describe "a wrong password for an account without one" do
    def verifications
      count = 0
      counter = Module.new do
        define_method(:verify_password) do |*args, **opts|
          count += 1
          super(*args, **opts)
        end
      end
      Argon2::Password.singleton_class.prepend(counter)
      yield
      count
    ensure
      counter.send(:remove_method, :verify_password)
    end

    def failed_sign_in(username)
      verifications do
        post_json "/api/auth/login", username:, password: "not the password"
        _(last_response.status).must_equal 401
      end
    end

    it "costs the hash an unknown username and a wrong password cost" do
      oidc_only_user("sam")
      sign_out!
      _(failed_sign_in("nobody")).must_equal 1
      _(failed_sign_in(user.username)).must_equal 1
      _(failed_sign_in("sam")).must_equal 1
    end

    it "costs the same hash for a locked account" do
      DB[:account_lockouts].insert(id: user.id, key: "k", deadline: Time.now.utc + 600)
      sign_out!
      _(failed_sign_in(user.username)).must_equal 1
    end
  end
end

describe Oidc do
  ENV_KEYS = %w[OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_NAME OIDC_AUTO_SIGNUP OIDC_REDIRECT_URI OIDC_CLIENT_AUTH_METHOD
                OIDC_SIGNING_ALG].freeze

  def settings(env) = Oidc.from_env(ENV_KEYS.to_h { [it, nil] }.merge(env))

  it "is off without an issuer" do
    _(settings({})).must_be_nil
  end

  CALLBACK = "https://runner.example.test/api/auth/oidc/callback"

  it "reads the provider, with defaults" do
    found = settings("OIDC_ISSUER" => "https://id.example.test", "OIDC_CLIENT_ID" => "app", "OIDC_CLIENT_SECRET" => "s",
                     "OIDC_REDIRECT_URI" => CALLBACK)
    _(found.to_h).must_equal(
      issuer: "https://id.example.test", client_id: "app", client_secret: "s", name: "single sign-on",
      auto_signup: false, redirect_uri: CALLBACK, auth_method: :basic, signing_alg: "RS256"
    )
    found = settings(
      "OIDC_ISSUER" => "https://id.example.test", "OIDC_CLIENT_ID" => "app", "OIDC_CLIENT_SECRET" => "s", "OIDC_REDIRECT_URI" => CALLBACK,
      "OIDC_AUTO_SIGNUP" => "true", "OIDC_CLIENT_AUTH_METHOD" => "client_secret_post", "OIDC_NAME" => "Home ID"
    )
    _([found.auto_signup, found.auth_method, found.name]).must_equal [true, :client_secret_post, "Home ID"]
  end

  it "stops the boot on settings that don't add up" do
    base = { "OIDC_ISSUER" => "https://id.example.test", "OIDC_CLIENT_ID" => "app", "OIDC_CLIENT_SECRET" => "s", "OIDC_REDIRECT_URI" => CALLBACK }
    _ { settings(base.merge("OIDC_CLIENT_SECRET" => "")) }.must_raise Oidc::Error
    _ { settings(base.except("OIDC_REDIRECT_URI")) }.must_raise Oidc::Error
    _ { settings(base.merge("OIDC_REDIRECT_URI" => "https://runner.example.test/elsewhere")) }.must_raise Oidc::Error
    _ { settings(base.merge("OIDC_REDIRECT_URI" => "runner.example.test/api/auth/oidc/callback")) }.must_raise Oidc::Error
    _ { settings(base.merge("OIDC_ISSUER" => "id.example.test")) }.must_raise Oidc::Error
    _ { settings(base.merge("OIDC_ISSUER" => "http://id.example.test")) }.must_raise Oidc::Error
    _ { settings(base.merge("OIDC_SIGNING_ALG" => "HS256")) }.must_raise Oidc::Error
    _ { settings(base.merge("OIDC_CLIENT_AUTH_METHOD" => "none")) }.must_raise Oidc::Error
  end

  it "makes a username from the provider's claims" do
    free = ->(_) { false }
    _(Oidc.username({ "preferred_username" => "sam.smith" }, taken: free)).must_equal "sam.smith"
    _(Oidc.username({ "preferred_username" => "é", "email" => "sam+run@example.test" }, taken: free)).must_equal "samrun"
    _(Oidc.username({ "name" => "Sam Smith" }, taken: free)).must_equal "SamSmith"
    _(Oidc.username({}, taken: free)).must_equal "user"
    _(Oidc.username({ "preferred_username" => "x" * 80 }, taken: free).length).must_equal 36
    _(Oidc.username({ "preferred_username" => "sam" }, taken: ->(name) { %w[sam sam-2].include?(name) })).must_equal "sam-3"
    _(Oidc.username({ "preferred_username" => "sam" }, taken: ->(_) { true })).must_match(/\Asam-[0-9a-f]{8}\z/)
  end
end
