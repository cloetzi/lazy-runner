require "test_helper"

describe "GET /api/version" do
  include RequestHelpers

  it "names the current release and is never cached" do
    get "/api/version"

    _(last_response.status).must_equal 200
    _(last_response.headers["cache-control"]).must_equal "no-store"
    _(json["release"]).must_match(/\A\h{16}\z/)
  end

  it "stays the same while public/ does not change" do
    get "/api/version"
    first = json["release"]
    get "/api/version"

    _(json["release"]).must_equal first
  end

  it "changes when a file in public/ changes" do
    get "/api/version"
    before = json["release"]
    path = Release::ROOT.join("release-test.txt")
    File.write(path, "new")
    begin
      get "/api/version"
      _(json["release"]).wont_equal before
    ensure
      FileUtils.rm_f(path)
    end

    get "/api/version"
    _(json["release"]).must_equal before
  end

  it "answers without a session" do
    sign_out!
    get "/api/version"

    _(last_response.status).must_equal 200
    _(json.keys.sort).must_equal %w[commit release version]
  end

  it "gives the version and commit the image was built with" do
    with_env("APP_VERSION" => "0.3.1", "APP_COMMIT" => "abcdef0") { get "/api/version" }

    _(json["version"]).must_equal "0.3.1"
    _(json["commit"]).must_equal "abcdef0"
  end

  it "is a dev build otherwise" do
    with_env("APP_VERSION" => nil) { get "/api/version" }

    _(json["version"]).must_equal "dev"
  end
end
