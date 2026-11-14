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
end
