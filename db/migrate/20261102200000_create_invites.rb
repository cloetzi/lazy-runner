# frozen_string_literal: true

# Onboarding and invites (#184). Others join by an invite link the owner
# makes: one use, seven days. Only the token's SHA-256 digest is kept, so the
# table alone lets nobody in; using an invite or revoking it deletes it.
#
# A user whose password the owner reset signs in with a temporary one and
# must choose their own before anything else (`password_change_required`).
# `welcomed_at` is when they finished or skipped the welcome screen shown on
# their first sign-in; users from before it are counted as welcomed.
Sequel.migration do
  up do
    alter_table(:users) do
      add_column :password_change_required, TrueClass, null: false, default: false
      add_column :welcomed_at, DateTime
    end
    from(:users).update(welcomed_at: :created_at)

    create_table(:invites) do
      primary_key :id
      String :digest, null: false
      DateTime :expires_at, null: false
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index :digest, unique: true, name: :index_invites_on_digest
    end
  end

  down do
    drop_table(:invites)
    alter_table(:users) do
      drop_column :welcomed_at
      drop_column :password_change_required
    end
  end
end
