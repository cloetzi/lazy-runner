# Accounts and sign-in (lib/auth_app.rb). `users` is Rodauth's accounts
# table: a username to sign in with (case-insensitive) and whether the user
# owns the install. The other tables are Rodauth's own, named as it names
# them: the password hashes (kept apart, so a query on users never carries
# one), failed sign-ins and lockouts, and the signed-in devices.
Sequel.migration do
  change do
    create_table(:users) do
      primary_key :id
      String :username, null: false, collate: "NOCASE"
      TrueClass :owner, null: false, default: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index :username, unique: true, name: :index_users_on_username
      constraint(:users_username, Sequel.lit("length(username) BETWEEN 3 AND 40"))
    end

    create_table(:account_password_hashes) do
      foreign_key :id, :users, primary_key: true, on_delete: :cascade
      String :password_hash, null: false
    end

    create_table(:account_login_failures) do
      foreign_key :id, :users, primary_key: true, on_delete: :cascade
      Integer :number, null: false, default: 1
    end

    create_table(:account_lockouts) do
      foreign_key :id, :users, primary_key: true, on_delete: :cascade
      String :key, null: false
      DateTime :deadline, null: false
      DateTime :email_last_sent
    end

    # One row per signed-in device. session_id is an HMAC of the key kept
    # in that device's session cookie.
    create_table(:account_active_session_keys) do
      primary_key :id
      foreign_key :account_id, :users, null: false, on_delete: :cascade
      String :session_id, null: false
      String :device
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :last_use, null: false, default: Sequel::CURRENT_TIMESTAMP
      index %i[account_id session_id], unique: true, name: :index_account_active_session_keys_on_session
    end
  end
end
