# The join tables between equipment and the exercises and steps that need it
# are plain lists of pairs: nothing reads when a pair was made, and Sequel's
# many_to_many writes only the pair.
Sequel.migration do
  up do
    %i[exercise_equipment step_equipment].each do |table|
      alter_table(table) do
        drop_column :created_at
        drop_column :updated_at
      end
    end
  end

  down do
    %i[exercise_equipment step_equipment].each do |table|
      alter_table(table) do
        add_column :created_at, DateTime
        add_column :updated_at, DateTime
      end
    end
  end
end
