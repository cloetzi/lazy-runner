# Signing in with an OpenID Connect provider (#185): an identity at the
# provider (its issuer and the `sub` it gives the person) points at one
# user. A user has a password, identities or both. Keyed by the issuer, so
# pointing the install at another provider can't let its users in as the
# old one's.
Sequel.migration do
  change do
    create_table(:user_identities) do
      primary_key :id
      foreign_key :user_id, :users, null: false, on_delete: :cascade
      String :issuer, null: false
      String :subject, null: false
      String :username
      DateTime :last_used_at
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index %i[issuer subject], unique: true, name: :index_user_identities_on_identity
      index %i[user_id issuer], unique: true, name: :index_user_identities_on_user
    end
  end
end
