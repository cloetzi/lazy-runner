# An identity at the install's OpenID Connect provider (lib/oidc.rb) that
# signs its user in: the provider's issuer and the `sub` it gives them. The
# sign-in itself is in lib/auth/oidc_callback.rb; this is what Settings lists and
# unlinks. `username` is what the provider called them, for the list.
class UserIdentity < Record
  # Unlinking the one way left into an account.
  class Refused < StandardError; end

  per_user
  many_to_one :user

  dataset_module do
    def latest_first = order(Sequel.desc(:created_at), Sequel.desc(:id))
  end

  # The identity the provider vouched for, whoever's it is, else nil: how
  # a sign-in finds its user.
  def self.find_identity(issuer, subject) = everyone.first(issuer:, subject:)

  # Unlinks it, unless it is the only way the user has to sign in: one at
  # the install's provider, for a user without a password (there is one
  # identity per provider). One at a provider the install no longer uses
  # signs nobody in and can always go. The devices that signed in with it
  # are signed out, but for the one asking (`keep`, its key as
  # SignedInDevice.current_key gives it), and the API tokens made on them
  # revoked: whoever could use the identity is out too.
  def unlink!(keep: nil)
    db.transaction do
      if issuer == Oidc.settings&.issuer && !user.password?
        raise Refused, "Set a password first: this is the only way you sign in"
      end

      SignedInDevice.of(user).where(user_identity_id: id).exclude(session_id: keep).delete
      ApiToken.of(user_id).where(user_identity_id: id).delete
      destroy
    end
  end

  def as_json(*)
    { id:, username:, current: issuer == Oidc.settings&.issuer, created_at:, last_used_at: }
  end
end
