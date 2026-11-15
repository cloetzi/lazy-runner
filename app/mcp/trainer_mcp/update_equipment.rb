module TrainerMcp
  class UpdateEquipment < Tool
    description <<~TEXT.squish
      Change the user's equipment inventory, as the Equipment page does: whether they own an item, and for
      fixed-weight items (dumbbells, kettlebells) the weights they own and the unit those come in. Fields left out
      are kept; `weights` replaces the list. Use it only for what the user tells you they have (a stool that works as
      a step is the step), and say what you changed. Owning an item opens up the exercises that need it in
      search_exercises. Answers with the item as list_equipment gives it.
    TEXT
    input_schema(
      properties: {
        equipment: { type: "string", description: "The item's slug, from list_equipment." },
        owned: { type: "boolean", description: "Whether the user has it." },
        weights: {
          type: "array", items: { type: "number", exclusiveMinimum: 0 },
          description: "Every weight they own of it, such as [10, 20]; only for items with a unit."
        },
        unit: {
          type: "string", enum: ExerciseWeight::UNITS,
          description: "The unit the user's weights of it come in, only for items with a unit. It relabels the numbers " \
                       "without converting them: 20 lb dumbbells set to kg become 20 kg ones. How weights are shown is " \
                       "the user's setting, not this."
        }
      },
      required: %w[equipment]
    )
    annotations(title: "Update equipment", **REPLACES, idempotent_hint: true)

    def self.answer(equipment:, **changes)
      item = Equipment.current.first(slug: equipment) || raise(Problem, "no equipment #{equipment.inspect}; list_equipment lists the slugs")
      raise Problem, "nothing to change: give owned, weights or unit" if changes.empty?

      mine = UserEquipment.first(equipment_id: item.id) || UserEquipment.new(equipment: item, owned: false)
      mine.update(changes.transform_keys(&:to_s))
      compact(item.as_json(mine))
    end
  end
end
