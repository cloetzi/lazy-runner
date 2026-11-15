# The Lazy Runner

> Strength for people who'd rather just run.

The Lazy Runner is a small, self-hosted strength coach for runners. Open it on a
phone, tablet or computer, see today's session, press **Start**, and get guided
through the warm-up, workout and cool-down with timers, beeps, on-screen cues and
looping exercise animations. Your sets, weights and feedback are logged, and the
weights you settle on are remembered for next time.

It is a private, self-hosted app: everyone on an install signs in with a
username and password, and it connects to no fitness service itself. An assistant you run yourself can act as a personal trainer
through its MCP server: it reads the exercise library, your equipment, your
workouts, your activities and how past sessions went, builds workouts from the
library, plans them on your calendar, suggests runs and other sport as
tentative routines, and can log your runs and other activities from a service
it reaches (such as Garmin).

## Status

Early development (iteration 1). The features below work, every built-in
exercise has its animation, and the app installs to the home screen and runs a
session offline, syncing when the connection returns.

## Features (v1)

- **Home:** today's session card with title, estimated minutes, the planner's
  note and one big Start button, below the day's sessions in order when there are
  several. Move it, skip it, or train something else. A day with nothing planned
  is a rest day that offers to bring the next planned session forward, else the
  next workout in the rotation. A new account, with nothing to train yet, is
  pointed at the example programs.
- **Example programs:** ready-made programs (Cycle 1, Home strength, No-gear strength) to import
  on Settings. An imported program is yours to change, and its weights snap to
  the gear you own.
- **Calendar:** plan a workout on any day from today on, with an optional note,
  and move, skip or remove what is planned. Phones show a week; wide screens
  also a month grid where a planned session can be dragged to another day.
  Done, planned, up next, missed and skipped each have their mark, and a missed
  session can be done today with one tap.
- **Routines:** plan runs, rides, hikes or a workout every week on some days,
  or once as a Maybe or Planned. Their days show dashed until you say you're
  going; a logged activity of the same sport ticks the day off, and one that
  didn't happen says so. Move a day, skip a week, or log it right there.
- **Coach:** your goals anchor a Coach tab with the current status and focus,
  this week as a plain list, open concerns and a journal of notes. You, a
  coach you name, or an agent over MCP write them; only you change goals, and
  an agent's proposed goal waits for you to accept or dismiss it. Notes dated
  to a day show on the calendar.
- **Workout view:** open any workout from today's card or the picker to see every
  block, round, rest and step with its target, without starting it. Weights can be
  adjusted there with the same stepper as the player; they are remembered for the
  exercise and used by the next session. Duplicate one to try a variation. A
  deleted workout is archived, so its sessions stay in the history.
- **Workout editor:** build a workout, warm-up or cool-down of your own from
  the exercise library, or edit one: name, warm-up and cool-down (or none),
  blocks with their rounds and rest, and steps with reps or time, tempo, a
  starting weight stepping through what you own, and a note. Exercises are
  picked with their animation, filtered as on the Exercises page; blocks and
  steps reorder with up and down buttons. Nothing is saved until Save, and
  any problem shows next to the block or step it is in.
- **Get ready:** before starting, a list of all equipment the session needs
  (dumbbells, bench or chair, stability ball) with target weights.
  Bodyweight-only sessions skip it.
- **Player:** one step per screen, readable from a distance and usable one-handed.
  - Exercise name, 2-4 cue lines, target (reps, weight, tempo or countdown),
    block and set progress, and what comes next.
  - Timed steps count down with beeps at start, 3-2-1 and end. Rep-based steps
    have a Done button and an optional rest timer. On an iPad or iPhone, beeps
    play alongside music and follow the mute setting; they come back after a
    call or an app switch, and Test sound in Settings tries them.
  - Per-side steps run both sides automatically with a switch cue (a rising beep and "Switch sides" on screen).
  - Pause (rests too), previous (skips back over rests), skip, a weight/reps stepper, and swap: trade an
    exercise for another of the same category, done the same way and doable with the equipment you
    own, for the rest of the session. The best
    matches work the same part of the body with the same equipment.
  - Screen wake lock; state survives a reload or a lost connection.
