# Contributing

Thank you for taking an interest in the Lazy Runner.

- **Issues are welcome**: a bug, a question, an idea. Say what you did, what
  you expected and what happened, with the version (Settings, About) and the
  device and browser for anything on screen.
- **Pull requests by arrangement.** Open an issue first and agree on the
  change before writing it; a pull request that arrives unannounced may be
  closed without review, however good it is. A typo fix needs no issue.
- **Security problems** go privately: see [SECURITY.md](SECURITY.md).

There is no contributor agreement. What you contribute is under the
project's licence (Apache-2.0 with the Commons Clause, see
[LICENSE](LICENSE)), as section 5 of the Apache licence says.

How the app works is in [docs/](docs/) and the README. `CLAUDE.md` is the
same guidance for an AI coding assistant, with a map of the code that is
handy for people too.

## Commands

```sh
bundle install
bundle exec rage s          # dev server on http://localhost:3000 (migrates and seeds on boot)
bundle exec rake test       # Ruby tests (Minitest); COVERAGE=1 for coverage/ (CI reports it)
bundle exec rubocop         # lint (.rubocop.yml); -a fixes what is safe to fix
bundle exec bundle-audit check --update  # locked gems against known advisories
npm test                    # player logic tests (node:test, no dependencies)
npm ci && npm run test:e2e  # browser smoke test (Playwright) against a server with a fresh database at BASE_URL
docker build --build-arg RUBY_VERSION="$(cat .ruby-version)" -t lazy-runner .
```

For the e2e test, start a server on a fresh database first, logging to a
file (the test reads the setup code there):
`rm -f storage/production.sqlite3* && SECURE_COOKIES=false bundle exec rage s -e production -p 3999 > /tmp/e2e.log 2>&1 &`
then `BASE_URL=http://localhost:3999 SERVER_LOG=/tmp/e2e.log npm run test:e2e`.

## Conventions

- **Tests use Minitest spec style with expectations**: `describe`/`it` and
  `_(value).must_equal expected`, `_ { ... }.must_raise Error`. Never `assert_*`,
  never RSpec. An expected hash goes in braces,
  `must_equal({ "a" => 1 })`: without them Minitest 6.1 takes it for
  keywords and compares with nil.
- Versions have one source of truth each: Ruby in `.ruby-version` (read by
  CI, the Docker build arg and the session hook), Node in `.node-version`.
  Never repeat a version number elsewhere. The Gemfile asks only for Ruby
  `~> 4.0`, so a patch bump can't fail a frozen `bundle install`; Renovate
  moves it with a new major.
- Use the latest stable release of everything (Ruby, gems, Node, base images,
  GitHub Actions) unless there is a stated reason not to.
  Renovate (the hosted app, `renovate.json`) keeps them there: weekly grouped
  PRs as Conventional Commits, minor and patch ones squash-merged once CI is
  green; majors, new Ruby or Node minors and lock file maintenance left for
  review; a dependency dashboard issue. Security updates (GitHub's and
  OSV's advisories) open at once. Ruby opens at any time rather than on
  Monday, with `ruby/setup-ruby` in the same PR so it knows the new version,
  and a Ruby patch skips the 3-day release age. An older pin needs a `packageRules`
  entry saying why. Not covered: the vendored Swagger UI (by hand) and the
  Debian release in the session-start hook's fallback image.
- CI runs on GitHub-hosted runners (`ubuntu-latest`) and only tests and
  lints: Ruby, RuboCop with the gem audit, node and e2e as parallel jobs, toolchains from setup
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
- Frontend: no frameworks or bundlers. Markup only in html`` templates
  (`public/js/html.js`), which escape what they are given; never build it
  by adding strings. Keep the player usable one-handed and
  readable from a distance; respect `prefers-color-scheme`.

## Keep it publishable


No secrets, personal data, hostnames or homelab-specific values in the repo. No
copied third-party images or text: exercise cues are written fresh, and the
animations are original. Deployment configuration lives elsewhere.


## Licence of what is in the repository

Everything here, the exercise text and the animations included, is under the
project's licence, except `lib/api_reference/swagger-ui`, which is Swagger UI
under its own Apache-2.0 licence and NOTICE. Form-reference links in the
seed comments name what an exercise was checked against; nothing is copied
from them.
