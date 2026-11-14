source "https://rubygems.org"

ruby file: ".ruby-version"

gem "rage-rb", "~> 1.28"
gem "rack"

gem "sqlite3"
gem "sequel", "~> 5.110"
# Core extensions (blank?, present?, index_by, squish) and the time zone
# behind TZ; the data layer is Sequel's.
gem "activesupport"
# Time zone data for TZ, so the image needs no system tzdata.
gem "tzinfo-data"
# The MCP server at /mcp, for an assistant acting as a personal trainer.
gem "mcp", "~> 1.8"
# Accounts and sign-in: Rodauth on the app's own Sequel connection, run as
# Roda middleware inside Rage (lib/auth_app.rb), with Argon2 password hashes.
gem "roda", "~> 3.109"
gem "rodauth", "~> 2.49"
gem "argon2", "~> 2.3"
# Signing in with an OpenID Connect provider (OIDC_ISSUER), next to passwords.
gem "rodauth-omniauth", "~> 0.6"
gem "omniauth_openid_connect", "~> 0.8"

group :test do
  gem "minitest"
  gem "rack-test"
end
