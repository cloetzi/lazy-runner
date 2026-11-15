require "securerandom"
require "uri"
require "omniauth_openid_connect"

# Signing in with an OpenID Connect provider, next to passwords (#185):
# set OIDC_ISSUER, OIDC_CLIENT_ID and OIDC_CLIENT_SECRET, and the sign-in
# page offers "Sign in with <OIDC_NAME>". Unset, the routes don't exist.
# How the flow runs is in lib/auth/oidc_callback.rb; the provider's own settings stay
# out of the repo.
#
# - OIDC_ISSUER: the provider's issuer URL (https); its endpoints and keys
#   come from its discovery document.
# - OIDC_CLIENT_ID, OIDC_CLIENT_SECRET: the app's client at the provider, a
#   confidential one with the authorization code flow (PKCE is always on).
#   Register `<the app's URL>/api/auth/oidc/callback` as its redirect URI,
#   and set the same in OIDC_REDIRECT_URI.
# - OIDC_NAME: what the button calls the provider. "single sign-on" if unset.
# - OIDC_AUTO_SIGNUP=true: anyone the provider lets through gets an account
#   on first sign-in, so the provider's access rules decide who joins.
#   Otherwise only users who linked the identity in Settings, or joined with
#   an invite, get in.
# - OIDC_REDIRECT_URI: the callback URL as registered with the provider,
#   `https://<the app's host>/api/auth/oidc/callback`. Required: worked out
#   from the request instead, a client could choose it with Host or
#   X-Forwarded-Host, and so where the provider sends a code (#209).
# - OIDC_CLIENT_AUTH_METHOD: client_secret_basic (the default) or
#   client_secret_post, as the client is registered.
# - OIDC_SIGNING_ALG: the ID token's signature algorithm, RS256 by default;
#   a token signed any other way is refused.
module Oidc
  class Error < StandardError; end

  # rack-oauth2's methods: :basic sends the secret in the Authorization
  # header; any method it doesn't name sends it in the body.
  AUTH_METHODS = { "client_secret_basic" => :basic, "client_secret_post" => :client_secret_post }.freeze
  CALLBACK_PATH = "/api/auth/oidc/callback".freeze
  ALGORITHMS = %w[RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512 EdDSA].freeze

  Settings = Data.define(:issuer, :client_id, :client_secret, :name, :auto_signup, :redirect_uri, :auth_method, :signing_alg)

  # The install's settings, else nil: OIDC is off.
  def self.settings
    return @settings if defined?(@settings)

    @settings = from_env
  end

  # Tests switch it on and off.
  class << self
    attr_writer :settings
  end

  def self.enabled? = !settings.nil?

  # Timeouts for calls to the provider, which a sign-in waits on. Tests put
  # a fake provider in place with http_adapter.
  class << self
    attr_accessor :http_adapter
  end

  def self.configure_http!
    OpenIDConnect.http_config do |faraday|
      faraday.options.open_timeout = 5
      faraday.options.timeout = 10
      Oidc.http_adapter&.call(faraday)
    end
    SWD.cache = cache
  end

  # The provider's discovery document, with its keys once fetched, kept for
  # a quarter of an hour: a sign-in needn't fetch them twice, and a key the
  # provider rotates in is picked up soon after.
  # A failed fetch is remembered for ten seconds, so while the provider is
  # down every sign-in that starts doesn't wait on it again.
  class Cache
    SECONDS = 900
    FAILED_SECONDS = 10

    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @clock = clock
      @entries = {}
      @failures = {}
    end

    # The interface the swd gem's discovery calls.
    def fetch(key, _options = {})
      value, at = @entries[key]
      return value if at && @clock.call - at < SECONDS

      error, failed_at = @failures[key]
      raise error if failed_at && @clock.call - failed_at < FAILED_SECONDS

      yield.tap { @entries[key] = [it, @clock.call] }.tap { @failures.delete(key) }
    rescue StandardError => e
      @failures[key] = [e, @clock.call] unless e.equal?(error)
      raise
    end

    def clear
      @entries.clear
      @failures.clear
    end
  end

  def self.cache = @cache ||= Cache.new

  # omniauth_openid_connect's strategy, but the nonce, the PKCE verifier
  # and the redirect URI it checks the answer against are always the ones
  # this browser's session (and the settings) hold: the stock strategy
  # takes them from the callback's parameters when they are there, which
  # come through the browser and so from anyone.
  class Strategy < OmniAuth::Strategies::OpenIDConnect
    UNTRUSTED = %w[nonce code_verifier redirect_uri].freeze

    def params = super.except(*UNTRUSTED)
  end

  def self.from_env(env = ENV)
    issuer = env["OIDC_ISSUER"].presence or return
    fetch = ->(key) { env[key].presence or raise Error, "#{key} must be set with OIDC_ISSUER" }
    # Discovery is over HTTPS only (the openid_connect gem's), as it should be.
    raise Error, "OIDC_ISSUER must be an https URL" unless url?(issuer, https: true)

    redirect_uri = fetch.("OIDC_REDIRECT_URI")
    unless url?(redirect_uri) && URI(redirect_uri).path == CALLBACK_PATH && URI(redirect_uri).query.nil?
      raise Error, "OIDC_REDIRECT_URI must be the app's http(s) URL ending in #{CALLBACK_PATH}"
    end

    method = env.fetch("OIDC_CLIENT_AUTH_METHOD", "").presence || "client_secret_basic"
    auth_method = AUTH_METHODS.fetch(method) { raise Error, "OIDC_CLIENT_AUTH_METHOD must be one of #{AUTH_METHODS.keys.join(", ")}" }
    alg = env["OIDC_SIGNING_ALG"].presence || "RS256"
    raise Error, "OIDC_SIGNING_ALG must be one of #{ALGORITHMS.join(", ")}" unless ALGORITHMS.include?(alg)

    Settings.new(
      issuer:, client_id: fetch.("OIDC_CLIENT_ID"), client_secret: fetch.("OIDC_CLIENT_SECRET"),
      name: env["OIDC_NAME"].presence || "single sign-on",
      auto_signup: %w[1 true yes on].include?(env["OIDC_AUTO_SIGNUP"].to_s.strip.downcase),
      redirect_uri:, auth_method:, signing_alg: alg
    )
  end

  def self.url?(value, https: false)
    uri = URI.parse(value)
    (https ? uri.is_a?(URI::HTTPS) : uri.is_a?(URI::HTTP)) && !uri.host.to_s.empty?
  rescue URI::InvalidURIError
    false
  end

  # A username for an account made on first sign-in, from what the provider
  # says (preferred_username, else the email's local part, else the name),
  # in the characters a username may have; one that is taken gets a number.
  def self.username(claims, taken:)
    base = [claims["preferred_username"], claims["nickname"], claims["email"].to_s[/\A[^@]*/], claims["name"]]
           .map { it.to_s.gsub(/[^A-Za-z0-9._-]/, "")[0, 36] }
           .find { it.length >= 3 } || "user"
    candidates = [base, *(2..99).map { "#{base}-#{it}" }]
    candidates.find { !taken.(it) } || "#{base[0, 27]}-#{SecureRandom.hex(4)}"
  end
end
