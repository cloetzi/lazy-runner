module Api
  class WelcomeController < ApplicationController
    # How far set-up has come, for the "Getting set up" card on Today.
    # @description Whether the user owns any `gear`, has a main workout to
    #   train (`workouts`, archived ones left out), has planned anything from `today` on
    #   (`planned`: a routine still running or a planned session) and has
    #   connected an `assistant` (an API token). `invited` is the owner's
    #   alone, null for anyone else: whether anyone else has an account or a
    #   pending invite.
    # @param today? {Date} The device's own date.
    # @response 200 #/components/schemas/Setup
    def show
      today = client_today
      user = Current.user!
      render json: {
        gear: !UserEquipment.where(owned: true).empty?,
        workouts: !Workout.active.where(kind: "workout").empty?,
        planned: !Routine.current(today).empty? || !Session.where(status: "planned").where { date >= today }.empty?,
        assistant: !ApiToken.empty?,
        invited: (!User.exclude(id: user.id).empty? || !Invite.pending.empty? if user.owner)
      }
    end

    # The welcome screen is done.
    # @description The PWA shows a welcome screen on a user's first sign-in
    #   (units, gear, example programs and training days, each step
    #   skippable) until this is sent, which it does as soon as the screen
    #   shows: what is left is on Today's "Getting set up" card. `/api/me`
    #   says `welcomed`.
    # @response 204
    def create
      Current.user!.welcomed!
      head :no_content
    end
  end
end
