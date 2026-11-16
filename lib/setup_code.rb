# frozen_string_literal: true

require "securerandom"
require "digest"
require "rack/utils"

# The one-time code that creates the owner account on a fresh install.
#
# The boot makes a new one while there are no users and prints it in the
# log, so only whoever can read the server's log can claim the install. Only
# its digest is kept, in this process (the server runs one worker). It is
# used up by the account it creates; once a user exists there is no code.
module SetupCode
  # 130 bits as 26 base32 characters, printed in groups of five.
  ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789".chars.freeze
  LENGTH = 26

  @digest = nil

  class << self
    # A new code; the one before it no longer works.
    def generate!
      code = random(LENGTH)
      @digest = digest(code)
      code.scan(/.{1,5}/).join("-")
    end

    # Random characters from the alphabet, which leaves out the ones easily
    # misread (I, L, O, U, 0, 1); a temporary password is made the same way.
    def random(length) = Array.new(length) { ALPHABET[SecureRandom.random_number(ALPHABET.size)] }.join

    def active? = !@digest.nil?

    def match?(code)
      return false unless @digest && code.is_a?(String)

      Rack::Utils.secure_compare(digest(normalize(code)), @digest)
    end

    def consume!
      @digest = nil
    end

    private

    def normalize(code) = code.upcase.delete("^A-Z0-9")

    def digest(code) = Digest::SHA256.hexdigest(code)
  end
end
