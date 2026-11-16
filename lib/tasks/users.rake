# frozen_string_literal: true

require "io/console"

# Helpers for the tasks below, kept off the top level.
module UserTasks
  module_function

  # "username: That username is taken. Try another.": the API's messages
  # say what is wrong but not which field, which a shell needs.
  def field_messages(error)
    fields = error.field_errors || {}
    fields.empty? ? error.message : fields.map { |field, message| "#{field}: #{message}" }.join("; ")
  end

  # The owner's first password, from PASSWORD for a scripted install, else
  # asked for without echo.
  def owner_password
    ENV["PASSWORD"].presence || begin
      print "Password: "
      $stdin.noecho(&:gets).to_s.chomp.tap { puts }
    end
  end
end

# Accounts from a shell on the server, for whoever runs the install: making
# the owner without the setup code (scripted installs), finding a username
# and getting a user back in, the owner included, since there is no email
# to reset a password by (the owner resets others' in Settings, Users).
namespace :users do
  desc "Create the owner account: rake users:create_owner USERNAME=name [PASSWORD=...]"
  task :create_owner do
    abort "This install already has users; sign in instead." unless User.empty?

    username = ENV.fetch("USERNAME") { abort "Set USERNAME." }
    AuthApp.rodauth.create_account(login: username, password: UserTasks.owner_password)
    SetupCode.consume!
    puts "Created the owner account #{username}."
  rescue Rodauth::InternalRequestError => error
    abort "Not created: #{UserTasks.field_messages(error)}"
  end

  desc "List the users, owners first: rake users:list"
  task :list do
    users = User.order(Sequel.desc(:owner), :username).all
    abort "No users yet: create the owner with the setup code from the server's log." if users.empty?

    users.each do |user|
      notes = [("owner" if user.owner), ("must choose a new password" if user.password_change_required)].compact
      puts [user.username, *notes].join("  ")
    end
  end

  desc "Give a user a temporary password to sign in with, sign out their devices and revoke their API tokens: " \
       "rake users:reset_password USERNAME=name"
  task :reset_password do
    # Taking the new password from the command line would leave it in the
    # shell's history; the temporary one is changed at the next sign-in. A
    # PASSWORD in the environment (a container's, for create_owner) is left be.
    warn "PASSWORD is ignored: this gives a temporary password instead." if ENV["PASSWORD"].present?

    username = ENV.fetch("USERNAME") { abort "Set USERNAME." }
    user = User.first(username:) or abort "No user #{username}; rake users:list names them."

    temporary = user.temporary_password!
    puts <<~TEXT
      #{user.username} can sign in with the temporary password

        #{temporary}

      and must choose a new one then. Their devices are signed out, their API tokens
      revoked, their sign-ins with the OIDC provider unlinked and any lockout lifted.
    TEXT
  rescue Rodauth::InternalRequestError => error
    abort "Not changed: #{error.message}"
  end
end
