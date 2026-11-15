# API

All JSON, under `/api`. The full reference, every path with its parameters,
request bodies and error responses, is generated from the controller comments
by Rage's OpenAPI support and served by the app:

- **`/api/openapi`**: browsable reference (Swagger UI, linked from Settings)
- **`/api/openapi/json`**: the OpenAPI 3 document, for tools and an MCP server

## Keeping it generated

Each controller action carries its own description, which is the only place
to change it:

```ruby
# Change the user's own workout.                      <- summary
# @description Fields left out are kept. ...
# @request { title?: String, warmup?: String }
# @response 200 #/components/schemas/Workout
# @response 403 #/components/responses/Forbidden
def update
```

Shared parts live in `config/openapi_components.yml`: the body schemas
(`Workout`, `Session`, `SetLog`, `Today`, ...), the `Error` schema and the
error responses. The API title is on `ApplicationController`.
`test/requests/openapi_test.rb` fails when a route has no summary or success
response, when a success other than a 204 has no body schema, when an error
response is not one of the shared ones, or when the document builds with
warnings.

The descriptions are checked against the real responses: every API request a
request test makes must answer with a status its action describes and a body
that fits the schema for it (`test/openapi_schema.rb`, hooked into
`RequestHelpers`). Objects are checked strictly, so a field added to a
response must be added to its schema, and every key listed is always sent,
as null when it has no value (`nullable`).

## Conventions

- **Errors** have one shape: `{ "error": { "code", "message", "fields"? } }`.
  Codes: `bad_request` (400), `unauthorized` (401),
  `password_change_required` (401, signed in with a temporary password), `forbidden` (403),
  `not_found` (404, with the `resource` and `id` looked for), `no_workouts`
  (404 from Today with nothing to train yet), `conflict` (409),
  `already_imported` (409, an example imported before), `user_mismatch`
  (409, a write for another user than the one signed in), `invalid` (422),
  `too_many_requests` (429, with `Retry-After`).
  `bad_request` and `invalid` name the offending `fields`. A required id
  left out is a `bad_request` ("step_id is required"); an id that names
  nothing is a `not_found`.
- **Everything is the signed-in user's**: the exercise library and the
  equipment catalogue are shared, and everything else (workouts, programs,
  sessions, sets, weights, suggestions, settings, what equipment is owned)
  is the user's own. Another user's id is a 404, as an id that names nothing
  is, and a `client_ref` is the user's own.
- **Today** is the server's day in `TZ` when a request sends no `date`.
  Planning and moving sessions take the client's own `today` when it is
  within a day of the server's, so a phone in another time zone, or just
  past midnight, plans on its own today. A session's `started_at` and its
  `finished_at` may come from the device (never later than now), so a run
  synced late keeps its times.
- **The calendar is sessions, activities and dated notes.** `GET /api/calendar` gives a
  range's sessions, activities and the coach's notes dated in it as flat lists (up to 366 days, so a
  month grid fits); the planning rules are those of `/api/sessions`. A session planned on a day before
  today reads as `missed`. Planning, moving and making a session planned
  again take a day from today on, and only a planned (or missed) session
  moves: anything else is a 409 (its own date sent back is no move). A done
  session keeps its status. `/api/today` lists the whole `day`. Sessions on
  one day happened in the order they finished, which the weight suggestions
  and deleting a session go by; `position` is only the planned order.
  `DELETE /api/sessions/:id` erases a session of any status (History);
  with `only=planned` (the calendar's Remove) it is a 409 once it has started.
- **Activities record what happened**, never a plan: `date` is the
  sender's own day it started on and may not be after their `today`.
  Distances and climb are whole metres, times whole seconds; nothing is
  worked out from them (no pace, load or score), and `distance_unit`
  (`/api/settings`, km or mi) only changes how they are shown.
  `POST /api/activities` takes one activity or `{ "activities": [...] }`
  (at most 500, all or nothing, a bad entry named `activities[3].field`).
  One sent with a `source` and `external_id` the user already has updates
  that activity: the fields sent win, the ones left out (or null) are
  kept, and `rpe` and `note` are filled only while empty, so the person's
  own stay. A deleted import comes back if its source sends it again.
- **Goals are the user's.** The app adds, edits, orders (`position`, 1
  first) and closes them (`achieved`, `dropped`). An agent only proposes one
  over MCP: a `proposed` goal the user accepts (`POST /api/goals/:id/accept`,
  taking the place of the goal it `replaces`) or dismisses (kept, so it isn't
  proposed again). A proposal is never edited (409).
