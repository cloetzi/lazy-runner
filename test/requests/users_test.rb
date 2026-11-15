require "test_helper"

describe "users and invites" do
  include RequestHelpers

  PASSWORD = RequestHelpers::TEST_PASSWORD

  def invite!
    post_json "/api/invites"
    _(last_response.status).must_equal 201, last_response.body
    json["token"]
  end

  # Joins on another device, with no session.
  def join(token, username = "newcomer", password: PASSWORD)
    sign_out!
    post_json "/api/auth/create-account", invite: token, username:, password:
  end

  def personal_counts(id)
    UserScopeTripwire::TABLES.to_h { [it, DB[it.to_sym].where(user_id: id).count] }
  end

  before { _(user.owner).must_equal true }

  describe "invites" do
    it "makes a one-time link, kept as a digest, that lists without its token" do
      token = invite!

      _(json["path"]).must_equal "/signin.html#invite/#{token}"
      _(token).must_match(/\A[A-Za-z0-9_-]{43}\z/)
      _(Invite.first!.digest).must_equal Digest::SHA256.hexdigest(token)
      _(Time.parse(json["invite"]["expires_at"])).must_be_close_to Time.now + 7 * 86_400, 60

      get "/api/invites"
      _(json["invites"].map { it["id"] }).must_equal [Invite.first!.id]
      _(last_response.body).wont_include token
    end

    it "lets someone join with it, as a user with nothing of their own, and signs them in" do
      token = invite!
      join(token)

      _(last_response.status).must_equal 200, last_response.body
      get "/api/me"
      newcomer = User.first!(username: "newcomer")
      _(json["user"]).must_equal({ "id" => newcomer.id, "username" => "newcomer", "owner" => false,
                                   "password_change_required" => false, "welcomed" => false })
      _(personal_counts(newcomer.id).values.sum).must_equal 0
      _(Invite.count).must_equal 0
    end

    it "says in plain words when the username is taken, whatever its case" do
      create_user("newcomer")
      token = invite!
      join(token, "NewComer")

      _(last_response.status).must_equal 422
      _(json["error"]["fields"]).must_equal({ "username" => ["That username is taken. Try another."] })
      _(Invite.count).must_equal 1
    end

    it "works once" do
      token = invite!
      join(token)
      post_json "/api/auth/logout"
      join(token, "second")

      _(last_response.status).must_equal 404
      _(json["error"]["fields"]).must_equal({ "invite" => [AuthApp::INVITE_GONE] })
      _(User.where(username: "second").count).must_equal 0
    end

    it "stops working after seven days" do
      token = invite!
      travel_to(Time.now + 7 * 86_400 + 1) do
        join(token)
        _(last_response.status).must_equal 404
      end

      travel_to(Time.now + 8 * 86_400) do
        @signed_out = false
        sign_in(user)
        get "/api/invites"
        _(json["invites"]).must_equal []
      end
    end

    it "stops working once revoked" do
      token = invite!
      delete "/api/invites/#{json["invite"]["id"]}"
      _(last_response.status).must_equal 204

      join(token)
      _(last_response.status).must_equal 404
    end

    it "stays unused when the sign-up fails" do
      token = invite!
      join(token, "no spaces")
      _(last_response.status).must_equal 422
      join(token, "runner")
      _(last_response.status).must_equal 422
      _(json["error"]["fields"].keys).must_equal ["username"]

      join(token)
      _(last_response.status).must_equal 200
    end

    it "takes no made-up token, nor a setup code in its place" do
      invite!
      join("A" * 43)
      _(last_response.status).must_equal 404

      sign_out!
      post_json "/api/auth/create-account", setup_code: SetupCode.generate!, username: "newcomer", password: PASSWORD
      _(last_response.status).must_equal 404
      _(User.where(username: "newcomer").count).must_equal 0
    ensure
      SetupCode.consume!
    end

    it "takes an empty invite field as none, for the owner's setup" do
      User.dataset.delete
      sign_out!
      post_json "/api/auth/create-account", setup_code: SetupCode.generate!, invite: "", username: "first", password: PASSWORD

      _(last_response.status).must_equal 200, last_response.body
      _(User.first!(username: "first").owner).must_equal true
    ensure
      SetupCode.consume!
    end

    it "is refused to someone signed in" do
      token = invite!
      post_json "/api/auth/create-account", invite: token, username: "newcomer", password: PASSWORD

      _(last_response.status).must_equal 409
      _(Invite.count).must_equal 1
    end

    it "goes through the sign-in throttle" do
      sign_out!
      10.times { post_json "/api/auth/create-account", invite: "A" * 43, username: "newcomer", password: PASSWORD }
      post_json "/api/auth/create-account", invite: "A" * 43, username: "newcomer", password: PASSWORD

      _(last_response.status).must_equal 429
    end
  end

  describe "for anyone but the owner" do
    before { sign_in(create_user("someone")) }

    it "is a 403, and changes nothing" do
      get "/api/users"
      _(last_response.status).must_equal 403
      _(json["error"]["code"]).must_equal "forbidden"
      get "/api/invites"
      _(last_response.status).must_equal 403
      post_json "/api/invites"
      _(last_response.status).must_equal 403
      post_json "/api/users/#{TestUsers::RUNNER_ID}/password"
      _(last_response.status).must_equal 403
      delete "/api/users/#{TestUsers::RUNNER_ID}"
      _(last_response.status).must_equal 403
      _([Invite.count, User.where(id: TestUsers::RUNNER_ID).count]).must_equal [0, 1]
    end
  end

  it "takes no API token, not even the owner's" do
    _, secret = ApiToken.issue!(user, "Script")
    @signed_out = true
    @fetch_site = nil
    header "Authorization", "Bearer #{secret}"
    get "/api/users"
    _(last_response.status).must_equal 403
    _(json["error"]["message"]).must_equal AuthApp::TOKEN_REFUSED
    post_json "/api/invites"
    _(last_response.status).must_equal 403
    _(Invite.count).must_equal 0
  end

  it "lists the users, oldest first" do
    someone = create_user("someone")
    get "/api/users"

    _(last_response.status).must_equal 200
    _(json["users"].map { it["username"] }).must_equal %w[runner someone]
    _(json["users"].last.slice("id", "owner")).must_equal({ "id" => someone.id, "owner" => false })
  end

  describe "resetting a password" do
    before { @someone = create_user("someone") }

    it "gives a temporary password, and signs out their devices and revokes their tokens" do
      ApiToken.issue!(@someone, "Theirs")
      DB[:account_active_session_keys].insert(account_id: @someone.id, session_id: "their phone")
      DB[:account_login_failures].insert(id: @someone.id, number: 10)
      DB[:account_lockouts].insert(id: @someone.id, key: "k", deadline: Time.now.utc + 600)
      post_json "/api/users/#{@someone.id}/password"

      _(last_response.status).must_equal 200
      temporary = json["password"]
      _(temporary).must_match(/\A[A-Z0-9]{4}(-[A-Z0-9]{4}){3}\z/)
      _(DB[:account_active_session_keys].where(account_id: @someone.id).count).must_equal 0
      _(ApiToken.of(@someone.id).count).must_equal 0
      _(DB[:account_lockouts].where(id: @someone.id).count).must_equal 0
      _(@someone.refresh.password_change_required).must_equal true

      sign_out!
      post_json "/api/auth/login", username: "someone", password: PASSWORD
      _(last_response.status).must_equal 401
      sign_in(@someone, password: temporary)
    end

    it "lets them in only to choose a new password, which signs out their other devices" do
      post_json "/api/users/#{@someone.id}/password"
      temporary = json["password"]
      sign_out!
      sign_in(@someone, password: temporary)

      get "/api/me"
      _(json["user"]["password_change_required"]).must_equal true
      get "/api/today"
      _(last_response.status).must_equal 401
      _(json["error"]["code"]).must_equal "password_change_required"

      DB[:account_active_session_keys].insert(account_id: @someone.id, session_id: "signed in with it too")
      post_json "/api/auth/change-password", password: temporary, new_password: "their own password", sign_out_others: false
      _(last_response.status).must_equal 200, last_response.body
      _(DB[:account_active_session_keys].where(account_id: @someone.id).select_map(:session_id)).wont_include "signed in with it too"
      get "/api/today"
      _(last_response.status).must_equal 200
      get "/api/me"
      _(json["user"]["password_change_required"]).must_equal false
    end

    it "keeps the temporary password out of API tokens' reach" do
      post_json "/api/users/#{@someone.id}/password"
      _, secret = ApiToken.issue!(@someone.refresh, "Made after")
      sign_out!
      @fetch_site = nil
      header "Authorization", "Bearer #{secret}"
      get "/api/today"

      # Turned away as a token that doesn't count, and not noted as used.
      _(last_response.status).must_equal 401
      _(last_response.headers["www-authenticate"]).must_include "invalid_token"
      _(ApiToken.of(@someone.id).get(:last_used_at)).must_be_nil
    end

    it "lifts a reset's temporary password with rake's, which is the user's own" do
      post_json "/api/users/#{@someone.id}/password"
      @someone.refresh.set_password!("chosen at the console")

      _(@someone.refresh.password_change_required).must_equal false
      sign_out!
      sign_in(@someone, password: "chosen at the console")
      get "/api/today"
      _(last_response.status).must_equal 200
    end

    it "is not for your own" do
      post_json "/api/users/#{user.id}/password"

      _(last_response.status).must_equal 409
      _(json["error"]["message"]).must_match(/under Account/)
    end

    it "is a 404 for nobody" do
      post_json "/api/users/0/password"
      _(last_response.status).must_equal 404
    end
  end

  describe "removing a user" do
    it "removes them and everything of theirs, and nobody else's" do
      someone = create_user("someone")
      ApiToken.issue!(someone, "Theirs")
      DB[:account_active_session_keys].insert(account_id: someone.id, session_id: "their phone")
      Current.set(user: someone) do
        Setting.current
        session = session_on(Time.zone.today, "in_progress")
        log_all(session, "goblet-squat")
        finish(session, "too_easy")
        Activity.log!({ date: Time.zone.today.to_s, sport: "run" }, today: Time.zone.today)
        ExerciseWeight.find_or_new(exercise_id: exercise("goblet-squat").id).set(value: 40, unit: "lb").save_changes
        Goal.add!(title: "Run a 10k")
        CoachNote.create(kind: "note", body: "Easy week", author_kind: "user")
        Routine.plan!({ sport: "run", weekdays: [1] }).confirm!(Time.zone.today.next_occurring(:monday))
        UserIdentity.create(issuer: "https://id.example.test", subject: "someone")
      end
      _(personal_counts(someone.id).select { |_, count| count.zero? }.keys).must_equal []
      mine = personal_counts(user.id)
      delete "/api/users/#{someone.id}"

      _(last_response.status).must_equal 204
      _(User.where(id: someone.id).count).must_equal 0
      _(personal_counts(someone.id).values.sum).must_equal 0
      _(DB[:account_active_session_keys].where(account_id: someone.id).count).must_equal 0
      _(personal_counts(user.id)).must_equal mine
    end

    it "signs them out at once" do
      someone = create_user("someone")
      sign_in(someone)
      Current.set(user: User.with_pk(TestUsers::RUNNER_ID)) { someone.remove! }
      get "/api/today"

      _(last_response.status).must_equal 401
    end

    it "won't remove you" do
      delete "/api/users/#{user.id}"

      _(last_response.status).must_equal 409
      _(json["error"]["message"]).must_equal "You can't remove yourself"
      _(User.where(id: user.id).count).must_equal 1
    end
  end

  describe "changing your own password" do
    before { sign_in(user) }

    it "can keep your other devices and tokens" do
      ApiToken.issue!(user, "Trainer")
      DB[:account_active_session_keys].insert(account_id: user.id, session_id: "another device")
      post_json "/api/auth/change-password", password: PASSWORD, new_password: "a new password", sign_out_others: "off"

      _(last_response.status).must_equal 200, last_response.body
      _(DB[:account_active_session_keys].where(account_id: user.id).select_map(:session_id)).must_include "another device"
      _(ApiToken.of(user.id).count).must_equal 1
    end
  end

  it "notes the welcome screen as done" do
    get "/api/me"
    _(json["user"]["welcomed"]).must_equal false

    post_json "/api/account/welcome"
    _(last_response.status).must_equal 204
    get "/api/me"
    _(json["user"]["welcomed"]).must_equal true
  end
end