- **Exercise animations:** keyframe poses on a simple skeleton, stored as data and
  rendered as SVG. Tiny, crisp, themeable and mirrorable for left/right. A static
  frame is shown when reduced motion is requested. An **Exercises** page previews
  every exercise with its animation and cues, and a how-to view adds the full
  instructions and common mistakes.
- **Remembered weights:** per exercise, not per workout. A remembered weight
  always wins over the seed value, in every workout that uses the exercise;
  reps and time are not remembered, they stay with each workout's step. The
  app never suggests a weight or changes one from how a session went: you
  change it with the stepper, or your coach agent recommends one from your
  sets and feedback and sets it when you agree.
- **Finish:** a short summary, optional RPE and a one-tap too easy / right / too hard on the weights, kept for you and your coach agent.
- **History:** a simple list, a weekly count, and weight and reps over time per exercise.
- **Equipment:** an inventory of what you have at home, with the weights you
  own for dumbbells and kettlebells. Every exercise names the equipment it
  needs, and the Exercises page can keep to what you own. An exercise that
  holds one weight just needs "a weight": any dumbbell or kettlebell you own.
- **Exercises:** the library, searchable and filtered by body area and
  equipment (what you own by default). Each card says when you last did it and
  which workouts use it; the how-to shows either side and half speed.
  `library.html?review` is the animation review layout.
- **Offline:** an installable PWA that fetches ahead while online, so every
  workout, the calendar, the coach board and history open without a connection,
  and a session runs and finishes there, syncing when the connection returns.

