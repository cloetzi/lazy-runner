# frozen_string_literal: true

module TrainerMcp
  # Lets /mcp in with a personal API token (ApiToken), through the mcp gem's
  # bearer check: the transport answers 401 with WWW-Authenticate without one,
  # and hands the verified token to every tool as `server_context.auth_info`,
  # its subject the user's id. An OAuth flow later (an authorization server
  # issuing tokens) is a swap of this verifier. The token's name goes along
  # as the `agent_name` claim: what the agent is called on what it writes;
  # whether it has REST access as `rest`, which the REST API checks
  # (lib/auth/gate.rb). For the REST API (`rest: true`) a token is noted as used only
  # when it has REST access, so one turned away there doesn't read as used.
  class TokenVerifier
    def initialize(rest: false)
      @rest = rest
    end

    def verify(secret)
      token = ApiToken.authenticate(secret, touch: !@rest) or raise MCP::Server::OAuth::InvalidTokenError, "Unknown or revoked token"
      token.used! if @rest && token.rest?

      MCP::Server::OAuth::AccessToken.new(token: secret, subject: token.user_id.to_s, client_id: token.id.to_s,
                                          claims: { "agent_name" => token.name, "rest" => token.rest? })
    end
  end
end
