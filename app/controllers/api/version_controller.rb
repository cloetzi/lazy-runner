module Api
  class VersionController < ApplicationController
    # The running version and the current release of the frontend.
    # @description Never stored by the browser: the service worker asks on
    #   each page load whether a new release of the frontend is out. Settings
    #   shows the version and commit.
    # @response 200 #/components/schemas/Version
    def show
      headers["cache-control"] = "no-store"
      render json: { release: Release.id, version: AppVersion.version, commit: AppVersion.commit }
    end
  end
end
