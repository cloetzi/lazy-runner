require "test_helper"

describe User do
  it "keeps the last owner" do
    runner = user
    _(runner.owner).must_equal true
    helper = create_user("helper", bare: true)

    error = _ { Current.set(user: helper) { runner.remove! } }.must_raise User::Refused
    _(error.message).must_equal "runner is the last owner"
    _(User.where(id: runner.id).count).must_equal 1
  end

  it "removes an owner while another is left" do
    runner = user
    other = create_user("other", bare: true)
    other.update(owner: true)

    Current.set(user: other) { runner.remove! }
    _(User.where(id: runner.id).count).must_equal 0
  end

  # The one connection, held for the whole transaction: a hash in there
  # would keep every other request waiting.
  it "hashes a password set from code before its transaction opens" do
    level = -> { User.db.synchronize { User.db.send(:savepoint_level, it) } }
    outside = level.()
    seen = []
    run = Hashing.method(:run)
    Hashing.define_singleton_method(:run) { |&work| seen << level.() && run.call(&work) }

    user.set_password!("a brand new password")

    _(seen).wont_be_empty
    _(seen.uniq).must_equal [outside]
    _(User.db[:account_password_hashes].where(id: user.id).get(:password_hash)).must_match(/\A\$argon2/)
  ensure
    Hashing.define_singleton_method(:run, run)
  end
end
