require "test_helper"
require "rake"

# lib/tasks/users.rake: getting back in from a shell, the owner included.
describe "rake users" do
  include RequestHelpers

  before do
    @rake = Rake.application
    Rake.application = Rake::Application.new
    load Rage.root.join("lib/tasks/users.rake").to_s
  end

  after { Rake.application = @rake }

  # What the task printed, to standard output and standard error.
  def run_task(name, env = {})
    with_env({ "USERNAME" => nil, "PASSWORD" => nil }.merge(env)) do
      capture_io { Rake::Task[name].invoke }.join
    end
  end

  describe "users:reset_password" do
    it "gives the owner a temporary password, which signs in only to choose a new one" do
      _, secret = ApiToken.issue!(user, "script")
      get "/api/me"
      output = run_task("users:reset_password", "USERNAME" => user.username)
      temporary = output[/\b[A-Z0-9]{4}(-[A-Z0-9]{4}){3}\b/]

      _(temporary).wont_be_nil
      # This device, its API token and the old password are out.
      get "/api/me"
      _(json["user"]).must_be_nil
      _(ApiToken.of(user.id).count).must_equal 0
      post_json "/api/auth/login", username: user.username, password: RequestHelpers::TEST_PASSWORD
      _(last_response.status).must_equal 401
      header "Authorization", "Bearer #{secret}"
      get "/api/workouts"
      _(last_response.status).must_equal 401
      header "Authorization", nil

      post_json "/api/auth/login", username: user.username, password: temporary
      _(last_response.status).must_equal 200
      get "/api/me"
      _(json.dig("user", "password_change_required")).must_equal true
    end

    it "takes no password from the environment, which the shell would keep" do
      output = run_task("users:reset_password", "USERNAME" => user.username, "PASSWORD" => "a new password")
      sign_out!
      post_json "/api/auth/login", username: user.username, password: "a new password"

      _(output).must_include "PASSWORD is ignored"
      _(last_response.status).must_equal 401
    end

    it "names no one it doesn't know" do
      _ { run_task("users:reset_password", "USERNAME" => "nobody") }.must_raise SystemExit
    end
  end

  describe "making the owner" do
    before do
      @signed_out = true
      User.dataset.delete
    end
    after { SetupCode.consume! }

    it "names the field it refuses" do
      error = nil
      with_env("USERNAME" => "no spaces", "PASSWORD" => RequestHelpers::TEST_PASSWORD) do
        _, error = capture_io { _ { Rake::Task["users:create_owner"].invoke }.must_raise SystemExit }
      end

      _(error).must_include "Not created: username: Use letters, digits, dots, dashes and underscores only"
      _(User.count).must_equal 0
    end
  end

  it "lists the users, owners first" do
    create_user("aaron", bare: true)
    _(run_task("users:list").lines.map(&:split)).must_equal [[user.username, "owner"], ["aaron"]]
  end
end
