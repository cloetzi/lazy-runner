# frozen_string_literal: true

# Exercises that alternate sides within one set, such as the dead bug:
# their reps count both sides together. The seeds say which on every boot.
# An ADD COLUMN, so no table is copied.
Sequel.migration do
  change do
    add_column :exercises, :alternating, TrueClass, null: false, default: false
  end
end
