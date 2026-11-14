# Each user says which unit their weighted gear comes in (#189): a user
# whose kettlebells are 16 and 24 kg lists them as kg. Null until set or
# weights are listed, while the item follows the user's unit (Settings).
# Rows there already keep the catalogue's unit, so nothing an existing user
# has changes unit.
# Added in place with its CHECK: add_constraint would copy the table.
Sequel.migration do
  up do
    run "ALTER TABLE user_equipment ADD COLUMN unit varchar(255) CONSTRAINT user_equipment_unit CHECK (unit IN ('lb', 'kg'))"
    self[:user_equipment]
      .update(unit: self[:equipment].where(id: Sequel[:user_equipment][:equipment_id]).select(:unit))
  end

  down do
    alter_table(:user_equipment) { drop_column :unit }
  end
end
