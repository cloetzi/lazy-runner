# CLAUDE.md

Guidance for Claude working in this repository. The commands, conventions
and rules for everyone are in CONTRIBUTING.md, imported here:

@CONTRIBUTING.md

## What this is

The Lazy Runner: a self-hosted strength coach for runners, signed in per user. A Ruby
JSON API (Rage + Sequel + SQLite) and a static PWA in `public/` served by
the same process. See README.md for the feature set, and `docs/` for how it
works: `architecture.md`, `data-model.md` (ER diagram; `test/lib/docs_test.rb`
fails when it misses a table or column, so update it with every migration),
`api.md` (conventions; the reference is generated at `/api/openapi`) and
`design.md`. Keep them short and current when a change touches what they say.

## Claude Code cloud sessions

`.claude/hooks/session-start.sh` (registered in `.claude/settings.json`) runs at
the start of every cloud session and does nothing elsewhere. It leaves `ruby`,
`bundle` and `node` on the PATH at the `.ruby-version` and `.node-version`
versions, with gems and `node_modules` installed and `LANG=C.UTF-8` (the
image defaults to US-ASCII), so the commands in CONTRIBUTING.md run directly, the e2e test
included; no Docker per test run. How:

- Ruby is built from the ruby-lang.org source (checksum from its `index.txt`)
  into `/opt/ruby-<version>`. Where the environment blocks ruby-lang.org, the
  hook starts dockerd once, copies Ruby out of `ruby:<version>-slim-bookworm`
  (via `mirror.gcr.io` when Docker Hub rate-limits), links
  `/usr/local/lib/ruby` to it and stops dockerd again.
- Node comes from nodejs.org into `/opt/node<major>`.
- When Playwright wants another Chromium revision than the preinstalled one,
  the hook downloads it into `/opt/pw-browsers-lazy-runner` and points
  `PLAYWRIGHT_BROWSERS_PATH` there. Where the environment blocks the browser
  hosts, it aliases the installed Chromium under the expected revision instead.
- Every step is skipped when its result is there, so only a fresh container
  pays for the build; a warm start takes about 1 s.

## Layout

- `app/controllers/api/` JSON endpoints, one controller per resource.
- `app/models/` Sequel models on a shared `Record` base (plugins, validation
  wording as the API gives it, `find!` raising `NotFound`), plus plain objects
  such as `PlayerPlan`, which flattens workouts into the ordered screens the
  player walks through. Queries are datasets: subsets and `dataset_module`
  methods on the model, `eager` for what a list reads. `Session` and
  `Routine` record every change to the plan themselves (`PlanChange.record!`),
  with `PlanChange.because(reason)` and `quietly` around the calls;
  undo runs the same model code the other way.
