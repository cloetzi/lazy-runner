# The app no longer suggests weights (#264): changing one is the user's and
# the coach's. The table goes with its rows; the finish feedback that drove
# them stays on completions for the coach to read.
Sequel.migration do
  up do
    drop_table?(:weight_suggestions)
  end

  down do
    raise Sequel::Error, "weight suggestions were dropped with their rows; restore a backup from before this migration instead"
  end
end
