# frozen_string_literal: true

# The session whose finish superseded a suggestion, so reopening or deleting
# that session can give the suggestion back.
Sequel.migration do
  change do
    alter_table(:weight_suggestions) do
      add_foreign_key :superseded_by_id, :sessions, on_delete: :set_null
      add_index :superseded_by_id, name: :index_weight_suggestions_on_superseded_by_id
    end
  end
end
