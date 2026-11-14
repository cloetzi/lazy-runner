module Api
  class GoalsController < ApplicationController
    # The user's goals.
    # @description `goals` are the active ones in order (1 first),
    #   `proposals` the changes an agent proposed that wait for the user to
    #   accept or dismiss, and `past` the achieved, dropped and dismissed
    #   ones, the latest decided first.
    # @response 200 #/components/schemas/Goals
    def index
      render json: {
        goals: Goal.active.in_order.all,
        proposals: Goal.proposed.order(:id).all,
        past: Goal.past.all
      }
    end

    # Add a goal.
    # @description Active, and last unless `position` (1 first) puts it
    #   elsewhere. Only the user adds goals; an agent proposes them over MCP.
    # @request #/components/schemas/GoalInput
    # @response 201 #/components/schemas/Goal
    # @response 422 #/components/responses/Invalid
    def create
      goal = Goal.add!(params.slice(:title, :why, :target_date, :position))
      render json: goal, status: :created
    end

    # Change a goal.
    # @description Fields left out are kept; `why` and `target_date` sent as
    #   null are cleared. `status` is active, achieved or dropped; `position`
    #   (1 first) moves an active goal among the others. A proposal is
    #   accepted or dismissed instead, which answers 409.
    # @request #/components/schemas/GoalInput
    # @response 200 #/components/schemas/Goal
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    # @response 422 #/components/responses/Invalid
    def update
      render json: Goal.find!(params[:id]).revise!(params.slice(*Goal::FIELDS))
    end

    # Delete a goal, a proposal included.
    # @description A goal another one replaced is kept as it was; the link goes.
    # @response 204
    # @response 404 #/components/responses/NotFound
    def destroy
      Goal.find!(params[:id]).destroy
      head :no_content
    end

    # Accept a proposed goal.
    # @description It becomes active in the place of the goal it replaces
    #   (which is dropped), else last. One no longer proposed answers 409.
    # @response 200 #/components/schemas/Goal
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    def accept
      render json: Goal.find!(params[:id]).accept!
    end

    # Dismiss a proposed goal.
    # @description It is kept as dismissed, so the agent sees it was turned
    #   down and doesn't propose it again. One no longer proposed answers 409.
    # @response 200 #/components/schemas/Goal
    # @response 404 #/components/responses/NotFound
    # @response 409 #/components/responses/Conflict
    def dismiss
      render json: Goal.find!(params[:id]).dismiss!
    end
  end
end
