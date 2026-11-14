require "io/console"

# Accounts from the command line, for the owner's own account: making it
# without the setup code (tests, scripted installs) and resetting its
# password, since there is no email to reset it by (the owner resets
# others' in Settings, Users). PASSWORD may come from the environment;
# otherwise it is asked for without echo.
namespace :users do
  desc "Create the owner account: rake users:create_owner USERNAME=name [PASSWORD=...]"
  task :create_owner do
    abort "This install already has users; sign in instead." unless User.empty?

    username = ENV.fetch("USERNAME") { abort "Set USERNAME." }
    AuthApp.rodauth.create_account(login: username, password: password_from_env_or_prompt)
    SetupCode.consume!
    puts "Created the owner account #{username}."
  rescue Rodauth::InternalRequestError => e
    abort "Not created: #{e.message}"
  end

  desc "Set a user's password, sign out their devices and revoke their API tokens: rake users:reset_password USERNAME=name [PASSWORD=...]"
  task :reset_password do
    username = ENV.fetch("USERNAME") { abort "Set USERNAME." }
    user = User.first(username:) or abort "No user #{username}."

    user.set_password!(password_from_env_or_prompt)
    puts "Set the password of #{user.username}, signed out their devices and revoked their API tokens."
  rescue Rodauth::InternalRequestError => e
    abort "Not changed: #{e.message}"
  end

  def password_from_env_or_prompt
    ENV["PASSWORD"].presence || begin
      print "Password: "
      $stdin.noecho(&:gets).to_s.chomp.tap { puts }
    end
  end
end
