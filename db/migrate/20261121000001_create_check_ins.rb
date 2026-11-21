# frozen_string_literal: true

# Check-ins: what the user says about a day, as context for the numbers a
# watch gives. Two groups, each optional: the night that ended that morning
# (`sleep`, `drinks`, `night_tags`, `night_note`), matching how Garmin dates
# sleep and overnight HRV, and how the user felt that day (`feeling`,
# `stress`, `sore`, `sore_areas`, `ill`, `day_note`). One row a day; nothing
# is derived from them.
#
# `night_by` and `day_by` say who logged each group (manual or llm, null
# while it is empty). An agent only fills fields left empty; `agent_name` and
# `agent_at` name the last one that did, for "Since you last looked".
Sequel.migration do
  change do
    create_table(:check_ins) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      Date :date, null: false
      String :sleep
      String :drinks
      column :night_tags, :json, null: false, default: "[]"
      String :night_note, text: true
      String :night_by
      String :feeling
      String :stress
      String :sore
      column :sore_areas, :json, null: false, default: "[]"
      TrueClass :ill, null: false, default: false
      String :day_note, text: true
      String :day_by
      String :agent_name
      DateTime :agent_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      index %i[user_id date], unique: true, name: :index_check_ins_on_user_id_and_date
      index %i[user_id agent_at], name: :index_check_ins_on_agent_at
      constraint(:check_ins_sleep) { (sleep =~ nil) | Sequel.expr(sleep: %w[poor ok good]) }
      constraint(:check_ins_drinks) { (drinks =~ nil) | Sequel.expr(drinks: %w[none 1-2 3+]) }
      constraint(:check_ins_feeling) { (feeling =~ nil) | Sequel.expr(feeling: %w[rough ok good]) }
      constraint(:check_ins_stress) { (stress =~ nil) | Sequel.expr(stress: %w[low normal high]) }
      constraint(:check_ins_sore) { (sore =~ nil) | Sequel.expr(sore: %w[no a_bit a_lot]) }
      constraint(:check_ins_night_by) { (night_by =~ nil) | Sequel.expr(night_by: %w[manual llm]) }
      constraint(:check_ins_day_by) { (day_by =~ nil) | Sequel.expr(day_by: %w[manual llm]) }
    end
  end
end
