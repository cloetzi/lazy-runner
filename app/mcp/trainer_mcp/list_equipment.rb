module TrainerMcp
  class ListEquipment < Tool
    description <<~TEXT.squish
      The user's equipment inventory: every item the library knows, whether the user owns it, and
      for fixed-weight items (dumbbells, kettlebells) the weights owned, in the unit the user's item comes in. Plan
      only with what is owned, and only with the weights owned. `weight` (any_weight) is the generic
      weight exercises need when any dumbbell or kettlebell will do: owned with any of them, with all
      their weights, and not changed with update_equipment. `unit` is how the user likes weights
      shown (lb or kg).
    TEXT
    annotations(title: "List equipment", **READ_ONLY)

    def self.answer
      { unit: Setting.unit, equipment: Equipment.listed.map { compact(it) } }
    end
  end
end
