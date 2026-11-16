# frozen_string_literal: true

require_relative "../../lib/auth_app"
require_relative "../../lib/api_boundary"

# Sessions and sign-in run inside Rage's stack, after Rage::FiberWrapper, so
# they run in the request's fiber and take their turn on the one database
# connection like the request itself (see lib/auth_app.rb). In config.ru, in
# front of Rage, they would run outside any fiber and could block the server
# while waiting for the connection.
# OIDC settings that don't add up stop the boot (lib/oidc.rb).
Oidc.settings
Oidc.configure_http!
OmniAuth.config.logger = Rage.logger

# ApiBoundary first: its headers go on every answer under /api and /mcp,
# AuthApp's included, and a JSON body that isn't an object is turned away
# before anything reads it.
Rage.configure do
  config.middleware.use ApiBoundary::Headers
  config.middleware.use ApiBoundary::JsonBody
  config.middleware.use(*Auth::SessionCookie.middleware)
  config.middleware.use AuthApp
end
