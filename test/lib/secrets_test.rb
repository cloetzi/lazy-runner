# frozen_string_literal: true

require "test_helper"

describe Secrets do
  it "makes a secret on first use, readable by its owner only, and reads it back after" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "storage/session_secret")
      secret = Secrets.from_file(path)

      _(secret.bytesize).must_be :>=, Secrets::MINIMUM_BYTES
      _(File.stat(path).mode & 0o777).must_equal 0o600
      _(Secrets.from_file(path)).must_equal secret
    end
  end

  it "keeps the secret that is there, and refuses an empty one" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session_secret")
      File.write(path, "y" * 64)
      _(Secrets.from_file(path)).must_equal "y" * 64
      _(Dir.children(dir)).must_equal ["session_secret"]

      File.write(path, "")
      _ { Secrets.from_file(path) }.must_raise Secrets::Error
    end
  end

  it "takes SESSION_SECRET when it is long enough" do
    ENV["SESSION_SECRET"] = "x" * 64
    _(Secrets.from_env).must_equal "x" * 64

    ENV["SESSION_SECRET"] = "too short"
    _ { Secrets.from_env }.must_raise Secrets::Error
  ensure
    ENV.delete("SESSION_SECRET")
  end

  it "derives a different key for each purpose" do
    _(Secrets.derive("one")).wont_equal Secrets.derive("two")
    _(Secrets.derive("one")).must_equal Secrets.derive("one")
  end
end
