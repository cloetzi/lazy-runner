require "digest"
require "securerandom"

# A personal API token: access to its user's data for an assistant (MCP) or
# a script, sent as `Authorization: Bearer lr_...`. Its `scope` says where:
# `mcp`, the trainer's MCP server alone (the default), or `api`, the REST
# API under /api as well, ticked when it is made. What is written with
# either is the agent's, under the rules the models keep for agents
# (Record.user_only!). The token is shown once, when it is made; only its
# SHA-256 digest is kept, so the table alone signs nobody in. Revoking one
# deletes it.
class ApiToken < Record
  PREFIX = "lr_".freeze
  # `api` is good for /mcp and /api, `mcp` for /mcp alone.
  SCOPES = %w[mcp api].freeze
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
    validates_includes SCOPES, :scope, message: "must be one of #{SCOPES.join(", ")}"
  end

  # Whether it is good for the REST API under /api, not only for MCP.
  def rest? = scope == "api"

  # A new token for the user: the record, and the token itself, which is
  # never seen again. Made on a device signed in with the OIDC provider, it
  # names that identity, so unlinking it revokes the token too.
  def self.issue!(user, name, scope: "mcp", user_identity_id: nil)
    secret = "#{PREFIX}#{SecureRandom.urlsafe_base64(32)}"
    [Current.set(user:) { create(name:, scope:, digest: digest(secret), user_identity_id:) }, secret]
  end

  # The token this secret is, whoever's it is, else nil: how a request
  # finds its user. Notes its use. A user signed in with a temporary
  # password has no API until they choose their own (a reset revokes their
  # tokens; this keeps it so should one be left).
  # `touch: false` leaves its use to the caller.
  def self.authenticate(secret, now: Time.now, touch: true)
    return unless secret.is_a?(String) && secret.bytesize == LENGTH && secret.start_with?(PREFIX)

    everyone.where(user_id: User.exclude(password_change_required: true).select(:id))
            .first(digest: digest(secret))&.tap { it.used!(now) if touch }
  end

  def self.digest(secret) = Digest::SHA256.hexdigest(secret)

  def used!(now = Time.now)
    return if last_used_at && now - last_used_at < TOUCH_SECONDS

    this.update(last_used_at: now)
    self.last_used_at = now
  end

  def as_json(*)
    { id:, name:, scope:, created_at:, last_used_at: }
  end
end
