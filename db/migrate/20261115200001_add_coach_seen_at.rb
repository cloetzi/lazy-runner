# frozen_string_literal: true

# When the user last marked Coach's "Since you last looked" as seen (#259):
# what agents did after it is news, and the Coach tab carries a dot until
# then. Null until the first time, when the last two weeks are news. An ADD
# COLUMN, so no table is copied.
Sequel.migration do
  change do
    add_column :users, :coach_seen_at, DateTime
  end
end
