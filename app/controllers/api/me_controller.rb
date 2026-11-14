module Api
  class MeController < ApplicationController
    skip_before_action :password_chosen!

    # Who is signed in on this device.
    # @description The signed-in user. Without one, a 401 that says whether
    #   the install still needs its owner account (`setup_required`): the
    #   PWA then shows the setup screen, else the sign-in screen. Public, as
    #   `/api/version` and `/api/openapi` are; every other route under `/api`
    #   answers a 401 without a session or an API token (and `/mcp` without a
    #   token). `password_change_required` means the user signed in with a
    #   temporary password and must change it (`POST
    #   /api/auth/change-password`) before anything else; `welcomed`, that
    #   they have been through the welcome screen. Signed out,
    #   `sign_in_with` names the install's OpenID Connect provider when it
    #   has one: the sign-in page then offers it (`POST /api/auth/oidc`).
    # @response 200 #/components/schemas/Me
    # @response 401 #/components/responses/SignedOut
    def show
      return render(json: { user: Current.user.as_json }) if Current.user

      render json: AuthApp.error_body(401, "Sign in to continue", setup_required: User.empty?, sign_in_with: Oidc.settings&.name), status: :unauthorized
    end
  end
end
