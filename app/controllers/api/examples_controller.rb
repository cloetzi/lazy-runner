module Api
  class ExamplesController < ApplicationController
    # The example programs.
    # @description Programs to import as your own (`db/examples`): each with
    #   its workouts and their minutes (a main workout's own, without its
    #   warm-up and cool-down), the equipment it needs (`gear`, each marked
    #   `owned` or not), how many of its exercises need gear you lack
    #   (`missing_exercises`, 0 for the best fit) and whether you have
    #   imported it.
    # @response 200 #/components/schemas/Examples
    def index
      library = Example.library
      owned = Equipment.owned.select_map(:slug)
      render json: Example.all.map { it.as_json(library, owned:) }
    end

    # Import an example program.
    # @description Copies the program and its workouts into yours, as
    #   ordinary workouts of your own: editable, duplicable, archivable. Each
    #   step's weight snaps to the nearest weight you own of its gear, and is
    #   left out when you own none of it; steps needing gear you don't have
    #   are kept. A second import is a 409 unless `copy` is true, which adds
    #   another copy.
    # @request { copy?: Boolean }
    # @response 201 #/components/schemas/Program
    # @response 400 #/components/responses/BadRequest
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    def import
      program = Example.find!(params[:slug]).import!(copy: boolean_param(:copy) || false)
      render json: Program.eager(workouts: { blocks: :steps }).with_pk(program.id), status: :created
    end
  end
end
