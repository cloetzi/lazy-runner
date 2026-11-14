module Api
  # The install's users, for the owner. Needs a signed-in browser: an API
  # token can't manage users or invites.
  class UsersController < ApplicationController
    before_action :owner_only!

    # Everyone who can sign in.
    # @description For the owner only (else a 403), oldest first.
    # @response 200 #/components/schemas/Users
    # @response 403 #/components/responses/Forbidden
    def index
      render json: { users: User.order(:created_at, :id).all.map(&:admin_json) }
    end

    # Reset a user's password.
    # @description Gives them a temporary password, shown this once, which
    #   they must change when they next sign in: until then every route
    #   answers them a 401 `password_change_required`. Their devices are
    #   signed out, their API tokens revoked and a lockout lifted. Not for
    #   your own: change that under Account (a 409).
    # @response 200 #/components/schemas/TemporaryPassword
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    def reset_password
      render json: { password: User.find!(params[:id]).reset_password! }
    end

    # Remove a user and their data.
    # @description Their workouts, sessions, gear, settings, devices and
    #   API tokens go with them, for good. You can't remove yourself or the
    #   last owner (a 409).
    # @response 204
    # @response 403 #/components/responses/Forbidden
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    def destroy
      User.find!(params[:id]).remove!
      head :no_content
    end
  end
end
