# Someone who signs in. Rodauth (lib/auth_app.rb) creates users and checks
# their passwords, which it keeps in its own account_password_hashes table;
# this model only reads them. The owner made the install with the setup
# code from the server's log; everyone else joined by an owner's invite.
class User < Record
  # A change the owner can't make: removing themselves or the last owner,
  # or resetting their own password (they change it under Account).
  class Refused < StandardError; end

  # A temporary password: 16 characters from the setup code's alphabet, in
  # groups of four (about 78 bits).
  TEMPORARY_LENGTH = 16

  dataset_module do
    def owners = where(owner: true)
  end

  # Gives the user a temporary password, shown to the owner this once, which
  # they must change when they next sign in. Signs out their devices,
  # revokes their API tokens and lifts a lockout: whoever had the old
  # password is out, and the user can get back in.
  def reset_password!
    raise Refused, "Change your own password under Account" if id == Current.user!.id

    temporary_password!
  end

  # The same from a shell (`rake users:reset_password`), for anyone, the
  # owner included: how an owner who lost their password gets back in.
  def temporary_password!
    temporary = SetupCode.random(TEMPORARY_LENGTH).scan(/.{4}/).join("-")
    set_password!(temporary, temporary: true)
    temporary
  end

  # Sets the password from code (a reset, by the owner or from a shell): no
  # current password needed. As any change made
  # from code, it signs out every device and revokes the API tokens
  # (lib/auth_app.rb, after_change_password); it also lifts a lockout, so
  # the user can get in. `temporary`: they must change it first.
  def set_password!(password, temporary: false)
    db.transaction do
      AuthApp.rodauth.change_password(account_id: id, new_password: password)
      this.update(password_change_required: temporary)
      db[:account_lockouts].where(id:).delete
      db[:account_login_failures].where(id:).delete
    end
    # As the database has it now, without marking the column changed.
    values[:password_change_required] = temporary
  end

  # Removes the user, and with them everything of theirs (every per-user
  # table cascades from users), their devices and API tokens included.
  def remove!
    raise Refused, "You can't remove yourself" if id == Current.user!.id

    db.transaction do
      raise Refused, "#{username} is the last owner" if owner && User.owners.count == 1

      destroy
    end
  end

  def welcomed! = this.update(welcomed_at: Time.now)

  # Marks what agents did up to `time` (never later than now) as seen on
  # Coach; an earlier time than the one marked already changes nothing.
  def coach_seen!(time = Time.now)
    time = [time, Time.now].min
    this.where(Sequel.|({ coach_seen_at: nil }, Sequel[:coach_seen_at] < time)).update(coach_seen_at: time)
    refresh
  end

  # Whether they can sign in with a password: a hash in Rodauth's table
  # (someone who joined with the OIDC provider may have none).
  def password? = !db[:account_password_hashes].where(id:).empty?

  def as_json(*)
    { id:, username:, owner:, password_change_required:, welcomed: !welcomed_at.nil? }
  end

  # As the owner's list of users shows them.
  def admin_json = as_json.merge(created_at:)
end
