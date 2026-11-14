require_relative "../../lib/auth_app"

# Sessions and sign-in run inside Rage's stack, after Rage::FiberWrapper, so
# they run in the request's fiber and take their turn on the one database
# connection like the request itself (see lib/auth_app.rb). In config.ru, in
# front of Rage, they would run outside any fiber and could block the server
# while waiting for the connection.
# OIDC settings that don't add up stop the boot (lib/oidc.rb).
Oidc.settings
Oidc.configure_http!
OmniAuth.config.logger = Rage.logger

Rage.configure do
  config.middleware.use(*SessionCookie.middleware)
  config.middleware.use AuthApp
end
