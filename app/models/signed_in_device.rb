# The devices a user is signed in on: one row per sign-in, kept by Rodauth's
# active_sessions feature (lib/auth_app.rb), so a plain dataset rather than a
# model. The cookie holds a random key; the row holds its HMAC, so the table
# alone can't sign anyone in.
module SignedInDevice
  TABLE = :account_active_session_keys

  def self.of(user) = DB[TABLE].where(account_id: user.id)

  # What the table keeps for the device `rodauth` answers (the HMAC of its
  # session's key), nil when it has no session (an API token).
  def self.current_key(rodauth)
    key = rodauth.session[rodauth.session_id_session_key]
    key && rodauth.compute_hmac(key)
  end

  # The identity at the OIDC provider the device with this key signed in
  # with, if it did.
  def self.identity_id(user, key) = key && of(user).where(session_id: key).get(:user_identity_id)

  def self.latest_first(user) = of(user).order(Sequel.desc(:last_use), Sequel.desc(:id))

  def self.as_json(row, current_key)
    {
      id: row[:id], device: row[:device], signed_in_at: row[:created_at], last_used_at: row[:last_use],
      current: !current_key.nil? && row[:session_id] == current_key
    }
  end
end