- **MCP server** at `/mcp`: tools for an assistant acting as a personal
  trainer, plus a brief with the rules it plans by. See
  [Connecting an assistant](#connecting-an-assistant).

Out of scope for v1: Garmin/Strava/Endurain data, native apps,
social, nutrition and voice cues.

## Tech stack

| Part      | Choice                                                                 |
|-----------|------------------------------------------------------------------------|
| Backend   | Ruby with [Rage](https://github.com/rage-rb/rage) (API-first, Rails-style controllers, fiber per request), on Rage's default server |
| Database  | SQLite through [Sequel](https://sequel.jeremyevans.net), one file on a Docker volume |
| Frontend  | Static PWA (plain ES modules, no build step) served by the same process |
| Tests     | Minitest (spec expectations) for the API and models, `node:test` for the player logic, Playwright for a browser run |
| Packaging | Container image built on each release                                  |

## Documentation

- [Architecture](docs/architecture.md): components, a session end to end, offline and releases, build and deploy.
- [Data model](docs/data-model.md): every table with an ER diagram, and who owns which data.
- [API](docs/api.md): conventions and a map of the endpoints. The full reference
  is generated from the controller comments and served by the app at
  `/api/openapi` (the OpenAPI document at `/api/openapi/json`), linked from Settings.
- [UI and design](docs/design.md): principles, tokens and components, exercise figures.

## Running it

With Docker (an image is built for each release and published to the GitHub container registry, tagged `latest` and with its version, such as `1.2.3` or `1.2`):

```sh
docker run -p 3000:3000 -v lazy-runner-data:/app/storage ghcr.io/cloetzi/lazy-runner:latest
```

Then open http://localhost:3000 on your phone or computer. The SQLite database
lives in `/app/storage`; back up that volume. The schema is migrated and the
exercise library and equipment catalogue are loaded on every start. A database from a
release before 0.1.0 has to run 0.1.0 once first; the server says so at boot.

**Signing in.** A fresh install has no accounts. The server logs a one-time
setup code when it starts (`docker logs <container>`, the line "Create the
owner account in the app with the setup code ..."); open the app, enter the
code and pick a username and password, and that account owns the install.
A restart prints a new code until the owner exists. The owner invites
everyone else from Settings, Users: an invite link works once, for 7 days,
and the person joining picks their own username and password. There the
owner also resets a forgotten password to a temporary one, which the user
changes when they next sign in, and removes a user with their data. A
first sign-in shows a welcome screen: units, the gear you own, an
example program to import and the days you train, which go on the
calendar. What is left to set up stays on Today until it is done.

**Getting back in.** There is no email to reset a password by, so the owner
resets one from a shell where the app runs, for any user, themselves
included. In the container that is
`docker exec -it <container> bundle exec rake users:reset_password USERNAME=<name>`
(from a checkout, `RAGE_ENV=production bundle exec rake ...`). It prints a
temporary password to sign in with, which has to be changed at once; their
devices are signed out, their API tokens revoked, their sign-ins with an
OpenID Connect provider unlinked and a lockout lifted. It takes no password
of your choosing, so none ends up in the shell's history.
`rake users:list` names the users, owners first, for a forgotten username,
and `rake users:create_owner USERNAME=<name>` makes the owner of a fresh
install without the setup code (it asks for the password, or takes
`PASSWORD=` for a scripted install).

**Each user's data is their own.** The exercise library and the equipment
catalogue are shared; workouts, the calendar, history, weights, settings
and what equipment is owned belong to each account. Upgrading from a release
that kept one user's data without accounts drops that data: the first start
copies the database aside to `storage/production.before-per-user.sqlite3`
before it does.

The session cookie is `Secure`, so the app expects to be reached over HTTPS,
behind your reverse proxy. On plain http, such as straight on the local
network, set `-e SECURE_COOKIES=false` or nobody stays signed in. The cookie
is sealed with a secret kept in `storage/session_secret`, made on first start;
set `SESSION_SECRET` (64 or more characters) to provide your own. Changing it
signs everyone out.

**Signing in with an OpenID Connect provider** (Authelia, Keycloak, Google
or any other) works next to passwords. Register a confidential client with
the authorization code flow, the redirect URI
`https://<your host>/api/auth/oidc/callback` and the scopes `openid profile
email`, then set `OIDC_ISSUER` (its https issuer URL), `OIDC_CLIENT_ID`,
`OIDC_CLIENT_SECRET`, `OIDC_REDIRECT_URI` (that same redirect URI) and
`OIDC_NAME` (what the button calls it). The sign-in
page then offers "Sign in with <name>": each user links their identity in
Settings, and an invite can be accepted with it instead of a password. With
`OIDC_AUTO_SIGNUP=true`, anyone the provider lets through gets an account
on first sign-in, named after their `preferred_username`, so the provider's
own access rules decide who joins. Optional: `OIDC_CLIENT_AUTH_METHOD=client_secret_post`
and `OIDC_SIGNING_ALG` (RS256 by default). The owner account is still made
with the setup code. Changing a password (signing out the other devices) or
an owner's reset unlinks the user's sign-ins, as it revokes their API tokens,
and unlinking one signs out the other devices that signed in with it and
revokes the API tokens made on them.

Set `TZ` to your time zone (an IANA name, such as `-e TZ=America/Vancouver`) so
that "today" is your day for API calls that don't send a date; it is UTC
otherwise. An unknown name stops the server at boot.

### Connecting an assistant

Make an API token in Settings (it is shown once), then point an MCP client at
`http://<host>:3000/mcp` (Streamable HTTP) with it, for example
`claude mcp add --transport http lazy-runner http://<host>:3000/mcp --header "Authorization: Bearer lr_..."`.
The assistant then acts as you, with full access to your data; revoke the
token in Settings to cut it off. Scripts can send the same header to `/api`.
A sign-in proxy in front of the app has to let `/mcp` and requests with a
`Bearer` token through without its own sign-in, and pass the
`Authorization` header on. The
server guards against DNS rebinding by accepting only `localhost` unless told
otherwise: set `MCP_ALLOWED_HOSTS` to the host names (or `host:port`) clients
use to reach it, comma-separated, such as `-e MCP_ALLOWED_HOSTS=<host>`.
Tools and the trainer brief are described in [docs/api.md](docs/api.md#mcp-server).

From source, with the Ruby version in `.ruby-version` and the Node version in `.node-version` (Node only runs the tests):

```sh
bundle install
bundle exec rage s      # http://localhost:3000
bundle exec rake test   # Ruby tests (Minitest)
npm test                # player logic tests
```

## Content and licensing

The repository is built so it can be open-sourced later: no secrets, personal data
or deployment-specific values, and no copied third-party images or text. Exercise
cues and animations are original. The licence will be chosen when the project is
published.
