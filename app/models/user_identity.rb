# An identity at the install's OpenID Connect provider (lib/oidc.rb) that
# signs its user in: the provider's issuer and the `sub` it gives them. The
# sign-in itself is in lib/auth_app.rb; this is what Settings lists and
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
  # signs nobody in and can always go.
  def unlink!
    db.transaction do
      if issuer == Oidc.settings&.issuer && !user.password?
        raise Refused, "Set a password first: this is the only way you sign in"
      end

      destroy
    end
  end

  def as_json(*)
    { id:, username:, current: issuer == Oidc.settings&.issuer, created_at:, last_used_at: }
  end
end
