# Who an invite is for (#275): an optional label the owner gives it, such
# as "For Sam", so two waiting invites can be told apart. ADD COLUMN, so no
# table is copied.
Sequel.migration do
  change do
    add_column :invites, :label, String
  end
end
