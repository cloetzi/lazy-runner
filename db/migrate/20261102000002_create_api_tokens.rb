# frozen_string_literal: true

# Personal API tokens: how an assistant (MCP) or a script signs in as
# a user. Only a token's SHA-256 digest is kept; the token itself is shown
# once, when it is made. Revoking one deletes it.
Sequel.migration do
  change do
    create_table(:api_tokens) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :name, null: false
      String :digest, null: false
      DateTime :last_used_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index :digest, unique: true, name: :index_api_tokens_on_digest
      index :user_id, name: :index_api_tokens_on_user_id
      constraint(:api_tokens_name, Sequel.lit("length(trim(name)) BETWEEN 1 AND 60"))
    end
  end
end
