# frozen_string_literal: true

require "test_helper"

describe Invite do
  let(:now) { Time.now }

  it "is pending for seven days, to the second" do
    invite, token = Invite.issue!(now:)

    _(invite.expires_at.to_i).must_equal (now + (7 * 86_400)).to_i
    _(Invite.pending_token?(token, now: invite.expires_at - 1)).must_equal true
    _(Invite.pending_token?(token, now: invite.expires_at)).must_equal false
    _(Invite.redeem!(token, now: invite.expires_at)).must_equal false
    _(Invite.redeem!(token, now: invite.expires_at - 1)).must_equal true
    _(Invite.count).must_equal 0
  end

  it "takes no token but its own" do
    _, token = Invite.issue!(now:)

    _(Invite.pending_token?(token.succ, now:)).must_equal false
    _(Invite.pending_token?(nil, now:)).must_equal false
    _(Invite.pending_token?(token[0, 42], now:)).must_equal false
    _(Invite.pending_token?(token, now:)).must_equal true
  end

  it "clears out expired invites when making one, and keeps the pending ones" do
    old, = Invite.issue!(now: now - (8 * 86_400))
    recent, = Invite.issue!(now: now - 86_400)
    Invite.issue!(now:)

    _(Invite.where(id: old.id).count).must_equal 0
    _(Invite.where(id: recent.id).count).must_equal 1
    _(Invite.pending(now).count).must_equal 2
  end
end
