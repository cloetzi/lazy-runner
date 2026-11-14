require "test_helper"

describe "API tokens" do
  include RequestHelpers

  def with_token(secret)
    @signed_out = true
    @fetch_site = nil
    header "Authorization", "Bearer #{secret}"
  end

  describe "managing them from Settings" do
    it "makes a token, shows it once, and lists it without it" do
      post_json "/api/account/tokens", name: "  Trainer agent "

      _(last_response.status).must_equal 201
      secret = json["secret"]
      _(secret).must_match(/\Alr_[A-Za-z0-9_-]{43}\z/)
      _(json["token"]["name"]).must_equal "Trainer agent"
      _(ApiToken.first!.digest).must_equal Digest::SHA256.hexdigest(secret)

      get "/api/account/tokens"
      _(json["tokens"].map { it["name"] }).must_equal ["Trainer agent"]
      _(last_response.body).wont_include secret
      _(json["tokens"].first["last_used_at"]).must_be_nil
    end

    it "needs a name, as text" do
      post_json "/api/account/tokens", name: " "
      _(last_response.status).must_equal 422
      _(json["error"]["fields"].keys).must_equal ["name"]

      post_json "/api/account/tokens", name: { "a" => 1 }
      _(last_response.status).must_equal 422
      _(ApiToken.count).must_equal 0
    end

    it "revokes a token, which stops working at once" do
      token, secret = ApiToken.issue!(user, "Laptop")
      delete "/api/account/tokens/#{token.id}"
      _(last_response.status).must_equal 204

      with_token(secret)
      get "/api/today"
      _(last_response.status).must_equal 401
    end

    it "shows and revokes only your own" do
      someone = create_user("someone")
      theirs, = ApiToken.issue!(someone, "Theirs")
      get "/api/account/tokens"
      _(json["tokens"]).must_equal []

      delete "/api/account/tokens/#{theirs.id}"
      _(last_response.status).must_equal 404
      _(ApiToken.everyone.with_pk(theirs.id)).wont_be_nil
    end
  end

  describe "using one on the API" do
    let(:secret) { ApiToken.issue!(user, "Script").last }

    it "acts as its user, with no session and no CSRF headers" do
      with_token(secret)
      get "/api/me"
      _(json["user"]["id"]).must_equal user.id

      patch_json "/api/settings", unit: "kg"
      _(last_response.status).must_equal 200
      _(Setting.unit).must_equal "kg"
      _(last_response.headers["set-cookie"]).must_be_nil
    end

    it "signs what an agent plans with the token's name, and nothing of yours" do
      with_token(secret)
      post_json "/api/sessions", workout_id: workout("cycle-1-workout-1").id, date: "2030-11-05", status: "planned", created_by: "llm"
      _(last_response.status).must_equal 201, last_response.body
      _(json.values_at("created_by", "agent_name")).must_equal ["llm", "Script"]

      post_json "/api/sessions", workout_id: workout("cycle-1-workout-1").id, date: "2030-11-06", status: "planned"
      _(json.values_at("created_by", "agent_name")).must_equal ["manual", nil]
    end

    it "turns away an unknown token, saying how to send one" do
      with_token("lr_#{"x" * 43}")
      get "/api/today"

      _(last_response.status).must_equal 401
      _(last_response.headers["www-authenticate"]).must_include "invalid_token"
    end

    it "turns away a header that isn't text" do
      with_token("lr_\xFF".dup.force_encoding("UTF-8"))
      get "/api/today"

      _(last_response.status).must_equal 401
    end

    it "answers /api/me as signed out for a bad token" do
      user
      with_token("lr_#{"x" * 43}")
      get "/api/me"

      _(last_response.status).must_equal 401
      _(json["setup_required"]).must_equal false
    end

    it "turns away a malformed token rather than falling back to the session" do
      sign_in(user)
      header "Authorization", "Bearer"
      get "/api/today"

      _(last_response.status).must_equal 401
    end

    it "leaves a scheme that only starts like Bearer to the session" do
      sign_in(user)
      header "Authorization", "Bearer-Proxy xyz"
      get "/api/today"

      _(last_response.status).must_equal 200
    end

    it "doesn't count a refused account call as a use" do
      with_token(secret)
      get "/api/account/tokens"

      _(last_response.status).must_equal 403
      _(ApiToken.first!.last_used_at).must_be_nil
    end

    it "leaves another scheme to the session, as a proxy's Basic sign-in passes through" do
      sign_in(user)
      header "Authorization", "Basic dXNlcjpwYXNz"
      get "/api/today"

      _(last_response.status).must_equal 200
    end

    it "can't manage the account: no new tokens, no devices" do
      with_token(secret)
      post_json "/api/account/tokens", name: "Another"
      _(last_response.status).must_equal 403
      _(json["error"]["message"]).must_equal AuthApp::TOKEN_REFUSED

      get "/api/account/devices"
      _(last_response.status).must_equal 403
      _(ApiToken.count).must_equal 1
    end

    it "still needs a session for the sign-in routes" do
      with_token(secret)
      post_json "/api/auth/change-password", password: RequestHelpers::TEST_PASSWORD, new_password: "a new password"

      _(last_response.status).wont_equal 200
    end

    it "goes when its user does" do
      secret
      DB[:users].where(id: user.id).delete
      with_token(secret)
      get "/api/today"

      _(last_response.status).must_equal 401
    end
  end
end
