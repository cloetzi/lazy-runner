module Api
  # Invite links, for the owner: how anyone else gets an account. Needs a
  # signed-in browser: an API token can't manage users or invites.
  class InvitesController < ApplicationController
    before_action :owner_only!

    # The invites not used yet.
    # @description For the owner only (else a 403), newest first, without
    #   their links, which are only shown when made. Expired ones are left out.
    # @response 200 #/components/schemas/Invites
    # @response 403 #/components/responses/Forbidden
    def index
      render json: { invites: Invite.pending.latest_first.all.map(&:as_json) }
    end

    # Make an invite link.
    # @description `path` is the link, on this server: send it to the
    #   person joining. It works once, for 7 days, and is shown this once.
    #   They choose a username and password with it (`POST
    #   /api/auth/create-account` with `invite`, the token after
    #   `#invite/`). The token is in the fragment, so no log records it.
    # @response 201 #/components/schemas/NewInvite
    # @response 403 #/components/responses/Forbidden
    def create
      invite, token = Invite.issue!
      render json: { invite: invite.as_json, token:, path: Invite.path(token) }, status: :created
    end

    # Revoke an invite.
    # @description Its link stops working at once.
    # @response 204
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    def destroy
      Invite.find!(params[:id]).destroy
      head :no_content
    end
  end
end
