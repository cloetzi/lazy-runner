module TrainerMcp
  # Lets /mcp in with a personal API token (ApiToken), through the mcp gem's
  # bearer check: the transport answers 401 with WWW-Authenticate without one,
  # and hands the verified token to every tool as `server_context.auth_info`,
  # its subject the user's id. An OAuth flow later (an authorization server
  # issuing tokens) is a swap of this verifier.
  class TokenVerifier
    def verify(secret)
      token = ApiToken.authenticate(secret) or raise MCP::Server::OAuth::InvalidTokenError, "Unknown or revoked token"

      MCP::Server::OAuth::AccessToken.new(token: secret, subject: token.user_id.to_s, client_id: token.id.to_s)
    end
  end
end
