module Api
  class ExerciseWeightsController < ApplicationController
    # The remembered weight for an exercise, with any pending suggestion.
    # @description With nothing remembered, `value`, `unit` and `updated_at`
    #   are null and workouts use their steps' own weights. A null `value` with
    #   a `unit` remembers no weight: the exercise is done without one.
    # @response 200 #/components/schemas/ExerciseWeight
    # @response 404 #/components/responses/NotFound
    def show
      exercise = Exercise.find!(params[:id])
      weight = ExerciseWeight.find_or_new(exercise_id: exercise.id)
      render json: weight.as_json.merge(suggestion: WeightSuggestion.pending.first(exercise_id: exercise.id))
    end

    # Set the remembered weight; it applies to every workout with the exercise.
    # @description PUT and PATCH do the same. `unit` defaults to the unit the
    #   exercise keeps its weight in; a weight in the other unit is converted
    #   and snapped to an owned weight. A `value` of null (or 0) remembers no
    #   weight, which wins over the steps' own weights. Setting a weight answers any pending
    #   suggestion: accepted when it is the suggested weight, else dismissed.
    #   Reps and seconds are set per workout step, so sending them is a 400
    #   rather than being ignored.
    # @request #/components/schemas/WeightInput
    # @response 200 #/components/schemas/ExerciseWeight
    # @response 400 #/components/responses/BadRequest
    # @response 404 #/components/responses/NotFound
    # @response 422 #/components/responses/Invalid
    def update
      gone = %i[reps seconds].select { params.key?(it) }
      if gone.any?
        message = "#{gone.join(" and ")} can't be remembered: only the weight carries over, reps and seconds are set per workout step"
        raise BadRequest.new(message, fields: gone.to_h { [it, ["is set per workout step"]] })
      end
      raise BadRequest.param(:value, "is required") unless params.key?(:value)

      weight = ExerciseWeight.remember!(Exercise.find!(params[:id]), params[:value], params[:unit])
      render json: weight.as_json.merge(suggestion: nil)
    end
  end
end
