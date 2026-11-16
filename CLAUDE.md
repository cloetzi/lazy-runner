# CLAUDE.md

Guidance for Claude (and other contributors) working in this repository.

## What this is

The Lazy Runner: a self-hosted strength coach for runners, signed in per user. A Ruby
JSON API (Rage + Sequel + SQLite) and a static PWA in `public/` served by
the same process. See README.md for the feature set, and `docs/` for how it
works: `architecture.md`, `data-model.md` (ER diagram; `test/lib/docs_test.rb`
fails when it misses a table or column, so update it with every migration),
`api.md` (conventions; the reference is generated at `/api/openapi`) and
`design.md`. Keep them short and current when a change touches what they say.

## Commands

```sh
bundle install
bundle exec rage s          # dev server on http://localhost:3000 (migrates and seeds on boot)
bundle exec rake test       # Ruby tests (Minitest)
bundle exec rubocop         # lint (.rubocop.yml); -a fixes what is safe to fix
npm test                    # player logic tests (node:test, no dependencies)
npm ci && npm run test:e2e  # browser smoke test (Playwright) against a server with a fresh database at BASE_URL
docker build --build-arg RUBY_VERSION="$(cat .ruby-version)" -t lazy-runner .
```

## Claude Code cloud sessions

`.claude/hooks/session-start.sh` (registered in `.claude/settings.json`) runs at
the start of every cloud session and does nothing elsewhere. It leaves `ruby`,
`bundle` and `node` on the PATH at the `.ruby-version` and `.node-version`
versions, with gems and `node_modules` installed and `LANG=C.UTF-8` (the
image defaults to US-ASCII), so the commands above run directly; no Docker per test run. How:

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

For the e2e test, start a server on a fresh database first, logging to a
file (the test reads the setup code there):
`rm -f storage/production.sqlite3* && SECURE_COOKIES=false bundle exec rage s -e production -p 3999 > /tmp/e2e.log 2>&1 &`
then `BASE_URL=http://localhost:3999 SERVER_LOG=/tmp/e2e.log npm run test:e2e`.

## Layout

