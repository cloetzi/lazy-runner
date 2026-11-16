# frozen_string_literal: true

require_relative "../throttle"
require_relative "access"

module Auth
  # Every route that checks a password, counted, so none can be used to
  # guess one (lib/throttle.rb). The gate (lib/auth/gate.rb) asks before
  # Rodauth sees the request.
  module Throttles
    # Sign-in attempts, ten a minute per username. They count apart from each
    # other, so a stream of made-up usernames can't use up the attempts of
    # real users, whose hashing is bounded by how few they are (#207).
    SIGN_INS = Throttle.new(per_key: Throttle::Limit.new(10, 60))
    # The dummy hash a sign-in with an unknown username costs: 60 a minute in
    # all. Past that, such a sign-in waits as long as a hash takes instead, so
    # it answers as before, in the same time, without the work (AuthApp).
    DUMMY_HASHES = Throttle.new(per_key: Throttle::Limit.new(60, 60))
    # Setup and invite attempts, per username. A wrong setup code or invite
    # hashes nothing, and both are too long to guess (130 and 256 bits), so
    # there is no total for a stream of them to use up.
    ACCOUNTS = Throttle.new(per_key: Throttle::Limit.new(10, 60))
    # Changing the password checks the current one, and wrong ones don't lock
    # the account: five tries per account in 15 minutes.
    PASSWORD_CHANGES = Throttle.new(per_key: Throttle::Limit.new(5, 900), total: Throttle::Limit.new(60, 60))
    # Starting an OIDC sign-in to link an identity: ten a minute per signed-in
    # user. Signed out it isn't counted: a start only redirects, with the
    # provider's cached discovery document and the state in the session
    # cookie, and a count shared by everyone signed out would let anyone keep
    # the provider's users out.
    OIDC_STARTS = Throttle.new(per_key: Throttle::Limit.new(10, 60))

    ALL = [SIGN_INS, DUMMY_HASHES, ACCOUNTS, PASSWORD_CHANGES, OIDC_STARTS].freeze

    # The throttle and key a POST to the path counts against, nil for none.
    # Sign-in, setup and invites count per username, read as Rodauth reads
    # it; a change of password per account; an OIDC start per signed-in user.
    def self.for(path, rodauth)
      prefix = Access::SIGN_IN
      case path
      when "#{prefix}/login" then [SIGN_INS, rodauth.param("username").downcase[0, 100]]
      when "#{prefix}/create-account" then [ACCOUNTS, rodauth.param("username").downcase[0, 100]]
      when "#{prefix}/change-password" then [PASSWORD_CHANGES, rodauth.session_value.to_s]
      when "#{prefix}/oidc"
        [OIDC_STARTS, rodauth.session_value.to_s] if rodauth.logged_in?
      end
    end

    def self.reset! = ALL.each(&:reset!)
  end
end
