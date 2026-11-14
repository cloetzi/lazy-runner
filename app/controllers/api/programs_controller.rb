module Api
  class ProgramsController < ApplicationController
    # The user's programs and their workouts.
    # @response 200 #/components/schemas/Programs
    def index
      render json: Program.eager(workouts: { blocks: :steps }).order(:id).all
    end
  end
end
