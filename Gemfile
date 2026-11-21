# frozen_string_literal: true

source "https://rubygems.org"

# .ruby-version pins the exact Ruby for CI, the image and the session hook.
# An exact pin here would fail a frozen bundle install whenever the running
# Ruby and Gemfile.lock's RUBY VERSION are a patch apart.
ruby "~> 4.0"

gem "rack"
gem "rage-rb", "~> 1.28"

gem "sequel", "~> 5.110"
gem "sqlite3"
# Core extensions (blank?, present?, index_by, squish) and the time zone
# behind TZ; the data layer is Sequel's.
gem "activesupport"
# Time zone data for TZ, so the image needs no system tzdata.
gem "tzinfo-data"
# The MCP server at /mcp, for an assistant acting as a personal trainer.
gem "mcp", "~> 1.8"
# Accounts and sign-in: Rodauth on the app's own Sequel connection, run as
# Roda middleware inside Rage (lib/auth_app.rb), with Argon2 password hashes.
gem "argon2", "~> 2.3"
gem "roda", "~> 3.109"
gem "rodauth", "~> 2.49"
# Signing in with an OpenID Connect provider (OIDC_ISSUER), next to passwords.
gem "omniauth_openid_connect", "~> 0.8"
gem "rodauth-omniauth", "~> 0.6"

group :test do
  gem "minitest"
  gem "rack-test"
  # COVERAGE=1 bundle exec rake test: line and branch coverage in coverage/.
  gem "simplecov", require: false
end

# Linting (.rubocop.yml): bundle exec rubocop. Known advisories for the
# locked gems: bundle exec bundle-audit check --update.
group :development do
  gem "bundler-audit", require: false
  gem "rubocop", require: false
  gem "rubocop-minitest", require: false
  gem "rubocop-performance", require: false
  gem "rubocop-rake", require: false
  gem "rubocop-sequel", require: false
end
