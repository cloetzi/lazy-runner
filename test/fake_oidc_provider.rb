# frozen_string_literal: true

require "openssl"
require "digest"
require "base64"
require "json/jwt"
require "faraday"

# An OpenID Connect provider for the tests, answering the app's calls to it
# through Faraday's test adapter (Oidc.http_adapter): discovery, keys, the
# token endpoint (checking the client, the code, the redirect URI and the
# PKCE verifier) and userinfo. A test plays the browser: it reads the
# authorize URL the app hands out, "signs in" here with #authorize, and
# takes the code back to the app's callback.
class FakeOidcProvider
  ISSUER = "https://id.example.test"
  CLIENT_ID = "lazy-runner"
  CLIENT_SECRET = "client secret for the tests"

  # How the client authenticates at the token endpoint: :basic or :post.
  attr_accessor :down, :signing_key, :auth
  attr_reader :key, :grants

  def initialize
    @key = OpenSSL::PKey::RSA.new(2048)
    @signing_key = @key
    reset!
  end

  def reset!
    @grants = {}
    @down = false
    @signing_key = @key
    @auth = :basic
  end

  def settings(**overrides)
    Oidc::Settings.new(
      issuer: ISSUER, client_id: CLIENT_ID, client_secret: CLIENT_SECRET, name: "Test ID", auto_signup: false,
      redirect_uri: "http://example.org/api/auth/oidc/callback", auth_method: :basic, signing_alg: "RS256", **overrides
    )
  end

  def adapter = ->(faraday) { faraday.adapter(:test, stubs) }

  # The person signs in at the provider: a code for the app's callback,
  # bound to what the authorize URL asked for. `nonce:` overrides the one
  # the ID token carries.
  def authorize(authorize_url, sub:, claims: {}, nonce: nil)
    query = URI.decode_www_form(URI(authorize_url).query).to_h
    raise "not this client" unless query["client_id"] == CLIENT_ID
    raise "PKCE not S256" unless query["code_challenge_method"] == "S256"

    code = SecureRandom.hex(8)
    @grants[code] = {
      redirect_uri: query["redirect_uri"], challenge: query["code_challenge"],
      claims: { "sub" => sub, **claims }, nonce: nonce || query["nonce"]
    }
    [code, query["state"]]
  end

  def id_token(grant)
    now = Time.now.to_i
    jwt = JSON::JWT.new(iss: ISSUER, sub: grant[:claims]["sub"], aud: CLIENT_ID, iat: now, exp: now + 300, nonce: grant[:nonce])
    jwt.kid = JSON::JWK.new(@key.public_key)[:kid]
    jwt.sign(@signing_key, :RS256).to_s
  end

  private

  def stubs
    @stubs ||= Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("#{ISSUER}/.well-known/openid-configuration") { answer(discovery) }
      stub.get("#{ISSUER}/jwks") { answer(keys: [JSON::JWK.new(@key.public_key)]) }
      stub.post("#{ISSUER}/token") { token(it) }
      stub.get("#{ISSUER}/userinfo") { |env| answer(@userinfo.fetch(env.request_headers["Authorization"].to_s.delete_prefix("Bearer "))) }
    end
  end

  def discovery
    {
      issuer: ISSUER, authorization_endpoint: "#{ISSUER}/authorize", token_endpoint: "#{ISSUER}/token",
      userinfo_endpoint: "#{ISSUER}/userinfo", jwks_uri: "#{ISSUER}/jwks", response_types_supported: ["code"],
      subject_types_supported: ["public"], id_token_signing_alg_values_supported: ["RS256"]
    }
  end

  def token(env)
    form = URI.decode_www_form(env.body).to_h
    basic = Base64.strict_encode64("#{CLIENT_ID}:#{URI.encode_www_form_component(CLIENT_SECRET)}")
    client =
      if @auth == :basic then env.request_headers["Authorization"] == "Basic #{basic}"
      else form["client_id"] == CLIENT_ID && form["client_secret"] == CLIENT_SECRET && !env.request_headers["Authorization"]
      end
    return answer({ error: "invalid_client" }, 401) unless client

    grant = @grants.delete(form["code"])
    verifier = form["code_verifier"].to_s
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    unless grant && form["grant_type"] == "authorization_code" && form["redirect_uri"] == grant[:redirect_uri] &&
           challenge == grant[:challenge]
      return answer({ error: "invalid_grant" }, 400)
    end

    access = SecureRandom.hex(16)
    (@userinfo ||= {})[access] = grant[:claims]
    answer(access_token: access, token_type: "Bearer", expires_in: 300, id_token: id_token(grant))
  end

  def answer(body, status = 200)
    raise Faraday::ConnectionFailed, "the provider is down" if @down

    [status, { "Content-Type" => "application/json" }, JSON.generate(body)]
  end
end
