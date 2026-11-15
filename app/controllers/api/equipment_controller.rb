module Api
  class EquipmentController < ApplicationController
    # The equipment catalogue, in display order, with what the user owns.
    # @description Each item says whether the user owns it and the weights
    #   they own of it, in its `unit`.
    # @response 200 #/components/schemas/EquipmentList
    def index
      render json: Equipment.listed
    end

    # Change whether the user owns an item, which weights, and their unit.
    # @description Fields left out are kept. Only items with a `unit`
    #   (dumbbells, kettlebells) take `weights` and `unit`. `weights` are in
    #   the item's `unit`, which is the user's own (Settings) until weights are
    #   listed, and then stays the one they were listed in. Changing `unit`
    #   keeps the numbers: it says what they were in.
    # @request { owned?: Boolean, weights?: [Numeric], unit?: [lb, kg] }
    # @response 200 #/components/schemas/Equipment
    # @response 400 #/components/responses/BadRequest
    # @response 404 #/components/responses/NotFound
    # @response 422 #/components/responses/Invalid
    def update
      item = Equipment.current.find!(params[:id])
      mine = UserEquipment.first(equipment_id: item.id) || UserEquipment.new(equipment: item, owned: false)
      changes = params.slice(:weights, :unit)
      changes[:owned] = boolean_param(:owned) if params.key?(:owned)
      mine.update(changes)
      render json: item.as_json(mine)
    end
  end
end
