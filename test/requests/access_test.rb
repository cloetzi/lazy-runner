# frozen_string_literal: true

require "test_helper"

# The access table (lib/auth/access.rb) against config/routes.rb, and the
# gate (lib/auth/gate.rb) answering every route as its row says.
describe Auth::Access do
  include RequestHelpers

  def routes = Rage.__router.routes.map { it[:path] }.uniq
  # Rodauth's routes under /api/auth are not Rage routes.
  def rows_without_routes = %w[auth]

  # The GET routes that take no id, the ones a request can be made to as is.
  def plain_gets
    Rage.__router.routes.select { it[:method] == "GET" && it[:meta][:controller_class] && !it[:path].include?(":") }
      .map { it[:path] }.uniq.select { Auth::Access.for(it) }
  end

  it "has a row for every route under /api" do
    api = routes.select { it == "/api" || it.start_with?("/api/") }
    _(api).wont_be_empty

    api.each do |path|
      _(Auth::Access::RULES).must_include Auth::Access.segment(path), "#{path} has no row in Auth::Access::RULES"
    end
  end

  it "has a route for every row" do
    segments = routes.filter_map { Auth::Access.segment(it) }
    (Auth::Access::RULES.keys - rows_without_routes).each do |segment|
      _(segments).must_include segment, "/api/#{segment} has a row but no route"
    end
  end

  it "names a known requirement in every row" do
    _(Auth::Access::RULES.values - Auth::Access::REQUIREMENTS).must_be_empty
  end

  it "stands aside outside /api, and needs a session or token for an unknown path under it" do
    _(Auth::Access.for("/mcp")).must_be_nil
    _(Auth::Access.for("/")).must_be_nil
    _(Auth::Access.for("/apix")).must_be_nil
    _(Auth::Access.for("/api")).must_equal :signed_in
    _(Auth::Access.for("/api/")).must_equal :signed_in
    _(Auth::Access.for("/api/nothing/here")).must_equal :signed_in
    _(Auth::Access.for("/api/auth/login")).must_equal :sign_in
    _(Auth::Access.for("/api/openapi/json")).must_equal :public
    _(Auth::Access.for(AuthApp::PREFIX)).must_equal :sign_in
  end

  # Rage routes /api/me/ to /api/me too, but only /api/me itself answers
  # signed out: anything longer needs a session or a REST token.
  it "takes /api/me signed out at its own path only" do
    _(Auth::Access.for("/api/me")).must_equal :optional
    _(Auth::Access.for("/api/me/")).must_equal :signed_in
    _(Auth::Access.for("/api/me/x")).must_equal :signed_in

    # Sent past the check against the API description, which describes
    # /api/me's own answer, not the gate's.
    @signed_out = true
    custom_request "GET", "/api/me/"
    _(last_response.status).must_equal 401
    _(json).wont_include "setup_required"

    _, secret = ApiToken.issue!(user, "Coach")
    @fetch_site = nil
    header "Authorization", "Bearer #{secret}"
    get "/api/me"
    _(last_response.status).must_equal 401
    _(json["setup_required"]).must_equal false
    custom_request "GET", "/api/me/"
    _(last_response.status).must_equal 403
    _(json["error"]["message"]).must_equal Auth::Token::MCP_ONLY
  end

  it "answers every plain GET route signed out as its row says" do
    @signed_out = true
    plain_gets.each do |path|
      get path
      case Auth::Access.for(path)
      when :public then _(last_response.status).must_equal 200, path
      # /api/me says signed out itself, with whether to set up.
      when :optional
        _(last_response.status).must_equal 401, path
        _(json["setup_required"]).must_equal false, path
      else
        _(last_response.status).must_equal 401, path
        _(json["error"]["code"]).must_equal "unauthorized", path
      end
    end
  end

  it "answers every plain GET route with a REST token as its row says" do
    _, secret = ApiToken.issue!(user, "Script", scope: "api")
    @signed_out = true
    @fetch_site = nil
    header "Authorization", "Bearer #{secret}"

    plain_gets.each do |path|
      get path
      case Auth::Access.for(path)
      when :browser
        _(last_response.status).must_equal 403, path
        _(json["error"]["message"]).must_equal Auth::Token::REFUSED, path
      when :optional then _(json["user"]["id"]).must_equal user.id, path
      # Let through: what the route answers (a GET may need a parameter).
      else _([401, 403]).wont_include last_response.status, path
      end
    end
  end

  # The public routes and Rodauth's don't read a token at all: a request
  # with one is answered as one without.
  it "reads no token on the public and sign-in routes" do
    _, secret = ApiToken.issue!(user, "Coach")
    @signed_out = true
    @fetch_site = nil
    header "Authorization", "Bearer #{secret}"

    get "/api/version"
    _(last_response.status).must_equal 200
    get "/api/openapi/json", {}, { "rack.input" => StringIO.new }
    _(last_response.status).must_equal 200

    header "Authorization", "Bearer lr_not-a-token"
    get "/api/version"
    _(last_response.status).must_equal 200
    # Not let through as the token's: a write here has the CSRF check.
    post_json "/api/auth/login", username: user.username, password: "wrong password"
    _(last_response.status).must_equal 403
    _(json["error"]["message"]).must_equal Auth::Csrf::REFUSED
  end
end
