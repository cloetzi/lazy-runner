# frozen_string_literal: true

module Api
  class ExercisesController < ApplicationController
    # The exercise library, by name.
    # @description Each exercise with the body `areas` it works, its movement
    #   `pattern` and the equipment it needs (none for bodyweight). Retired
    #   exercises are left out.
    # @param equipment? `owned` keeps to what the user owns; a comma-separated list of equipment slugs keeps to exactly that (dumbbells or a kettlebell also find exercises that need just a weight), and an empty one to bodyweight.
    # @response 200 #/components/schemas/Exercises
    # @response 400 #/components/responses/BadRequest
    def index
      exercises = Exercise.current.eager(:equipment).order(:name)
      exercises = exercises.doable_with(equipment_filter) if params.key?(:equipment)
      render json: exercises.all
    end

    # One exercise, with its cues, instructions and animation.
    # @response 200 #/components/schemas/Exercise
    # @response 404 #/components/responses/NotFound
    def show
      render json: Exercise.eager(:equipment).find!(params[:id])
    end

    # What the player offers when swapping this exercise, best match first.
    # @description Each with how well it matches (`match`: same, similar or
    #   other movement) and why (`reason`), the `weight` to start at, the
    #   `weight_unit` it takes one in (null without weighted gear) and the
    #   owned weights to step through (`allowed_weights`).
    # @response 200 #/components/schemas/Alternatives
    # @response 404 #/components/responses/NotFound
    def alternatives
      fixed = Equipment.fixed
      planned = Exercise.eager(:equipment).find!(params[:id])
      alternatives = planned.alternatives
      seeds = Step.first_weights(alternatives.map(&:id))
      render json: alternatives.map { |exercise|
        weight = exercise.start_weight(seeds[exercise.id])
        unit = exercise.weight_unit if exercise.takes_weight?(weight || seeds[exercise.id])
        exercise.as_json.merge(
          match: planned.match(exercise), reason: planned.match_reason(exercise),
          weight:, weight_unit: unit, allowed_weights: (Equipment.allowed_for(exercise.equipment_slugs, unit, fixed) if unit)
        )
      }
    end

    private

    def equipment_filter
      Equipment.named(params[:equipment])
    rescue Equipment::Unknown => error
      raise BadRequest.new(error.message, fields: { equipment: error.slugs.map { "#{it} is not an equipment slug" } })
    end
  end
end
