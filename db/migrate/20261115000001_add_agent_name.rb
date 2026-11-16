# frozen_string_literal: true

# Who planned it: what an agent writes over MCP carries the name of
# the API token it connected with, so the app shows one name for it
# everywhere. Coach notes already have `author_name`. Rows written before
# this have none, and the app shows its default name for them. ADD COLUMNs,
# so no table is copied.
Sequel.migration do
  change do
    # rubocop:disable-next Sequel/IrreversibleMigration -- add_column reverses
    %i[sessions routines activities goals].each do |table|
      add_column table, :agent_name, String
    end
  end
end
