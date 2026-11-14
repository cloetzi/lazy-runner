# A remembered weight can be "no weight" (#230): stepping below the lightest
# weight keeps the exercise without one, rather than falling back to the
# weight a workout step sets. Allowing NULL copies the table on SQLite; it
# has no CHECK constraints or partial indexes to make again.
Sequel.migration do
  up do
    alter_table(:exercise_weights) { set_column_allow_null :value }
    # set_exercise_weight took 0 for none before: it is no weight now.
    from(:exercise_weights).where(value: 0).update(value: nil)
  end

  down do
    from(:exercise_weights).where(value: nil).delete
    alter_table(:exercise_weights) { set_column_not_null :value }
  end
end
