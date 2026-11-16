# frozen_string_literal: true

module Api
  class SettingsController < ApplicationController
    # The user's settings.
    # @description `unit` is lb or kg: how weights are shown and stepped. Each
    #   exercise still keeps its weights in its equipment's unit.
    #   `distance_unit` is km or mi: how distances are shown (with climb in m
    #   or ft). Activities keep theirs in metres.
    # @response 200 #/components/schemas/Setting
    def show
      render json: Setting.current
    end

    # Change the user's settings.
    # @description Fields left out are kept.
    # @request { unit?: [lb, kg], distance_unit?: [km, mi] }
    # @response 200 #/components/schemas/Setting
    # @response 422 #/components/responses/Invalid
    def update
      setting = Setting.current
      setting.update(params.slice(:unit, :distance_unit))
      render json: setting
    end
  end
end
