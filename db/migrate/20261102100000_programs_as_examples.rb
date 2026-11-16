# frozen_string_literal: true

# Programs stop being seeded: they are examples a user imports, and an
# imported copy is the user's own (`source: user`), noting the example it
# came from in `example_slug`. The copies the seed loader made become such
# imports, so nobody loses a workout or its sessions. The seed-only rules
# go: the partial unique slug indexes, the CHECKs that a seeded program or
# workout has a slug, and `seed` as a source.
#
# Changing a CHECK or a default copies the table on SQLite, and the copy
# keeps neither CHECK constraints nor partial indexes, so the ones that stay
# are made again here.
Sequel.migration do
  up do
    %i[programs workouts].each do |table|
      from(table).where(source: "seed").update(source: "user")
      alter_table(table) do
        drop_index %i[user_id slug], name: :"index_#{table}_on_slug"
        rename_column :slug, :example_slug
      end
    end

    alter_table(:programs) do
      drop_constraint :programs_seed_slug
      drop_constraint :programs_source
      set_column_default :source, "user"
    end
    alter_table(:programs) do
      add_constraint(:programs_source, source: %w[user llm])
    end

    alter_table(:workouts) do
      drop_constraint :workouts_seed_slug
      drop_constraint :workouts_source
      set_column_default :source, "user"
    end
    alter_table(:workouts) do
      add_constraint(:workouts_source, source: %w[user llm])
      add_constraint(:workouts_framing) { ~(no_warmup & (warmup_id !~ nil)) & ~(no_cooldown & (cooldown_id !~ nil)) }
    end
  end

  down do
    raise Sequel::Error, "programs can't go back to being seeded"
  end
end
