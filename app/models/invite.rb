# frozen_string_literal: true

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
  MAX_LABEL = 60

  dataset_module do
    def pending(now = Time.now) = where { expires_at > now }

    def latest_first = order(Sequel.desc(:created_at), Sequel.desc(:id))
  end

  # A new invite, with an optional `label` saying who it is for: the
  # record, and its token, which is never seen again. Expired invites go
  # first.
  def self.issue!(label: nil, now: Time.now)
    token = SecureRandom.urlsafe_base64(32)
    # A refused label leaves the expired ones be.
    invite = db.transaction do
      sweep!(now)
      create(label:, digest: digest(token), expires_at: now + (DAYS * 86_400))
    end
    [invite, token]
  end

  # Whether the token is a pending invite's.
  def self.pending_token?(token, now: Time.now) = !with_token(token, now).empty?

  # Whether someone can join with the token now: a pending invite's, on an
  # install with an owner (on one without, no invite counts). Joining and
  # the check before the join form ask the same.
  def self.usable?(token, now: Time.now) = !User.empty? && pending_token?(token, now:)

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

  def before_validation
    self.label = label.strip.presence if label.is_a?(String)
    super
  end

  def validate
    super
    validates_type String, :label, allow_nil: true
    validates_max_length MAX_LABEL, :label, message: "is longer than #{MAX_LABEL} characters" if label.is_a?(String)
  end

  def as_json(*)
    { id:, label:, created_at:, expires_at: }
  end
end
