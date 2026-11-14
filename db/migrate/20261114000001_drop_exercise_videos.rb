# Exercises no longer link to demo videos elsewhere (#276): the column #235
# added goes. A plain DROP COLUMN (the sqlite3 gem's SQLite has it natively),
# so no table is copied and no constraint is lost.
Sequel.migration do
  up do
    drop_column :exercises, :videos
  end

  down do
    add_column :exercises, :videos, :json, null: false, default: "[]"
  end
end