- `app/controllers/api/` JSON endpoints, one controller per resource.
- `app/models/` Sequel models on a shared `Record` base (plugins, validation
  wording as the API gives it, `find!` raising `NotFound`), plus plain objects
  such as `PlayerPlan`, which flattens workouts into the ordered screens the
  player walks through. Queries are datasets: subsets and `dataset_module`
  methods on the model, `eager` for what a list reads. `Session` and
  `Routine` record every change to the plan themselves (`PlanChange.record!`,
  #258), with `PlanChange.because(reason)` and `quietly` around the calls;
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
- Data is per user (#175): the library and the equipment catalogue are
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
  (`{ error: { code, message, fields } }`) and the server's "today" (`TZ`,
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
  and km or mi the same way; beeps, vibration, lead-in and the RPE question
  on the device, read and written by `preferences.js`.
  The Calendar page (`calendar-page.js`, sheets in `calendar-sheets.js`, shared
  with Today) draws the server's sessions and activities (`/api/calendar`)
  with the outbox's queued changes laid over them (`withQueued` in
  `calendar.js`, `withQueuedActivities` in `activities.js`), so a change made
  offline shows at once. An agent's latest change to an item, and the
  sessions it moved away from a day or removed, show with their reason and a
  button that takes them back (`plan-changes.js`, sent at once). Activities keep what was sent (metres, seconds) and
  nothing derived; `activities.js` gives known sports their sprite icon.
  The Coach page (`coach-page.js`, sheets in `coach-sheets.js`, logic in
  `coach.js`) draws `/api/coach`: goals (only the user writes them; an
  agent's `proposed` ones wait for Accept or Dismiss), the newest status and
  focus, open concerns and the journal, under "Since you last looked"
  (`/api/coach/news`, `coach-news.js`): what agents did since the user marked
  it seen (`users.coach_seen_at`), which `/api/me` counts for the dot on the
  Coach tab (`showCoachNews` in `nav.js`). Its writes, and notes written on the
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

## Conventions

- **Tests use Minitest spec style with expectations**: `describe`/`it` and
  `_(value).must_equal expected`, `_ { ... }.must_raise Error`. Never `assert_*`,
  never RSpec.
- Versions have one source of truth each: Ruby in `.ruby-version` (read by the
  Gemfile, CI and the Docker build arg), Node in `.node-version`. Never repeat
  a version number elsewhere.
- Use the latest stable release of everything (Ruby, gems, Node, base images,
  GitHub Actions) unless there is a stated reason not to.
  Renovate (the hosted app, `renovate.json`) keeps them there: weekly grouped
  PRs as Conventional Commits, minor and patch ones squash-merged once CI is
  green; majors, new Ruby or Node minors and lock file maintenance left for
  review; a dependency dashboard issue. An older pin needs a `packageRules`
  entry saying why. Not covered: the vendored Swagger UI (by hand) and the
  Debian release in the session-start hook's fallback image.
- CI runs on GitHub-hosted runners (`ubuntu-latest`) and only tests and
  lints: Ruby, RuboCop, node and e2e as parallel jobs, toolchains from setup
  actions reading the version files, dependencies cached. The image is built only for a release
  (`.github/workflows/release.yml`). Keep branch builds lean.
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/):
  `type(scope): summary` with `feat`, `fix`, `perf`, `refactor`, `docs`,
  `test`, `ci`, `build` or `chore`, and `!` or a `BREAKING CHANGE:` footer for
  a breaking change. A squash merge's title is the commit, so PR titles follow
  it too. release-please reads them on main to keep a release PR open with the
  next version and changelog (`feat` bumps the minor version, `fix` and `perf`
  the patch, while below 1.0 a breaking change bumps the minor). It runs once
  CI passes on main; merging the release PR tags the release and publishes
  the image. The version is release-please's
  (`.release-please-manifest.json`, `version.txt`, `CHANGELOG.md`): never
  bump it by hand.
- Use `it` in short blocks rather than `_1`, and name the parameter in a
  block over more than one line.
- RuboCop (`.rubocop.yml`): its defaults with new cops on, all Metrics off,
  lines up to 140, and a frozen string literal comment in every Ruby file.
  CI fails on any offence and there is no todo file: fix it, or disable the
  cop on that line with `-- why`.
- Every API change gets a request test in `test/requests/`. Timing logic gets a
  unit test.
- Seeds are the source of truth for the library, examples for programs.
  Change exercises, equipment and examples in YAML, not in migrations. An
  example change reaches only later imports: users' copies are theirs. The
  loader never deletes a logged set: set logs carry their own exercise,
  planned exercise, block and target, and only lose the link to a step that
  leaves. An exercise dropped from the seeds with sets logged (or a step
  naming it) is retired, not deleted. Keep it that way.
- Rage specifics: requests run in fibers, and with Sequel's
  `fiber_concurrency` extension they take turns on the one connection: a
  fiber holds it for a whole transaction, so keep transactions short and
  never wait on another request inside one. The boot disconnects once it has
  migrated and seeded (see `config/initializers/database.rb`). Tests run
  fibers synchronously, key connections by thread so request fibers share the
  test's, and wrap each test in a transaction rolled back at the end, with the
  app's transactions as savepoints (see `test/test_helper.rb`).
- Sequel gotchas:
  - A plain `save` writes every column of the in-memory record, stale ones
    included; use `update`, `save_changes` or `update_columns` (no hooks or
    timestamps) unless writing the whole record is the point.
  - `Model#==` compares values, not ids; compare ids in tests.
  - `column_changed?` misses a JSON column changed in place; `changing?` sees it.
  - Aggregates come back untyped on SQLite (`MAX(date)` is a String) and need
    `.as(:name)` in `select_map`/`select_hash`.
  - Iterate a dataset you write to inside the loop with `.all.each`, not
    `.each`, which streams from an open statement.
  - A value that can't be typecast stays as given; `Record#after_validation`
    refuses it unless a validation named it first.
  - A model's `after_update` calls `super` first, or `column_previously_changed?`
    reads the save before.
- Animations: side-on figure facing right, angles in degrees (0 forward, 90
  down). Per-side exercises are authored for the left side (near limbs) and
  mirrored for the right. Accent the moving limb, highlight the target muscle,
  time rep-based moves to the step's tempo where there is one. Check new poses on
  the Exercises page in both colour schemes.
- Frontend: no frameworks or bundlers. Keep the player usable one-handed and
  readable from a distance; respect `prefers-color-scheme`.

## Keep it open-sourceable

No secrets, personal data, hostnames or homelab-specific values in the repo. No
copied third-party images or text: exercise cues are written fresh, and the
animations are original. Deployment configuration lives elsewhere.

## Workflow

- Work is tracked as GitHub issues under the v1 milestone, one per slice. PRs
  reference their issue with `Closes #N`; keep the issue current if scope changes.
- The v1 spec is the source of truth for scope; out-of-scope ideas go into new
  issues rather than the current PR.
- Before a PR merges, run the code-review skill on it, triage the findings,
  fix the real ones and push, then review again. At most two rounds: fix
  what the second review finds and merge, unless it finds something
  significant (a security hole, data loss, a design question the user should
  decide). Then the PR goes to the user with a list of what the second
  review pointed out. Merge only with CI green.
