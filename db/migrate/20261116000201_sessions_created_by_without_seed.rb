# frozen_string_literal: true

# Programs and their sessions are no longer seeded, so "seed" left the
# session creators. A session that still says so counts as the user's.
Sequel.migration do
  up do
    from(:sessions).where(created_by: "seed").update(created_by: "manual")
  end

  down do
    # Nothing to put back: which sessions said "seed" isn't kept.
  end
end
