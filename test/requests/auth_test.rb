require "test_helper"

describe "accounts and sign-in" do
  include RequestHelpers

  def sign_in_as(username, password)
    post_json "/api/auth/login", username:, password:
  end

  describe "setting up the install" do
    # A fresh install: the test user goes too, with everything of theirs.
    before do
      @signed_out = true
      User.dataset.delete
    end
    after { SetupCode.consume! }

    it "says it needs its owner while there are no users" do
      get "/api/me"

      _(last_response.status).must_equal 401
      _(json["setup_required"]).must_equal true
      _(json["error"]["code"]).must_equal "unauthorized"
    end

    it "makes the owner with the setup code from the log, and signs them in" do
      code = SetupCode.generate!
      post_json "/api/auth/create-account", setup_code: code.downcase, username: "Runner", password: RequestHelpers::TEST_PASSWORD

      _(last_response.status).must_equal 200, last_response.body
      owner = User.first!
      _(owner.username).must_equal "Runner"
      _(owner.owner).must_equal true
      _(SetupCode.active?).must_equal false
      get "/api/me"
      _(json["user"]).must_equal({ "id" => owner.id, "username" => "Runner", "owner" => true, "password_change_required" => false, "welcomed" => false })
      # Nothing of their own yet: they pick their gear and examples in the app.
      Current.set(user: owner) do
        _([Program.count, Workout.count, UserEquipment.count]).must_equal [0, 0, 0]
      end
    end

    it "refuses a wrong setup code" do
      SetupCode.generate!
      post_json "/api/auth/create-account", setup_code: "AAAAA-AAAAA", username: "runner", password: RequestHelpers::TEST_PASSWORD

      _(last_response.status).must_equal 403
      _(json["error"]["code"]).must_equal "forbidden"
      _(json["error"]["fields"]).must_equal({ "setup_code" => [AuthApp::WRONG_SETUP_CODE] })
      _(User.count).must_equal 0
      _(SetupCode.active?).must_equal true
    end

    it "refuses a setup code that was used, or never made" do
      post_json "/api/auth/create-account", setup_code: "", username: "runner", password: RequestHelpers::TEST_PASSWORD

      _(last_response.status).must_equal 403
      _(User.count).must_equal 0
    end

    it "refuses a second owner, code or not" do
      create_user("first")
      code = SetupCode.generate!
      post_json "/api/auth/create-account", setup_code: code, username: "second", password: RequestHelpers::TEST_PASSWORD

      _(last_response.status).must_equal 404
      _(json["error"]["message"]).must_match(/already has an owner/)
      _(User.count).must_equal 1
    end

    it "checks the username and the password" do
      code = SetupCode.generate!
      post_json "/api/auth/create-account", setup_code: code, username: "no spaces", password: "short"

      _(last_response.status).must_equal 422
      _(json["error"]["code"]).must_equal "invalid"
      _(json["error"]["fields"]).must_equal({ "username" => ["Use letters, digits, dots, dashes and underscores only"] })
      post_json "/api/auth/create-account", setup_code: code, username: "runner", password: "short"
      _(json["error"]["fields"].keys).must_equal ["password"]
      _(User.count).must_equal 0
    end

    it "makes no owner when the code is right but the user signed in already" do
      sign_in(create_user("first"))
      post_json "/api/auth/create-account", setup_code: SetupCode.generate!, username: "second", password: RequestHelpers::TEST_PASSWORD

      _(last_response.status).must_equal 409
      _(User.count).must_equal 1
    end
  end

  describe "signing in" do
    before do
      @signed_out = true
      @runner = user
    end

    it "signs in whatever the username's case, and says who" do
      sign_in_as "RUNNER", RequestHelpers::TEST_PASSWORD

      _(last_response.status).must_equal 200
      get "/api/me"
      _(json["user"]["id"]).must_equal @runner.id
    end

    it "keeps the session in an HttpOnly, SameSite cookie" do
      sign_in_as "runner", RequestHelpers::TEST_PASSWORD

      cookie = last_response.headers["set-cookie"]
      _(cookie).must_match(/\A#{Auth::SessionCookie.cookie_name}=/)
      _(cookie).must_match(/httponly/i)
      _(cookie).must_match(/samesite=lax/i)
    end

    it "gives one answer for an unknown user and a wrong password" do
      sign_in_as "nobody", RequestHelpers::TEST_PASSWORD
      unknown = [last_response.status, json]
      sign_in_as "runner", "wrong password"
      wrong = [last_response.status, json]

      _(unknown).must_equal [401, { "error" => { "code" => "unauthorized", "message" => "Wrong username or password" } }]
      _(wrong).must_equal unknown
      get "/api/me"
      _(last_response.status).must_equal 401
    end

    it "locks the account after ten wrong passwords, then unlocks it on its own" do
      10.times { sign_in_as "runner", "wrong password" }
      Auth::Throttles::SIGN_INS.reset! # a minute later
      sign_in_as "runner", RequestHelpers::TEST_PASSWORD

      _(last_response.status).must_equal 401
      _(json).must_equal({ "error" => { "code" => "unauthorized", "message" => "Wrong username or password" } })
      DB[:account_lockouts].where(id: @runner.id).update(deadline: Time.now.utc - 60)
      sign_in_as "runner", RequestHelpers::TEST_PASSWORD
      _(last_response.status).must_equal 200
    end

    it "refuses signing in twice; sign out first" do
      sign_in_as "runner", RequestHelpers::TEST_PASSWORD
      sign_in_as "runner", RequestHelpers::TEST_PASSWORD

      _(last_response.status).must_equal 409
      _(json["error"]["code"]).must_equal "conflict"
    end

    # Each username counts apart, so attempts with made-up ones don't keep
    # a real user out, and past a budget they stop costing a hash (#207).
    it "lets the real user in through a stream of made-up usernames" do
      hashes = 0
      counter = Module.new { define_method(:verify_password) { |*args, **opts| hashes += 1; super(*args, **opts) } }
      Argon2::Password.singleton_class.prepend(counter)
      70.times { sign_in_as "made-up-#{it}", "wrong password" }

      _(last_response.status).must_equal 401
      _(json).must_equal({ "error" => { "code" => "unauthorized", "message" => "Wrong username or password" } })
      _(hashes).must_equal 60
      sign_in_as "runner", RequestHelpers::TEST_PASSWORD
      _(last_response.status).must_equal 200, last_response.body
    ensure
      counter.send(:remove_method, :verify_password)
    end

    it "slows down a run of attempts on one username" do
      10.times { sign_in_as "runner", "wrong password" }
      sign_in_as "runner", "wrong password"

      _(last_response.status).must_equal 429
      _(json["error"]["code"]).must_equal "too_many_requests"
      _(last_response.headers["retry-after"].to_i).must_be :>, 0
    end
  end

  describe "the API without a session" do
    before { @signed_out = true }

    it "answers 401 everywhere but the public routes" do
      get "/api/today"
      _(last_response.status).must_equal 401
      _(json["error"]["code"]).must_equal "unauthorized"

      post_json "/api/workouts", title: "Mine"
      _(last_response.status).must_equal 401

      get "/api/version"
      _(last_response.status).must_equal 200
    end
  end

  # The PWA's queued changes name the user they were made by: one queued
  # before someone else signed in on the device never lands in their
  # account (#205).
  describe "a queued change for another user" do
    before { sign_in(user) }

    it "is refused while someone else is signed in" do
      header "X-Lazy-Runner-User", (user.id + 1).to_s
      patch_json "/api/settings", unit: "kg"

      _(last_response.status).must_equal 409
      _(json["error"]["code"]).must_equal "user_mismatch"
      _(Setting.unit).must_equal "lb"
    end

    it "goes through for the user it was made by, and reads aren't checked" do
      header "X-Lazy-Runner-User", user.id.to_s
      patch_json "/api/settings", unit: "kg"
      _(last_response.status).must_equal 200

      header "X-Lazy-Runner-User", "someone else"
      get "/api/settings"
      _(last_response.status).must_equal 200
    end

    it "is refused with an API token of someone else too" do
      sign_out!
      header "X-Lazy-Runner-User", (user.id + 1).to_s
      header "Authorization", "Bearer #{ApiToken.issue!(user, "Script", scope: "api").last}"
      patch_json "/api/settings", unit: "kg"

      _(last_response.status).must_equal 409
    end
  end

  describe "writes from another site" do
    before { sign_in(user) }

    it "refuses a form posted from a sibling subdomain" do
      @fetch_site = "same-site"
      patch "/api/settings", "unit=kg", "CONTENT_TYPE" => "application/x-www-form-urlencoded", "IODINE_HAS_BODY" => true

      _(last_response.status).must_equal 403
      _(json["error"]["code"]).must_equal "forbidden"
      _(Setting.unit).must_equal "lb"
    end

    it "goes by Origin when there is no Sec-Fetch-Site" do
      @fetch_site = nil
      header "Origin", "http://elsewhere.example"
      patch_json "/api/settings", unit: "kg"
      _(last_response.status).must_equal 403

      header "Origin", nil
      patch_json "/api/settings", unit: "kg"
      _(last_response.status).must_equal 403

      header "Origin", "http://example.org"
      patch_json "/api/settings", unit: "kg"
      _(last_response.status).must_equal 200
    end

    it "lets reads through from anywhere" do
      @fetch_site = "cross-site"
      get "/api/settings"

      _(last_response.status).must_equal 200
    end

    it "refuses a body that isn't JSON, even from this app" do
      patch "/api/settings", "unit=kg", "CONTENT_TYPE" => "text/plain", "IODINE_HAS_BODY" => true

      _(last_response.status).must_equal 403
      _(json["error"]["message"]).must_equal "Send the body as application/json"
      _(Setting.unit).must_equal "lb"
    end
  end

  describe "signing out" do
    it "ends the session and tells the browser to drop its cache" do
      sign_in(user)
      post_json "/api/auth/logout"

      _(last_response.status).must_equal 200
      _(last_response.headers["clear-site-data"]).must_equal '"cache"'
      _(DB[:account_active_session_keys].where(account_id: user.id).count).must_equal 0
      get "/api/today"
      _(last_response.status).must_equal 401
    end
  end

  describe "changing the password" do
    before { sign_in(user) }

    it "needs the current password" do
      post_json "/api/auth/change-password", password: "wrong password", new_password: "a new password"

      _(last_response.status).must_equal 401
      _(json["error"]["fields"].keys).must_equal ["password"]
    end

    it "slows down guessing the current password" do
      10.times { post_json "/api/auth/change-password", password: "wrong password", new_password: "a new password" }
      post_json "/api/auth/change-password", password: RequestHelpers::TEST_PASSWORD, new_password: "a new password"

      _(last_response.status).must_equal 429
    end

    it "changes it, signs out the other devices and revokes the API tokens" do
      ApiToken.issue!(user, "Made by whoever knew the old password")
      DB[:account_active_session_keys].insert(account_id: user.id, session_id: "another device")
      post_json "/api/auth/change-password", password: RequestHelpers::TEST_PASSWORD, new_password: "a new password"

      _(last_response.status).must_equal 200, last_response.body
      _(DB[:account_active_session_keys].where(account_id: user.id).select_map(:session_id)).wont_include "another device"
      _(ApiToken.where(user_id: user.id).count).must_equal 0
      get "/api/today"
      _(last_response.status).must_equal 200
      sign_out!
      sign_in(user, password: "a new password")
    end
  end

  describe "signed-in devices" do
    before { sign_in(user) }

    it "lists the devices, this one marked" do
      DB[:account_active_session_keys].insert(account_id: user.id, session_id: "elsewhere", device: "Firefox on Android",
                                              last_use: Time.now.utc - 3600)
      get "/api/account/devices"

      _(last_response.status).must_equal 200
      _(json["devices"].map { it["current"] }).must_equal [true, false]
      _(json["devices"].last["device"]).must_equal "Firefox on Android"
    end

    it "shows nobody else's devices" do
      someone = create_user("someone")
      DB[:account_active_session_keys].insert(account_id: someone.id, session_id: "theirs")
      get "/api/account/devices"

      _(json["devices"].size).must_equal 1
    end

    it "signs out another device" do
      id = DB[:account_active_session_keys].insert(account_id: user.id, session_id: "elsewhere")
      delete "/api/account/devices/#{id}"

      _(last_response.status).must_equal 204
      _(DB[:account_active_session_keys].where(id:).count).must_equal 0
      get "/api/today"
      _(last_response.status).must_equal 200
    end

    it "can't sign out someone else's device" do
      someone = create_user("someone")
      id = DB[:account_active_session_keys].insert(account_id: someone.id, session_id: "theirs")
      delete "/api/account/devices/#{id}"

      _(last_response.status).must_equal 404
      _(DB[:account_active_session_keys].where(id:).count).must_equal 1
    end

    it "signs out every other device, and keeps this one" do
      DB[:account_active_session_keys].insert(account_id: user.id, session_id: "elsewhere")
      delete "/api/account/devices"

      _(last_response.status).must_equal 204
      _(DB[:account_active_session_keys].where(account_id: user.id).count).must_equal 1
      get "/api/today"
      _(last_response.status).must_equal 200
    end

    it "writes a device's last use at most hourly" do
      get "/api/today"
      long_ago = Time.utc(2026, 10, 1)
      DB[:account_active_session_keys].where(account_id: user.id).update(last_use: long_ago)
      get "/api/today"

      _(last_response.status).must_equal 200
      _(DB[:account_active_session_keys].where(account_id: user.id).get(:last_use)).must_equal long_ago
    end

    it "answers /api/me as signed out once this device is signed out elsewhere" do
      DB[:account_active_session_keys].where(account_id: user.id).delete
      get "/api/me"

      _(last_response.status).must_equal 401
      _(json["setup_required"]).must_equal false
    end

    it "signs this device out when its own row goes" do
      DB[:account_active_session_keys].where(account_id: user.id).delete
      get "/api/today"

      _(last_response.status).must_equal 401
      _(json["error"]["message"]).must_equal "This device has been signed out"
      @signed_in = false
      @signed_out = true
      sign_in(user)
    end
  end
end
