# Activities (#177): runs, rides and other sports, as they happened, logged
# by hand or sent by a script or an agent with the numbers its source gave.
# Nothing derived is kept (no pace, load or score). An activity that came
# from somewhere else is known by `source` + `external_id` within its user,
# so sending it again updates it; one made in the app by its `client_ref`.
#
# `settings.distance_unit` (km or mi) is how distances are shown; they are
# stored in metres. It is added in place with its CHECK: Sequel's
# add_constraint would copy the table and lose `settings_unit`.
Sequel.migration do
  up do
    create_table(:activities) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      # The sender's own day the activity started on.
      Date :date, null: false
      DateTime :started_at
      String :sport, null: false
      String :title
      Integer :moving_seconds
      Integer :elapsed_seconds
      Integer :distance_m
      Integer :climb_m
      Integer :avg_hr
      Integer :max_hr
      Integer :rpe
      String :note, text: true
      String :source
      String :external_id
      String :client_ref
      String :created_by, null: false, default: "manual"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[user_id date], name: :index_activities_on_user_id_and_date
      index %i[user_id source external_id], unique: true, where: Sequel.~(external_id: nil), name: :index_activities_on_source_and_external_id
      index %i[user_id client_ref], unique: true, name: :index_activities_on_client_ref
      constraint(:activities_sport) { Sequel.function(:length, Sequel.function(:trim, :sport)) > 0 }
      constraint(:activities_created_by, created_by: %w[manual llm])
      constraint(:activities_rpe) { (rpe =~ nil) | ((rpe >= 1) & (rpe <= 10)) }
      constraint(:activities_numbers) do
        %i[moving_seconds elapsed_seconds distance_m climb_m avg_hr max_hr].map { |column| (Sequel[column] =~ nil) | (Sequel[column] >= 0) }.reduce(:&)
      end
      constraint(:activities_external_id_source) { (external_id =~ nil) | (source !~ nil) }
    end

    run "ALTER TABLE `settings` ADD COLUMN `distance_unit` varchar(255) NOT NULL DEFAULT 'km' " \
        "CONSTRAINT `settings_distance_unit` CHECK (`distance_unit` IN ('km', 'mi'))"
  end

  down do
    alter_table(:settings) { drop_column :distance_unit }
    drop_table(:activities)
  end
end
