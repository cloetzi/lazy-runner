# frozen_string_literal: true

require "test_helper"

describe Throttle do
  let(:now) { [1000.0] }
  let(:throttle) do
    Throttle.new(per_key: Throttle::Limit.new(3, 60), total: Throttle::Limit.new(5, 60), clock: -> { now.first })
  end

  it "lets attempts through up to the limit per key, then says how long to wait" do
    3.times { _(throttle.hit("runner")).must_be_nil }
    now[0] += 20

    _(throttle.hit("runner")).must_equal 40
  end

  it "counts a username whatever its case" do
    3.times { throttle.hit("Runner") }

    _(throttle.hit("RUNNER")).wont_be_nil
  end

  it "forgets attempts once they leave the window" do
    3.times { throttle.hit("runner") }
    now[0] += 60

    _(throttle.hit("runner")).must_be_nil
  end

  it "caps the attempts on every key together" do
    5.times { throttle.hit(it.to_s) }

    _(throttle.hit("someone else")).must_equal 60
  end

  it "counts every key apart without a total" do
    apart = Throttle.new(per_key: Throttle::Limit.new(3, 60), clock: -> { now.first })
    10.times { apart.hit("made-up-#{it}") }

    _(apart.hit("runner")).must_be_nil
  end

  it "doesn't count an attempt it turned away" do
    3.times { throttle.hit("runner") }
    10.times { throttle.hit("runner") }
    now[0] += 60

    3.times { _(throttle.hit("runner")).must_be_nil }
  end

  it "forgets usernames nobody tries any more" do
    5.times { throttle.hit("made-up-#{it}") }
    now[0] += 61
    throttle.hit("runner")

    _(throttle.size).must_equal 2 # runner and the total
  end

  it "holds a bounded number of keys, the newest" do
    small = Throttle.new(per_key: Throttle::Limit.new(3, 60), max_keys: 3, clock: -> { now.first })
    3.times { small.hit("runner") }
    _(small.hit("runner")).wont_be_nil
    3.times { small.hit("made-up-#{it}") }

    _(small.size).must_equal 3
    _(small.hit("runner")).must_be_nil
  end
end
