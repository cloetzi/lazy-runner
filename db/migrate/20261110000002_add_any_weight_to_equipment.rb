# frozen_string_literal: true

# Equipment that any owned gear in set weights stands in for: the
# generic "weight" an exercise needs when a dumbbell or a kettlebell will do.
Sequel.migration do
  change do
    add_column :equipment, :any_weight, TrueClass, null: false, default: false
  end
end
