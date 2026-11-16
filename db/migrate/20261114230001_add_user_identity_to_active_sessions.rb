# frozen_string_literal: true

# Which identity at the OIDC provider a device signed in with, if any, and
# so which one an API token was made under, so unlinking that identity signs
# those devices out and revokes those tokens. Unlinked by other means
# (a new password, a reset), the identity is gone and what it signed in
# stays as the password change left it. Devices signed in and tokens made
# before this migration name none.
Sequel.migration do
  change do
    alter_table(:account_active_session_keys) do
      add_foreign_key :user_identity_id, :user_identities, on_delete: :set_null
      add_index :user_identity_id, name: :index_account_active_session_keys_on_user_identity
    end
    alter_table(:api_tokens) do
      add_foreign_key :user_identity_id, :user_identities, on_delete: :set_null
      add_index :user_identity_id, name: :index_api_tokens_on_user_identity
    end
  end
end
