require "test_helper"

describe "static files" do
  include RequestHelpers

  it "serves the app at the root" do
    get "/"

    _(last_response.status).must_equal 200
    _(last_response.content_type).must_include "text/html"
    _(last_response.body).must_include "The Lazy Runner"
  end

  it "asks browsers to check for a new version on every load" do
    get "/js/app.js"

    _(last_response.status).must_equal 200
    _(last_response.headers["cache-control"]).must_equal "no-cache"
    _(last_response.headers["last-modified"]).wont_be_nil
  end

  # Nothing from another origin runs where the session is, and no other
  # site frames the app (#206).
  it "lets only the app's own scripts run, and no other site frame it" do
    get "/"

    policy = last_response.headers["content-security-policy"]
    _(policy).must_include "script-src 'self'"
    _(policy).must_include "frame-ancestors 'none'"
    _(last_response.headers["x-content-type-options"]).must_equal "nosniff"
  end

  it "answers 304 when the file has not changed" do
    get "/css/app.css"
    get "/css/app.css", {}, "HTTP_IF_MODIFIED_SINCE" => last_response.headers["last-modified"]

    _(last_response.status).must_equal 304
  end

  it "serves the web app manifest" do
    get "/manifest.webmanifest"

    _(last_response.status).must_equal 200
    _(last_response.content_type).must_include "application/manifest+json"
    _(JSON.parse(last_response.body)["start_url"]).must_equal "/"
  end

  it "serves the service worker from the root, so it covers the whole app" do
    get "/sw.js"

    _(last_response.status).must_equal 200
    _(last_response.content_type).must_include "javascript"
    _(last_response.headers["cache-control"]).must_equal "no-cache"
  end

  it "links the manifest and registers the service worker on every page" do
    %w[/ /library.html /equipment.html].each do |page|
      get page

      _(last_response.body).must_include %(<link rel="manifest" href="/manifest.webmanifest">)
      _(last_response.body).must_include %(src="/js/pwa.js")
    end
  end

  it "leaves the API alone" do
    get "/api/today"

    _(last_response.status).must_equal 200
    _(last_response.content_type).must_include "application/json"
  end

  it "does not serve files outside public" do
    get "/../Gemfile"

    _(last_response.body).wont_include "rubygems"
  end
end
