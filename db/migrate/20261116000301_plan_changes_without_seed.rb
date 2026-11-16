# frozen_string_literal: true

# Sessions lost the "seed" creator (20261116000201), but a removal recorded
# before then keeps it in what it would plan again, which taking the removal
# back must be able to save: such a session counts as the user's there too.
Sequel.migration do
  up do
    from(:plan_changes)
      .where(Sequel.function(:json_extract, :was, "$.created_by") => "seed")
      .update(was: Sequel.function(:json_set, :was, "$.created_by", "manual"))
  end

  down do
    # Nothing to put back: which changes said "seed" isn't kept.
  end
end
