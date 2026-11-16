# frozen_string_literal: true

require "test_helper"

describe ApiToken do
  it "finds a token by its secret, and nothing by anything else" do
    token, secret = ApiToken.issue!(user, "Agent")

    _(ApiToken.authenticate(secret).id).must_equal token.id
    _(ApiToken.authenticate(secret.succ)).must_be_nil
    _(ApiToken.authenticate("#{secret}x")).must_be_nil
    _(ApiToken.authenticate(nil)).must_be_nil
  end

  it "writes its last use at most once a minute" do
    _, secret = ApiToken.issue!(user, "Agent")
    start = Time.utc(2026, 11, 2, 9)

    ApiToken.authenticate(secret, now: start)
    ApiToken.authenticate(secret, now: start + 59)
    _(ApiToken.first!.last_used_at).must_equal start

    ApiToken.authenticate(secret, now: start + 60)
    _(ApiToken.first!.last_used_at).must_equal start + 60
  end

  it "keeps no two tokens alike" do
    secrets = Array.new(3) { ApiToken.issue!(user, "Agent").last }

    _(secrets.uniq.size).must_equal 3
  end
end
