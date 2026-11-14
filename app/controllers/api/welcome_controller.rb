module Api
  class WelcomeController < ApplicationController
    # The welcome screen is done.
    # @description The PWA shows a welcome screen on a user's first sign-in
    #   (units, gear, example programs, each step skippable) until this is
    #   sent, when they finish or skip it; `/api/me` says `welcomed`.
    # @response 204
    def create
      Current.user!.welcomed!
      head :no_content
    end
  end
end
