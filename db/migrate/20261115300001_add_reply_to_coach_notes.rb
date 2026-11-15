# A reply to a coach note (#263): the user's few words under a note they
# didn't write, linked to it. Deleting the note deletes its replies. A plain
# key, as a coach note's link to its session is: the model checks the note is
# the same user's. An ADD COLUMN, so no table is copied.
Sequel.migration do
  change do
    alter_table(:coach_notes) do
      add_foreign_key :reply_to_id, :coach_notes, on_delete: :cascade
      add_index :reply_to_id, name: :index_coach_notes_on_reply_to_id
    end
  end
end
