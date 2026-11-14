# The version of the running app and the commit it was built from. The
# release workflow bakes both into the image (APP_VERSION from release-please,
# APP_COMMIT, see the Dockerfile); any other build is "dev", with the commit of
# the git checkout it runs from when there is one, read once.
module AppVersion
  DEV = "dev"
  SHA = /\A\h{7,40}\z/

  def self.git_commit
    sha = IO.popen(["git", "-C", Rage.root.to_s, "rev-parse", "--short=7", "HEAD"], err: File::NULL, &:read).strip
    sha if sha.match?(SHA)
  rescue SystemCallError
    nil
  end
  private_class_method :git_commit

  def self.version
    ENV["APP_VERSION"].to_s.strip.delete_prefix("v").then { it.empty? ? DEV : it }
  end

  def self.commit
    from_env = ENV["APP_COMMIT"].to_s.strip.downcase
    return from_env if from_env.match?(SHA)

    @git_commit = git_commit unless defined?(@git_commit)
    @git_commit
  end
end
