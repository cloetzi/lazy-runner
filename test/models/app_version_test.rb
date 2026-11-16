# frozen_string_literal: true

require "test_helper"

describe AppVersion do
  it "is the version the image was built for, without a leading v" do
    with_env("APP_VERSION" => "v0.2.0") { _(AppVersion.version).must_equal "0.2.0" }
    with_env("APP_VERSION" => "1.2.3") { _(AppVersion.version).must_equal "1.2.3" }
  end

  it "is dev when no version was baked in" do
    with_env("APP_VERSION" => nil) { _(AppVersion.version).must_equal "dev" }
    with_env("APP_VERSION" => " ") { _(AppVersion.version).must_equal "dev" }
  end

  it "takes the commit baked in" do
    with_env("APP_COMMIT" => "ABCDEF0") { _(AppVersion.commit).must_equal "abcdef0" }
  end

  it "falls back to the commit of the git checkout without a sha baked in" do
    check = Rage.root.join(".git").exist? ? -> { _(it).must_match(/\A\h{7,}\z/) } : -> { _(it).must_be_nil }

    with_env("APP_COMMIT" => nil) { check.call(AppVersion.commit) }
    with_env("APP_COMMIT" => "main") { check.call(AppVersion.commit) }
  end
end
