# frozen_string_literal: true

require "securerandom"
require "openssl"
require "fileutils"

# The secret that seals the session cookie, and the keys derived from it.
#
# SESSION_SECRET (at least 64 bytes) when it is set; otherwise one generated
# on first boot and kept in storage/session_secret, readable by the app's
# user only, so `docker run` needs no setup and a restart doesn't sign
# everyone out. Tests get a fresh one per run.
module Secrets
  MINIMUM_BYTES = 64

  class Error < StandardError; end

  def self.session
    @session ||= from_env || (Rage.env.test? ? SecureRandom.hex(64) : from_file)
  end

  # A key for one purpose, so a key leaked from one use can't be replayed
  # in another.
  def self.derive(purpose)
    OpenSSL::HMAC.hexdigest("SHA256", session, purpose)
  end

  def self.from_env
    secret = ENV["SESSION_SECRET"].presence or return
    raise Error, "SESSION_SECRET must be at least #{MINIMUM_BYTES} bytes" if secret.bytesize < MINIMUM_BYTES

    secret
  end

  def self.from_file(path = Rage.root.join("storage/session_secret"))
    path = path.to_s
    return read(path) if File.exist?(path)

    FileUtils.mkdir_p(File.dirname(path))
    secret = SecureRandom.hex(64)
    # Written whole to a file readable by its owner only, then linked into
    # place, which never overwrites: two boots racing both read the one that
    # won, and nobody reads a half-written one.
    draft = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}"
    File.open(draft, File::WRONLY | File::CREAT | File::EXCL, 0o600) { it.write(secret) }
    begin
      File.link(draft, path)
      secret
    rescue Errno::EEXIST
      read(path)
    ensure
      File.unlink(draft)
    end
  end

  def self.read(path)
    secret = File.read(path).strip
    raise Error, "#{path} holds no secret (#{MINIMUM_BYTES}+ bytes); remove it to make a new one" if secret.bytesize < MINIMUM_BYTES

    secret
  end
end
