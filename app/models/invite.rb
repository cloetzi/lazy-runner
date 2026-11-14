require "digest"
require "securerandom"

# A link the owner sends someone to join: `/signin.html#invite/<token>`, in
# the fragment, so no server or proxy log records it. It works once, for
# seven days. Only the token's SHA-256 digest is kept; using an invite or
# revoking it deletes it. Invites are the install's, not a user's: any
# owner sees them all.
class Invite < Record
  DAYS = 7
  # 32 random bytes, base64url.
  LENGTH = 43

  dataset_module do
    def pending(now = Time.now) = where { expires_at > now }

    def latest_first = order(Sequel.desc(:created_at), Sequel.desc(:id))
  end

  # A new invite: the record, and its token, which is never seen again.
  # Expired invites go first.
  def self.issue!(now: Time.now)
    sweep!(now)
    token = SecureRandom.urlsafe_base64(32)
    [create(digest: digest(token), expires_at: now + DAYS * 86_400), token]
  end

  # Whether the token is a pending invite's.
  def self.pending_token?(token, now: Time.now) = !with_token(token, now).empty?

  # Uses the invite up: true when the token was a pending one. Run inside
  # the transaction that makes the account, so two people can't both join
  # on one link.
  def self.redeem!(token, now: Time.now) = with_token(token, now).delete == 1

  def self.with_token(token, now)
    return where(false) unless token.is_a?(String) && token.bytesize == LENGTH

    pending(now).where(digest: digest(token))
  end

  def self.sweep!(now = Time.now) = exclude { expires_at > now }.delete

  def self.digest(token) = Digest::SHA256.hexdigest(token)

  def self.path(token) = "/signin.html#invite/#{token}"

  def as_json(*)
    { id:, created_at:, expires_at: }
  end
end
