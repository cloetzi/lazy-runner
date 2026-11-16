# frozen_string_literal: true

# A day on the calendar can hold several sessions: `position` orders them
# (1 first), and `note` keeps the planner's reason for one ("easy legs, long
# run on Saturday"). Existing days are numbered by id.
#
# SQLite drops a default and adds a CHECK constraint by copying the table.
# Sequel switches foreign keys off for the copy, which SQLite only allows
# outside a transaction; with them on, dropping the old sessions table would
# fail on the set logs and completions that point at it.
Sequel.migration do
  no_transaction

  up do
    alter_table(:sessions) do
      add_column :position, Integer, null: false, default: 1
      add_column :note, String, text: true
    end

    earlier = Sequel[:earlier]
    self[:sessions].update(
      position: from(Sequel[:sessions].as(:earlier))
        .where(earlier[:date] => Sequel[:sessions][:date])
        .where { earlier[:id] <= Sequel[:sessions][:id] }
        .select { count.function.* }
    )

    alter_table(:sessions) do
      set_column_default :position, nil
      add_constraint(:sessions_position) { position >= 1 }
      # The calendar and Today read days in order; this covers lookups by date too.
      add_index %i[date position], name: :index_sessions_on_date_and_position
      drop_index :date, name: :index_sessions_on_date
    end
  end

  down do
    alter_table(:sessions) do
      add_index :date, name: :index_sessions_on_date
      drop_index %i[date position], name: :index_sessions_on_date_and_position
      drop_constraint :sessions_position
      drop_column :note
      drop_column :position
    end
  end
end
