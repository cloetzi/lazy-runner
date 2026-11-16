# frozen_string_literal: true

require "test_helper"

describe Hashing do
  it "answers with what the work returns, on another thread" do
    _(Hashing.run { Thread.current }).wont_be_same_as Thread.current
    _(Hashing.run { 6 * 7 }).must_equal 42
  end

  it "raises what the work raises" do
    _(_ { Hashing.run { raise ArgumentError, "bad hash" } }.must_raise(ArgumentError).message).must_equal "bad hash"
    _(Hashing.run { :still_working }).must_equal :still_working
  end

  it "runs two at a time at most" do
    running = Queue.new
    most = Mutex.new
    peak = 0
    now = 0
    Array.new(5) do
      Thread.new do
        Hashing.run do
          most.synchronize do
            now += 1
            peak = [peak, now].max
          end
          sleep 0.02
          most.synchronize { now -= 1 }
        end
        running << true
      end
    end.each(&:join)

    _(running.size).must_equal 5
    _(peak).must_equal Hashing::THREADS
  end
end
