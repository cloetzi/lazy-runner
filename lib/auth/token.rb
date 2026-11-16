# frozen_string_literal: true

module Auth
  # A personal API token in place of the session (ApiToken, made in
  # Settings). It is read and checked as /mcp checks it (the mcp gem's bearer
  # parsing, TrainerMcp::TokenVerifier), so the two can't drift apart. What a
  # request with one may do is the gate's (lib/auth/gate.rb).
  module Token
    # The Bearer scheme as the mcp gem reads it: "Bearer" then a space or
    # nothing. Another scheme (a proxy's Basic sign-in passed through, say) is
    # left alone, and the request reads as one without a token.
    BEARER = /\ABearer(?: |\z)/i
    REFUSED = "Manage the account from a signed-in browser, not with an API token"
    MCP_ONLY = "This API token is for MCP (/mcp) only; for the REST API, make one with REST access in Settings"
    INVALID = "Send a valid API token: Authorization: Bearer lr_..."

    def self.bearer?(env) = env["HTTP_AUTHORIZATION"].to_s.b.match?(BEARER)

    # The mcp gem's bearer check, with the app's verifier: one reading of a
    # token for /api and /mcp alike (for /api, noted as used only with REST
    # access).
    def self.authenticator
      @authenticator ||= MCP::Server::OAuth::Authenticator.new(token_verifier: TrainerMcp::TokenVerifier.new(rest: true))
    end

    # The token's access token (subject: the user's id; claims: `rest` and
    # `agent_name`). Raises MCP::Server::OAuth::Error for a missing, unknown,
    # revoked or expired one.
    def self.authenticate(env) = authenticator.authenticate(env)

    # The WWW-Authenticate challenge the mcp gem gives for the error, if any.
    def self.challenge(error)
      _, headers, = authenticator.challenge_response(error)
      headers.find { |key, _| key.casecmp?("www-authenticate") }&.last
    end
  end
end