- **Coach notes** are a status, focus, concern or note, written by the user
  (`author_kind: user`, the default), a coach they name (`human` with an
  `author_name`) or an agent (`llm`, over MCP only). The current status or
  focus is the newest of its kind; deleting it brings the one before back.
  A concern stays open until `PATCH` sends `resolved: true`. `GET /api/coach`
  is the whole board with this week's sessions, activities, routines and
  routine days as plain lists, nothing summed; `GET /api/coach/notes` pages the journal with
  `before`, filtered by `kind` and `author`. A note about a session or
  activity shows on its day wherever it moves (`/api/calendar`). Tidy up
  (`GET` counts, `POST /api/coach/tidy` deletes) clears the agent's notes
  written before a day, keeping the current status and focus and the open
  concerns.
- **Weights** come back in the exercise's unit: the one the user's gear for
  it comes in (`unit` in `/api/equipment`, theirs to set). A weight sent in the other
  unit is converted and snapped to an owned weight. The `unit` setting
  (`/api/settings`) only changes how weights are shown.
- **The generic weight** (`weight`, `any_weight: true` in `/api/equipment`)
  is what an exercise needs when any dumbbell or kettlebell will do. It
  can't be changed: it is owned with any gear in set weights, its weights
  are all of theirs, and filtering by dumbbell or kettlebell finds it too.
- **Retries are safe**: `POST /api/sessions` and `POST /api/activities`
  with a known `client_ref` return that record; `POST /api/sessions/:id/sets` updates a set that is
  already logged (200 instead of 201); `complete` keeps fields it leaves out.
  A set sent for a step the session no longer runs (the workout was edited
  on another device while this one ran it offline) is kept from what the
  player showed (`planned_exercise_id`, `block_label`, `target`), without
  the step link.
- **Every workout is the user's**, imported ones included. Deleting one
  archives it, and an archived workout is read-only (403).
- **A workout's structure is written whole**: `POST /api/workouts` and
  `PUT /api/workouts/:id` take every block and step, in order, and replace
  what is there. Blocks and steps that name their `id` are kept (a step's
  logged sets keep their link); the rest are new, and what is left out is
  deleted, its logged sets kept. All or nothing: a 422 lists every problem,
  with `fields` keyed by path (`blocks[0].steps[1].reps`). GET's blocks can
  be sent back as they are: a step's `equipment` and `weights_held` are its
  own (null while it follows its exercise; `equipment_needed` is what it is
  done with), and what only GET gives is ignored. While a session
  runs a workout (as itself, or as the warm-up or cool-down), changing its
  structure or its warm-up and cool-down answers 409 until that session is
  finished or skipped, or planned again while no set is logged in it. A run
  holds the workout on its day and the next, and later on only while it is
  picked up again or logs a set within a day; one left idle longer is
  abandoned and no longer blocks edits. Only the server's status counts: a
  session started offline is unknown until its outbox reaches the server.
- **Archiving a warm-up or cool-down** takes it out of the main workouts that
  pick it (they run without one) and is a 409 while a session runs it.
- **Signed in, or a 401.** Every route under `/api` needs a session or a
  personal API token but `/api/version`, `/api/openapi` and `/api/me`, which
  says who is signed in or, as a 401, whether the install still needs its
  owner (`setup_required`). A device signed out from elsewhere gets a 401
  that says so.
- **API tokens** (made in Settings, `/api/account/tokens`) are sent as
  `Authorization: Bearer lr_...` and act as their user with full access,
  without the session or the CSRF headers. An unknown or revoked one is a
  401 with `WWW-Authenticate`. They can't manage the account (devices,
  tokens): that is a 403, so a leaked token can't make itself another. Only
  the `Bearer` scheme counts; another `Authorization` header (a proxy's
  Basic sign-in) is left to the session. What a token writes as an agent
  (`created_by: llm`, and everything over MCP) carries the token's name as
  `agent_name`, the name the app shows for the agent.