- `lib/auth_app.rb` accounts and sign-in: Rodauth (JSON only) as Roda
  middleware inside Rage (`config/initializers/sign_in.rb`), with Roda's
  session cookie. It answers `/api/auth/*` and gates the rest of `/api`;
  the gate, CSRF, tokens, throttles, the OIDC callback and the cookie are
  each a file in `lib/auth/`. What a route needs is its row in
  `Auth::Access::RULES` (`lib/auth/access.rb`): a new resource under `/api`
  needs one (`test/requests/access_test.rb`). A `Bearer` API token with REST
  access (`ApiToken#rest?`) stands in for the session (a token is MCP-only
  by default); a write needs `Sec-Fetch-Site: same-origin` (else a matching
  `Origin`) and a JSON body, and a request without a session is a 401 but
  `/api/version`, `/api/openapi` and `/api/me`. The user's id reaches
  `ApplicationController` in `env["lazy_runner.user_id"]`, which sets
  `Current.user`. The owner invites everyone else (`Invite`, Settings →
  Users) and can reset a password to a temporary one, which leaves the user
  only `/api/me` and changing it; from a shell, `rake users:reset_password`
  does that for anyone, the owner included (`lib/tasks/users.rake`). With `OIDC_ISSUER` set (`lib/oidc.rb`),
  an OpenID Connect provider signs users in too (`/api/auth/oidc`,
  `user_identities`; tests run it against `test/fake_oidc_provider.rb`).
  Request tests sign in as `user` (the
  owner) on their first request
  (`test/test_helper.rb`; `sign_out!`, `sign_in`, `create_user`), and
  every write in the PWA goes through `send` in `api.js` or the outbox.
  What a token may do is the models' to say, not the controllers' or the
  tools': with `Current.agent_name` set, `Record::AgentSigned` makes what it
  writes `llm`, and `Record.user_only!` refuses what only the user does
  (goals, erasing history, the user's notes) with `Record::UserOnly`, a 403
  on the API and a tool error over MCP. `lib/api_boundary.rb` puts
  `no-store`/`nosniff` on every `/api` and `/mcp` answer and turns away a
  JSON body that isn't an object; `ApplicationController` answers a bug as
  `server_error` and has typed readers (`string_param`, `integer_param`,
  `id_param`, `boolean_param`, `hash_param`) for anything that reaches a
  query or a `dig`; `test/requests/wrong_types_test.rb` sends every
  documented field the wrong types.
- Data is per user: the library and the equipment catalogue are
  shared, everything else has a `user_id` (or a parent with one). A
  per-user model calls `per_user` (`Record`), and then every query on it
  is the signed-in user's (`Current.user!`, raising with nobody signed in):
  write `Session.find!(id)`, and another user's id is a 404. Opt out only
  on purpose, with `Model.everyone` or `Model.of(user_id)`; to work on
  another user's records, run as them (`Current.set(user:)`), since saving
  or deleting one as someone else raises `Current::Mismatch`. Links between
  two of a user's tables are associations keyed by `[:user_id, ...]`,
  matching the composite foreign keys. The exception is an optional link
  that goes null when its target is deleted (a coach note's activity or
  session, a goal's `replaces`): a composite key would null `user_id` too,
  so it is a plain key and the model checks the target is the same user's.
  A coach note's `reply_to_id` is plain too, so it could be added without
  copying the table; the model checks it the same way.
  Every test runs as `user`
  (`Current.user` is set; `Current.set(user: other) { ... }` for another),
  and a query a request makes on a per-user table without `user_id` fails
  it (`UserScopeTripwire`).
- `app/controllers/application_controller.rb` the one error shape
  (`{ error: { code, message, fields } }`, one `rescue_from Refusal` for what
  the models refuse) and the request's today (`Current.today`: the device's
  `today` within a day of the server's, else the server's in `TZ`,
  `config/initializers/time_zone.rb`). Each action's comment is its OpenAPI
  description (Rage's `@description`, `@param`, `@request`, `@response` tags;
  shared parts in `config/openapi_components.yml`), served at `/api/openapi`.
  A request test checks every route is described, so a new action needs its tags,
  and every request test checks its responses against the schemas there, so a
  new response field needs one too (`test/openapi_schema.rb`).
- `app/mcp/` the MCP server at `/mcp` (`TrainerMcp`, the official `mcp` gem,
  stateless Streamable HTTP): read and write tools for a trainer agent, one
  class each, calling the same model code as the API (what it writes is marked
  `llm` and signed with the token's name, `Current.agent_name`), and the brief in `trainer_mcp/brief.md`. API tokens only
  (`TrainerMcp::TokenVerifier`); a tool's `answer` that takes `user:` gets
  the token's user, and the models see them as `Current.user` while it runs.
  `MCP_ALLOWED_HOSTS` widens the DNS rebinding guard.
  A new tool goes in `TrainerMcp::TOOLS` with a test in `test/requests/mcp_test.rb`.
- `lib/seed_loader.rb` loads `db/seeds/*.yml` (the equipment catalogue and
  the exercise library, shared) idempotently on every boot. Equipment comes
  first; exercises list what they need by its slug. Programs are not seeded:
  `db/examples/<slug>.yml` are example programs a user imports
  (`app/models/example.rb`, `/api/examples`, MCP `import_example`) into
  ordinary programs of theirs, weights snapped to their gear. A new account
  owns nothing and has no workouts. Tests run as `user`, who owns every item
  and has every example imported (`TestUsers.equip!`); `create_user(name,
  bare: true)` makes one with nothing.
- `lib/static_files.rb` serves `public/` with `Cache-Control: no-cache`, so a
  plain reload picks up a new version (Iodine's own file server caches for an hour),
  and a Content-Security-Policy: no inline scripts and nothing from other origins.
  `lib/api_reference.rb` serves the reference page with Swagger UI from
  `lib/api_reference/swagger-ui`, an exact release copied from its npm package
  (`package.json` there is its version; update all its files together).
- `lib/database.rb` opens SQLite (one connection, WAL, foreign keys,
  IMMEDIATE transactions) and runs `db/migrate/` (Sequel timestamp migrations)
  on boot. The first migration is the 0.1.0 schema as ActiveRecord left it;
  a database ActiveRecord kept is taken over by rewriting its
  `schema_migrations` (`Database.adopt_active_record!`), and one older than
  0.1.0 is refused. New migrations are plain Sequel ones. On SQLite, Sequel
  changes a default or adds a constraint by copying the table, and the copy
  loses its CHECK constraints and partial indexes: make them again in the same
  migration (`test/lib/database_test.rb` fails otherwise).
- `public/` the frontend: plain ES modules, no build step.
  The logic modules (listed in `docs/architecture.md`) are kept free of the
  DOM and tested in `test/js`. Writes go through the outbox so they
  survive a lost connection; the running session is kept in localStorage.
  `nav.js` draws the navigation on every page from `routes.js`: a bottom tab
  bar on phones with the rest under More, a rail from 44rem, a sidebar from
  60rem; a detail's Back goes where it was opened from (`backFor`).
  Views on the home page have a URL hash, and the session screens and the
  editor hide the navigation (`body[data-focus]`). The workout editor
  (`#edit/<id>`, `#edit/new`), with Cancel and Save in its own header, keeps its draft
  in `builder.js` and draws it in `editor.js`, saving the whole structure in
  one request. Example programs are imported from Workouts ("From an
  example", `#examples`, `example-list.js`), and gear the user doesn't own is
  marked wherever gear is named (`gear.js`). Settings live on the Settings page: lb or kg on the server
  (`/api/settings`, sent through the outbox, with a copy in localStorage),
  and km or mi the same way; beeps, When muted (Safari's audio session, `beeper.js`), vibration, lead-in and the RPE question
  on the device, read and written by `preferences.js`.
  The Calendar page (`calendar-page.js`, sheets in `calendar-sheets.js`, shared
  with Today) draws the server's sessions and activities (`/api/calendar`)
  with the outbox's queued changes laid over them (`withQueued` in
  `calendar.js`, `withQueuedActivities` in `activities.js`), so a change made
  offline shows at once. An agent's latest change to an item, and the
  sessions it moved away from a day or removed, show with their reason and a
  button that takes them back (`plan-changes.js`, sent at once). Activities keep what was sent (metres, seconds) and
  nothing derived; `activities.js` gives known sports their sprite icon.
  Check-ins (last night, how the day felt) are a card on Today, rows on
  the Calendar's day and tiles on Coach's week (`check-in-sheets.js`, logic
  in `check-ins.js`), written through the outbox.
  The Coach page (`coach-page.js`, sheets in `coach-sheets.js`, logic in
  `coach.js`) draws `/api/coach` as four kinds of thing, each with its own
  look (`docs/design.md`): a band for "Since you last looked"
  (`/api/coach/news`, `coach-news.js`: what agents did since the user marked
  it seen, `users.coach_seen_at`, which `/api/me` counts for the dot on the
  Coach tab, `showCoachNews` in `nav.js`) and an agent's `proposed` goals,
  which wait there for Accept or Dismiss; the newest status and focus and
  the open concerns as one card; goals (only the user writes them) and the
  week in outlined panels; the journal as a timeline. Its writes, and notes written on the
  Calendar, go straight through `send` rather than the outbox.
- `public/sw.js` the service worker: the shell cached as one unit per release
  (`app/models/release.rb`), the API network first with a capped cache as the
  offline fallback, read through `getJson` in `api.js` (see "Offline and
  releases" in `docs/architecture.md`). Its `SHELL` list must name every file
  in `public/` (a node test checks it).
- `public/js/skeleton.json` the animation skeleton, shared by the renderer and
  the Ruby check in `app/models/animation.rb`. `figure.js` documents the keyframe
  format; `figure-view.js` draws it as SVG; `library.html` previews every exercise.
- `config/coach.yml` the weight stepper's increments (the app suggests no
  weights: changing one is the user's or the coach agent's).
  `app/models/weights.rb` converts and compares weights: each exercise keeps
  them in the unit of the user's gear for it (`user_equipment.unit`, else the
  lb/kg setting) and each step in that of the gear it is done with
  (`Step#gear_unit`), converted at the API boundary. The stepper itself is
  `public/js/weights.js`: fixed-weight equipment steps through the owned
  weights (`allowed_weights`), anything else by the increments.
- `test/` Minitest (`test/requests`, `test/models`, `test/lib`); `test/js` node tests;
  `test/e2e` a Playwright run through the real server, offline finish included
  (CI runs it with the Playwright version in `package-lock.json`).
  `test/lib/boot_test.rb` runs the production boot in its own process.

## Workflow

- Work is tracked as GitHub issues, one per slice. PRs reference their issue
  with `Closes #N`; keep the issue current if scope changes.
- The v1 spec is the source of truth for scope; out-of-scope ideas go into new
  issues rather than the current PR.
- Before a PR merges, run the code-review skill on it, triage the findings,
  fix the real ones and push, then review again. At most two rounds: fix
  what the second review finds and merge, unless it finds something
  significant (a security hole, data loss, a design question the user should
  decide). Then the PR goes to the user with a list of what the second
  review pointed out. Merge only with CI green.
