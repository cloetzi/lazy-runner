module Api
  class TokensController < ApplicationController
    # Your API tokens.
    # @description Newest first, without the tokens themselves, which are
    #   only shown when made. Needs a signed-in browser: an API token can't
    #   list, make or revoke tokens.
    # @response 200 #/components/schemas/ApiTokens
    def index
      render json: { tokens: tokens.latest_first.all.map(&:as_json) }
    end

    # Make an API token.
    # @description For an assistant (point its MCP client at `/mcp`) or a
    #   script (`Authorization: Bearer <token>` on `/api`), with full access
    #   to your data. `secret` is the token: it is shown this once.
    # @request { name: String }
    # @response 201 #/components/schemas/NewApiToken
    # @response 422 #/components/responses/Invalid
    def create
      user = Current.user!
      identity = SignedInDevice.identity_id(user, SignedInDevice.current_key(rodauth))
      token, secret = ApiToken.issue!(user, params[:name], user_identity_id: identity)
      render json: { token: token.as_json, secret: }, status: :created
    end

    # Revoke an API token.
    # @description It stops working at once.
    # @response 204
    # @response 404 #/components/responses/NotFound
    def destroy
      tokens.find!(params[:id]).destroy
      head :no_content
    end

    private

    def tokens = ApiToken.dataset
  end
end