- **Writes come from the app.** A POST, PUT, PATCH or DELETE needs
  `Sec-Fetch-Site: same-origin` (or, without it, an `Origin` equal to the
  server's) and a body of `application/json`, else a 403. Browsers send the
  headers themselves; a script sends `Origin`. A write may name the user it
  is for in `X-Lazy-Runner-User` (the PWA's outbox does): it is a 409
  `user_mismatch` when someone else is signed in.
- **Sign-in routes** are Rodauth's, under `/api/auth`, in JSON and in the
  same error shape, and not in the OpenAPI reference:

  | Route | Body | Does |
  |-------|------|------|
  | `POST /api/auth/create-account` | `setup_code` or `invite`, `username`, `password` | Creates the owner on a fresh install with the setup code (403 for a wrong one, 404 once there is an owner), or anyone else's account with an owner's invite (404 when it is used, expired or revoked); signs them in |
  | `POST /api/auth/login` | `username`, `password` | Signs in; 401 "Wrong username or password" for an unknown user, a wrong password and a locked account alike, in the same time; 409 when signed in already; 429 after 10 tries a minute on one username |
  | `POST /api/auth/logout` | | Signs this device out (`Clear-Site-Data: "cache"`) |
  | `POST /api/auth/change-password` | `password`, `new_password`, `sign_out_others` | Changes the password; signs out every other device, revokes the API tokens and unlinks OIDC sign-ins unless `sign_out_others` is false (always when leaving a temporary password). Without a password yet (signed in only with OIDC), sets one, no `password` needed |
  | `POST /api/auth/oidc` | `invite`, `next` (both optional) | With an OIDC provider set: `{ authorize_url }`, the provider's page to send the browser to (502 when it can't be reached); signed in, it links the identity instead. 404 without a provider |
  | `GET /api/auth/oidc/callback` | | Where the provider sends the browser back: signs in, joins with the invite, or links, then redirects to `/signin.html` (`?next=`, or `?oidc_error=no_account`, `invite_gone`, `cancelled`, `unavailable`, `failed`) or, for a link, `/settings.html?oidc=linked` (or `linked_elsewhere`, `already_linked`, ...) |

  Usernames are 3 to 40 letters, digits, dots, dashes and underscores,
  matched whatever their case; passwords are at least 8 characters. Ten
  wrong passwords lock an account for 15 minutes.
- **The owner manages users** (`/api/users`, `/api/invites`): a 403 for
  anyone else, and for an API token. A user given a temporary password
  gets a 401 with the code `password_change_required` from every route but
  `/api/me` and `/api/auth/*` until they change it, and their API tokens
  don't count (a 401 `invalid_token`) until then.

## MCP server

`/mcp` speaks the Model Context Protocol over Streamable HTTP for an
assistant acting as a personal trainer (`app/mcp/`). It takes a personal
API token only (`Authorization: Bearer lr_...`, checked by
`TrainerMcp::TokenVerifier` through the mcp gem's bearer support; a browser
session doesn't count), and the tools act as that token's user. It is
stateless (no session id) and answers each POST with plain JSON.

Make a token in Settings, which shows this server's MCP address and a
ready-to-paste command with the new token in it, and connect a client with
`http://<host>:3000/mcp`, for example
`claude mcp add --transport http lazy-runner http://<host>:3000/mcp --header "Authorization: Bearer lr_..."`. Only
loopback `Host` names are accepted (a guard against DNS rebinding) unless
`MCP_ALLOWED_HOSTS` lists others, comma-separated (`name` or `name:port`).

On connecting, the client gets the **trainer brief** as the server's
instructions (also the `trainer_brief` prompt and the `lazy-runner://brief`
resource): what the app is, plan only with owned equipment, an exercise's
weight applies to every workout that uses it while reps and time are set per
step, every workout is the user's to change, the library is fixed, an empty day is
a rest day, a missed session is a signal rather than an error, and a workout
change reaches every future session of it.

| Tool | Does |
|------|------|
| `search_exercises` | The library, filtered by `text`, `area`, `pattern`, `category` and `equipment` (what is owned by default) |
| `get_exercise` | One exercise by slug: instructions, mistakes, equipment, remembered weight, owned weights, pending suggestion, workouts using it |
| `list_equipment` | The inventory with owned weights, and the display unit |
| `list_workouts` | Workouts by program, the user's own last (as `GET /api/workouts`) |
| `get_workout` | One workout's blocks and steps with resolved targets (as `GET /api/workouts/:id`, without the player plan) |
| `training_summary` | Sessions in a date range (28 days by default) with how they felt and what was done per exercise, weekly counts, remembered weights, pending suggestions |
| `list_sessions` | The calendar over a date range (as `GET /api/sessions`), each session with its workout, minutes and completion |
| `list_activities` | Activities over a date range (as `GET /api/activities`), with the user's distance unit |
| `list_routines` | Routines with days in a date range (by default the 7 days before today and the 21 from today on), the days with their state (tentative, confirmed, done, skipped, missed) and raw counts per state |
| `list_examples` | The example programs (as `GET /api/examples`) |
| `create_workout` | A new workout with its whole structure (as `POST /api/workouts`), marked `source: llm`; steps name exercises by slug; `warnings` name steps with gear or a weight the user doesn't own |
| `import_example` | An example program into the user's (as `POST /api/examples/:slug/import`), marked `source: llm` |
| `update_workout` | Title, framing and, with `blocks`, the whole structure (as `PATCH` and `PUT /api/workouts/:id`) of a workout of the user's or the assistant's |
| `duplicate_workout` | A copy of a workout, marked `source: llm` |
| `archive_workout` | Archives a workout, taking its sessions from today on off the calendar |
| `set_exercise_weight` | The remembered weight (as `PUT /api/exercises/:id/weight`), for every workout with the exercise |
| `update_equipment` | Whether the user owns an item, and its weights and unit (as `PATCH /api/equipment/:id`) |
| `plan_sessions` | Up to 28 sessions on days from today on, all or nothing, marked `created_by: llm` |
| `move_session` | A planned or missed session to another day or place, or a new note |
| `remove_session` | A planned or missed session off the calendar |
| `log_activities` | Up to 500 activities, all or nothing (as `POST /api/activities`), marked `created_by: llm`; distances in metres or with a unit (`"5 mi"`), no RPE or note |
| `plan_routine` | A weekly or one-off routine for a sport or a workout, always tentative, marked `created_by: llm`; distance in metres or with a unit |
| `update_routine` | A routine the assistant planned (as `PATCH /api/routines/:id`, so a reschedule with days gone by starts a new one) |
| `end_routine` | Ends a routine the assistant planned from today on, or deletes one without days gone by |
| `get_coach_board` | Goals (active, proposed, dismissed), the current status and focus, open concerns, the latest notes and this week, routine days included |
| `list_coach_notes` | Every note, newest first, by kind, author or day, paged with `before` |
| `write_coach_note` | A status, focus, concern or note, marked `author_kind: llm` and signed with the token's name (`author_name` sent is ignored); the same note again isn't written twice, and an agent writes at most 20 a day |
| `update_coach_note` | Changes a note an agent wrote; the person's are theirs |
| `delete_coach_notes` | Deletes up to 100 notes an agent wrote, all or nothing |
| `resolve_concern` | Resolves a concern an agent raised; the person's are theirs to resolve |
| `propose_goal` | A goal, or a change to one, for the user to accept or dismiss; never a dismissed title again |

The assistant may change any session still planned or missed, the user's
included, but never skips one and never touches one started or done. It
changes and ends only the routines it planned, and never confirms, skips or
moves a routine day; those
answer with the same refusals as the API. A mistake in the arguments (an
unknown slug, a bad date, an argument the tool's schema doesn't name) is a
tool error whose text says what to fix; a workout that doesn't hold together
names each block and step at fault, and nothing is written. Answers leave
out fields without a value; the ones that give `today` give its `weekday` too. `test/requests/mcp_test.rb` drives the endpoint
over HTTP, including a workout built and planned through `/mcp` and read
back through the API.

## Map

| Resource | Paths |
|----------|-------|
| Today | `GET /today` (the day's session, framed and flattened for the player) |
| Workouts | `GET/POST /workouts`, `GET/PATCH/PUT/DELETE /workouts/:id`, `POST /workouts/:id/duplicate`, `GET /programs` |
| Calendar | `GET /calendar` (sessions, activities and dated notes over a range) |
| Coach | `GET /coach`, `GET/POST /coach/notes`, `PATCH/DELETE /coach/notes/:id`, `GET/POST /goals`, `PATCH/DELETE /goals/:id`, `POST /goals/:id/accept`, `POST /goals/:id/dismiss` |
| Activities | `GET/POST /activities`, `PATCH/DELETE /activities/:id` |
| Sessions | `GET/POST /sessions`, `GET/PATCH/DELETE /sessions/:id`, `POST /sessions/:id/sets`, `POST /sessions/:id/complete`, `PATCH /sessions/:id/completion` |
| Exercises | `GET /exercises`, `GET /exercises/:id`, `GET /exercises/:id/alternatives`, `GET/PATCH/PUT /exercises/:id/weight` |
| History | `GET /history`, `GET /history/exercises`, `GET /exercises/:id/history` |
| Equipment | `GET /equipment`, `PATCH /equipment/:id` |
| Settings | `GET/PATCH /settings` |
| Version | `GET /version` (the app's version and commit, shown on Settings, and the frontend release id, for the service worker) |
| Account | `GET /me`, `GET/DELETE /account/devices`, `DELETE /account/devices/:id`, `GET/POST /account/tokens`, `DELETE /account/tokens/:id`, `GET /account/identities`, `DELETE /account/identities/:id`, `POST /account/welcome`; sign-in under `/auth` (above) |
| Users (owner) | `GET /users`, `DELETE /users/:id`, `POST /users/:id/password`, `GET/POST /invites`, `DELETE /invites/:id` |
