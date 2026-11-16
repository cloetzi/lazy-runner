# frozen_string_literal: true

module Api
  # Signing in with the install's OpenID Connect provider (lib/oidc.rb):
  # the identities linked to your account. Linking one is a sign-in at the
  # provider (`POST /api/auth/oidc` while signed in), so it isn't here.
  # Needs a signed-in browser: an API token can't add ways in.
  class IdentitiesController < ApplicationController
    # Your linked sign-ins.
    # @description `provider` is the install's OIDC provider, as the
    #   sign-in page names it, or null when the install has none (then
    #   there is nothing to link). `password` says whether you have a
    #   password too: without one, change-password sets it without the
    #   current one, and the identity at the provider can't be unlinked.
    #   `current` is false for an identity at a provider the install no
    #   longer uses, which signs nobody in. Changing your password (signing
    #   out the other devices) or an owner's reset unlinks them all.
    # @response 200 #/components/schemas/Identities
    def index
      user = Current.user!
      render json: {
        provider: Oidc.settings&.then { { name: it.name } },
        password: user.password?,
        identities: identities.latest_first.all.map(&:as_json)
      }
    end

    # Unlink a sign-in.
    # @description It no longer signs you in: the other devices that signed
    #   in with it are signed out and the API tokens made on a device signed
    #   in with it revoked (ones from before that was recorded aren't known:
    #   sign out the other devices for them). Refused (409) when it is the only
    #   way you have to sign in: set a password first.
    # @response 204
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    def destroy
      identities.find!(params[:id]).unlink!(keep: SignedInDevice.current_key(rodauth))
      head :no_content
    end

    private

    def identities = UserIdentity.dataset
  end
end
