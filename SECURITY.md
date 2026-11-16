# Security

## Reporting a problem

Please report a vulnerability privately, through **Report a vulnerability**
on the repository's Security tab (GitHub's private vulnerability reporting),
rather than in a public issue. Say what you found, how to reproduce it, and
which version or commit you tried. You will get an answer as soon as the
maintainer can give one; this is a project kept in spare time, so there is no
fixed response time. Fixes go into the next release, and only the latest
release is supported.

## What the app is built for

The Lazy Runner is meant for a household or a small group on a network you
trust, such as a home network or a VPN. **Do not expose it to the internet.**

- **A trusted network.** Nothing in it is hardened for a hostile one: there is
  no rate limit beyond the sign-in throttles, and the endpoints a
  self-hosted app needs (`/api/version`, `/api/openapi`, the sign-in pages)
  answer anyone who can reach them.
- **TLS from a reverse proxy.** The app speaks plain HTTP. Put it behind a
  reverse proxy that terminates TLS; the session cookie is `Secure` unless
  `SECURE_COOKIES=false` is set, which is for plain HTTP on a local network
  only.
- **People who sign in are trusted to a point.** Each user's data is their
  own: every query on a user's tables is scoped to the signed-in user, and a
  test fails any request that reads one without that scope. The owner can
  invite and remove users and reset their passwords.
- **An assistant acts through an API token.** A token is for the MCP server
  only unless REST access is ticked when it is made. What an agent may do is
  enforced in the models: it proposes goals rather than setting them, and it
  leaves the user's history and the user's own notes alone. Every change it
  makes to the plan is recorded with its reason and can be taken back.

The browser side has a strict Content-Security-Policy (`script-src 'self'`,
nothing from other origins), every write needs a same-origin request with a
JSON body, and API answers carry `Cache-Control: no-store`.

## Accepted risks

These are known and accepted for an app on a trusted network. Each is a
decision, not an oversight; an issue is welcome if you think one should change.

- **API tokens don't expire.** They last until revoked in Settings, or until
  the owner resets the user's password.
- **No re-authentication for sensitive actions**, such as linking an OpenID
  Connect identity, resetting another user's password or removing a user. An
  unlocked device that is signed in as the owner is the owner.
- **Lockout can be used to annoy.** Anyone who can reach the sign-in page can
  lock an account by guessing wrong passwords. The owner lifts a lockout with
  a password reset (`rake users:reset_password`).
- **No general write limit for agents over MCP**, only 20 coach notes a day
  and 5 open goal proposals. A looping agent can fill the calendar; every such
  change is recorded and can be taken back, and revoking its token stops it.
- **An MCP tool that crashes logs its call**, which may put the user's text in
  the server log. Keep the log as private as the database.
- **`/api/version` and `/api/openapi` are public**, so a client can check the
  server before signing in.
- **`style-src 'unsafe-inline'`** stays in the Content-Security-Policy for
  inline styles; scripts are `'self'` only.
