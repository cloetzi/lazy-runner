require "digest"
require "securerandom"

# A personal API token: full access to its user's data, for an assistant
# (MCP) or a script, sent as `Authorization: Bearer lr_...`. The token is
# shown once, when it is made; only its SHA-256 digest is kept, so the table
# alone signs nobody in. Revoking one deletes it.
class ApiToken < Record
  PREFIX = "lr_".freeze
  # 32 random bytes, base64url: 43 characters after the prefix.
  LENGTH = PREFIX.length + 43
  # Its last use is written at most this often, so a busy assistant doesn't
  # write on every call.
  TOUCH_SECONDS = 60

  per_user
  many_to_one :user

  dataset_module do
    def latest_first = order(Sequel.desc(:created_at), Sequel.desc(:id))
  end

  def before_validation
    self.name = name.strip if name.is_a?(String)
    super
  end

  def validate
    super
    validates_type String, :name
    validates_presence :name
    validates_max_length 60, :name if name.is_a?(String)
  end

  # A new token for the user: the record, and the token itself, which is
  # never seen again. Made on a device signed in with the OIDC provider, it
  # names that identity, so unlinking it revokes the token too.
  def self.issue!(user, name, user_identity_id: nil)
    secret = "#{PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    [Current.set(user:) { create(name:, digest: digest(secret), user_identity_id:) }, secret]
  end

  # The token this secret is, whoever's it is, else nil: how a request
  # finds its user. Notes its use. A user signed in with a temporary
  # password has no API until they choose their own (a reset revokes their
  # tokens; this keeps it so should one be left).
  def self.authenticate(secret, now: Time.now)
    return unless secret.is_a?(String) && secret.bytesize == LENGTH && secret.start_with?(PREFIX)

    everyone.where(user_id: User.exclude(password_change_required: true).select(:id))
            .first(digest: digest(secret))&.tap { it.used!(now) }
  end

  def self.digest(secret) = Digest::SHA256.hexdigest(secret)

  def used!(now = Time.now)
    return if last_used_at && now - last_used_at < TOUCH_SECONDS

    this.update(last_used_at: now)
    self.last_used_at = now
  end

  def as_json(*)
    { id:, name:, created_at:, last_used_at: }
  end
end
