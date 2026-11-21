# Data model

One SQLite file (`storage/<env>.sqlite3`, or `DATABASE_URL`), migrated on
every boot by Sequel from `db/migrate/`. Every table but the two join tables
(`exercise_equipment`, `step_equipment`) and Rodauth's `account_*` tables
also has `created_at` and `updated_at`, left out below. `test/lib/docs_test.rb` checks that every table and column appears here.

The exercise library and the equipment catalogue are shared and seeded.
Everything else is one user's: a `user_id` (deleted with the user) on every
personal table, or a parent that has one (blocks and steps through their
workout, completions through their session). Links between two of a user's
records are composite foreign keys on `(user_id, id)`, so a session can't
name another user's workout even by mistake. The diagram leaves the
`users` links to these tables out. `invites` stand alone: an owner's
links for others to join.

```mermaid
erDiagram
    equipment ||--o{ exercise_equipment : "needed by"
    exercises ||--o{ exercise_equipment : needs
    equipment ||--o{ step_equipment : "used by"
    steps ||--o{ step_equipment : uses
    programs |o--o{ workouts : groups
    workouts |o--o{ workouts : "warm-up / cool-down"
    workouts ||--o{ blocks : has
    blocks ||--o{ steps : has
    exercises ||--o{ steps : "done in"
    workouts ||--o{ sessions : "run as"
    sessions ||--o{ set_logs : logs
    steps |o--o{ set_logs : "planned by"
    exercises ||--o{ set_logs : "done / planned"
    sessions ||--o| completions : "finished by"
    exercises ||--o| exercise_weights : remembers
    users ||--o{ activities : logs
    users ||--o{ goals : "aims for"
    goals |o--o{ goals : "proposed to replace"
    users ||--o{ coach_notes : "coached in"
    activities |o--o{ coach_notes : "noted on"
    sessions |o--o{ coach_notes : "noted on"
    coach_notes |o--o{ coach_notes : "replied to"
    users ||--o{ check_ins : "checks in"
    users ||--o{ routines : "means to"
    workouts |o--o{ routines : "run by"
    routines ||--o{ routine_days : "changed on"
    routines |o--o{ sessions : "confirmed as"
    routines |o--o{ activities : "linked by hand"
    users ||--o{ plan_changes : "changed plan"
    sessions |o--o{ plan_changes : "changed in"
    routines |o--o{ plan_changes : "changed in"
    workouts |o--o{ plan_changes : "edited in"
    exercises |o--o{ plan_changes : "weight set in"
    plan_changes |o--o| plan_changes : "taken back by"
    users ||--o| account_password_hashes : "proves with"
    users ||--o| account_login_failures : "failed sign-ins"
    users ||--o| account_lockouts : "locked by"
    users ||--o{ account_active_session_keys : "signed in on"
    users ||--o{ api_tokens : "lets in"
    users ||--o{ user_identities : "signs in as"
    user_identities |o--o{ account_active_session_keys : "signed in"
    user_identities |o--o{ api_tokens : "made under"
    users ||--o{ user_equipment : owns
    equipment ||--o{ user_equipment : "owned as"

    equipment {
        int id PK
        string slug UK
        string name
        int position
        string unit "lb | kg | null: whether it comes in set weights"
        bool any_weight "the generic weight: any owned gear in set weights stands in"
        bool retired "dropped from the seeds, kept for users who had it"
    }
    user_equipment {
        int id PK
        int user_id FK
        int equipment_id FK "unique per user"
        bool owned "no row: not owned"
        json weights "owned weights, for fixed-weight gear"
        string unit "lb | kg, once set or weights are listed; null: follows settings.unit"
    }
    exercise_equipment {
        int id PK
        int exercise_id FK
        int equipment_id FK
    }
    exercises {
        int id PK
        string slug UK
        string name
        string category "stretch | mobility | activation | strength | cardio"
        json areas "legs, hips, core, upper_body"
        string pattern "squat, lunge, hinge, push, pull, ..."
        json cues
        json mistakes
        json instructions
        bool unilateral
        bool alternating "sides in turn within a set; reps count both"
        int weights_held "1, or 2 for a dumbbell in each hand"
        int default_reps
        int default_seconds
        json animation "keyframes, see public/js/figure.js"
        bool retired "dropped from the seeds, kept for logged sets"
    }
    programs {
        int id PK
        int user_id FK
        string example_slug "the example it was imported from"
        string name
        text description
        string source "user | llm"
    }
    workouts {
        int id PK
        int user_id FK
        int program_id FK "null for one standing alone"
        string example_slug "the example workout it was imported as"
        string kind "warmup | workout | cooldown"
        string title
        string subtitle
        int position
        string source "user | llm"
        int warmup_id FK
        int cooldown_id FK
        bool no_warmup
        bool no_cooldown
        datetime archived_at "deleted = archived"
    }
    blocks {
        int id PK
        int workout_id FK
        string label "A, B, Warm-up; unique per workout"
        int position
        int rounds
        int rest_seconds "after each round but the last"
    }
    steps {
        int id PK
        int block_id FK
        int exercise_id FK
        int position
        int reps "reps or duration_seconds, not both"
        int duration_seconds
        string tempo "3 or 4 digits, such as 3110"
        decimal weight_value "the step's own target"
        string weight_unit
        int weights_held
        bool per_side
        string note
    }
    step_equipment {
        int id PK
        int step_id FK
        int equipment_id FK
    }
    sessions {
        int id PK
        int user_id FK
        int workout_id FK
        date date
        int position "order within the day, 1 first"
        string status "planned | in_progress | done | skipped; missed is derived"
        string created_by "manual | llm"
        string agent_name "the agent's API token name, when llm"
        text note "the planner's reason for it"
        datetime started_at
        json part_kinds "the parts it runs: warmup, workout, cooldown"
        string client_ref UK "per user; makes POST /api/sessions safe to retry"
        int routine_id FK "the routine day it confirms; null when the routine goes"
        date routine_date "that routine's own day, unique with it"
    }
    set_logs {
        int id PK
        int user_id FK "the session's, for history by exercise"
        int session_id FK
        int step_id FK "nulled when the step leaves"
        int step_ref "the step logged against, kept"
        int exercise_id FK "done (differs when swapped)"
        int planned_exercise_id FK
        string block_label
        string part "warmup | workout | cooldown: main or framing"
        int set_number
        string side "left | right | null"
        string status "done | skipped"
        int reps
        int seconds
        decimal weight_value
        string weight_unit
        int target_reps
        int target_seconds
        decimal target_weight_value
        string target_weight_unit
    }
    completions {
        int id PK
        int session_id FK,UK
        datetime finished_at
        int rpe "1-10"
        string feedback "too_easy | right | too_hard"
        text note
        bool ended_early
    }
    exercise_weights {
        int id PK
        int user_id FK
        int exercise_id FK "unique per user"
        decimal value "null: no weight"
        string unit
    }
    activities {
        int id PK
        int user_id FK
        date date "the sender's own day it started on"
        datetime started_at "UTC"
        string sport "free text, trimmed and lowercase"
        string title "null: the sport is shown"
        int moving_seconds
        int elapsed_seconds
        int distance_m "metres"
        int climb_m "metres"
        int avg_hr
        int max_hr
        int rpe "1-10, the person's"
        text note
        string source "with external_id, unique per user"
        string external_id "its id at the source"
        string client_ref UK "per user"
        string created_by "manual | llm"
        string agent_name "the agent's API token name, when llm"
        int routine_id FK "a sport routine's day it was linked to by hand"
        date routine_date "that day, unique with the routine"
    }
    routines {
        int id PK
        int user_id FK
        string title "null: the sport or workout is shown"
        string sport "a sport, or workout_id"
        int workout_id FK "one of the user's workouts"
        json weekdays "ISO 1-7; empty for a one-off"
        date starts_on
        date ends_on "a one-off's is its day; null runs on"
        int minutes "rough"
        int distance_m "rough, metres"
        string effort "easy | moderate | hard"
        text note
        string created_by "manual | llm"
        string agent_name "the agent's API token name, when llm"
    }
    check_ins {
        int id PK
        int user_id FK
        date date "unique with the user"
        string sleep "poor | ok | good: the night that ended that morning"
        string drinks "none | 1-2 | 3+, that night"
        json night_tags "late_to_bed, ate_late, travelling, woke_a_lot"
        text night_note
        string night_by "manual | llm; null while the night is empty"
        string feeling "rough | ok | good: the day"
        string stress "low | normal | high"
        string sore "no | a_bit | a_lot"
        json sore_areas "knees, calves, achilles, shins, hamstrings, hips, back, other"
        bool ill
        text day_note
        string day_by "manual | llm; null while the day is empty"
        string agent_name "the last agent that filled a field"
        datetime agent_at "when it did"
    }
    routine_days {
        int id PK
        int routine_id FK
        date date "the routine's own day, unique with it"
        string status "confirmed | skipped | moved"
        date moved_to "the day it shows on instead"
    }
    plan_changes {
        int id PK
        int user_id FK
        string changed_by "manual | llm (with an API token)"
        string agent_name "the agent's API token name, when llm"
        string item_kind "session | routine | workout | weight (an exercise's remembered one)"
        int session_id FK "set null when deleted"
        int routine_id FK "set null when deleted"
        int workout_id FK "the workout edited or archived"
        int exercise_id FK "the exercise whose remembered weight was set"
        string title "the item's name at the time"
        string action "planned | moved | removed | changed | ended | archived"
        date from_date "the day it left"
        date to_date "the day it joined"
        json was "the fields before; a removal's, all to put it back; a workout's whole structure; a weight's value and unit"
        json now "the fields after"
        text summary "what a workout edit changed, in a line"
        text reason
        string batch "shared by one request or tool call"
        int undoes_id FK,UK "the change it takes back"
    }
    goals {
        int id PK
        int user_id FK
        string title
        text why
        date target_date
        string status "active | achieved | dropped | proposed | dismissed"
        int position "an active goal's place, 1 first"
        string created_by "user | llm (proposed)"
        string agent_name "the agent's API token name, when llm"
        text proposed_reason "an agent's reason"
        int replaces_id FK "the goal a proposal would change"
        datetime decided_at
    }
    coach_notes {
        int id PK
        int user_id FK
        string kind "status | focus | concern | note"
        string title
        text body
        string author_kind "user | human | llm"
        string author_name "a human coach's name, or the agent's API token name"
        date date "the day it is about"
        int activity_id FK "set null when deleted"
        int session_id FK "set null when deleted"
        int reply_to_id FK "the note a reply answers; deleted with it"
        datetime resolved_at "a concern's"
        text resolution
    }
    settings {
        int id PK
        int user_id FK,UK
        string unit "lb | kg"
        string distance_unit "km | mi"
    }
    users {
        int id PK
        string username UK "case-insensitive, 3-40 characters"
        bool owner "made the install"
        bool password_change_required "signed in with a temporary password"
        datetime welcomed_at "finished or skipped the welcome screen"
        datetime coach_seen_at "what agents did up to then was seen on Coach"
    }
    account_password_hashes {
        int id PK,FK "the user"
        string password_hash "Argon2id"
    }
    account_login_failures {
        int id PK,FK "the user"
        int number "wrong passwords in a row"
    }
    account_lockouts {
        int id PK,FK "the user"
        string key "unused: no unlock by email"
        datetime deadline "locked until"
        datetime email_last_sent "unused"
    }
    user_identities {
        int id PK
        int user_id FK
        string issuer UK "the OIDC provider (with subject, unique)"
        string subject "its sub for the person"
        string username "what the provider calls them"
        datetime last_used_at
    }
    api_tokens {
        int id PK
        int user_id FK
        string name "what it is for"
        string digest UK "SHA-256 of the token, shown once"
        datetime last_used_at "to the minute"
        string scope "mcp: /mcp alone (the default) | api: /api too"
        int user_identity_id FK "made on a device signed in with it, if any"
    }
    invites {
        int id PK
        string digest UK "SHA-256 of the token, shown once"
        string label "who it is for, as the owner put it; optional"
        datetime expires_at "7 days on; used or revoked, it is deleted"
    }
    account_active_session_keys {
        int id PK
        int account_id FK "the user"
        string session_id "HMAC of the cookie's key"
        string device "user agent at sign-in; signed in at created_at"
        datetime last_use
        int user_identity_id FK "the identity it signed in with, if any"
    }
```

## Six groups

- **Accounts:** `users`, and Rodauth's tables for signing in (`lib/auth_app.rb`):
  the password hash, kept apart so a query on users never carries one; wrong
  passwords in a row and the lockout they lead to; and one row per signed-in
  device. `user_identities` are the identities at the install's OpenID
  Connect provider that sign a user in (one per user and provider): a user
  has a password, an identity or both. A device signed in with one names
  it, as does a token made there, so unlinking the identity signs that
  device out and revokes the token.
  `api_tokens` let an assistant or a script in as the user (revoking deletes one).

- **Inventory:** the `equipment` catalogue, and what each exercise needs
  (`exercise_equipment`). An exercise with none is bodyweight. Steps can name
  extra gear (`step_equipment`). What a user owns, and which weights, is
  `user_equipment`.
- **Plan:** `programs` → `workouts` → `blocks` → `steps`, all the user's: a
  program is an example they imported (`db/examples`, copied on import), and
  a workout belongs to one or stands alone. A block is a circuit:
  every round runs its steps in order, per-side steps left then right.
  A main workout is framed by a warm-up and a cool-down: its own choice
  (`warmup_id` / `cooldown_id`, or none with `no_warmup` / `no_cooldown`),
  else its program's.
- **Log:** `sessions` → `set_logs` and one `completion`. A set log is
  self-contained (exercise planned and done, block, target), so history
  survives edits to the plan and swaps in the player.
- **Activities:** `activities`, runs and other sports as they happened, with
  the numbers as they were sent and nothing worked out from them. They sit
  beside sessions on the calendar.
- **Check-ins:** `check_ins`, what the user says about a day: the night
  that ended that morning (as Garmin dates sleep and overnight HRV) and how
  they felt that day, each optional. Context for the coach, nothing derived.
- **Routines:** `routines`, what the user means to do, tentatively: a sport or
  a workout, weekly or once. Their days are worked out when the calendar is
  read (`RoutineCalendar`); `routine_days` holds only the days the user
  changed, a workout routine's confirmed day is a planned session naming it,
  and an activity can be linked to a day by hand.
- **Plan changes:** `plan_changes`, one row per session or routine planned,
  moved, removed, changed or ended, by the user or an agent, with the fields
  before and after and the reason given. An undo is a row too, pointing at the
  change it takes back.
- **Coach board:** `goals` (what the user trains for; only they write active
  ones, an agent proposes) and `coach_notes` (status, focus, concerns and a
  journal, by the user, a coach they name, or an agent). The current status
  or focus is the newest note of its kind; nothing marks which replaced which.
- **Coach state:** `exercise_weights` (the remembered weight per exercise, which
  wins over a step's own weight in every workout; the user or the coach agent
  sets it, never the app) and `settings`.

## Who owns what

| Data | Comes from | Notes |
|------|-----------|-------|
| Exercises and the equipment catalogue | `db/seeds/*.yml`, loaded by `lib/seed_loader.rb` on every boot, shared | Matched by slug, updated in place so ids stay stable. |
| Programs and their workouts | Imported from `db/examples/*.yml` (`POST /api/examples/:slug/import`, MCP `import_example`), weights snapped to the user's gear | The user's from then on, like any workout of theirs; `example_slug` notes the example. Nothing is seeded. |
| `user_equipment` | The user, on the Equipment page | A new account owns nothing. |
| Workouts (`source: user` or `llm`) | Imported, duplicated, or built with `POST /api/workouts` (MCP marks its own `llm`) | Archived, never deleted. `PUT` rewrites their blocks and steps, keeping the step ids it names; steps it drops go, their logged sets stay. |
| Sessions, set logs, completions, weights, settings | The app, per user | Never touched by the seed loader. A logged set is never deleted by it. |
| Goals | The user, in the app | An agent only proposes one (MCP `propose_goal`): `proposed` until the user accepts or dismisses it; dismissed ones stay so it isn't proposed again. |
| Coach notes | The user or a coach they name in the app; an agent through MCP (`author_kind: llm`) | The agent changes, deletes and resolves only its own notes (at most 20 new a day); the app doesn't change an agent's note, but deletes it. |
| Activities | The app, or a script through `POST /api/activities`, or an agent through MCP `log_activities` (`created_by: llm`) | One from elsewhere is matched by `source` + `external_id` and updated in place; the person's `rpe` and `note` are never overwritten by a resend, and one the person logged (`manual`) is left as it is when a token resends it. |
| Check-ins | The user in the app (`PUT /api/check_ins/:date/night` or `/day`), or an agent through MCP `log_check_in` with what the user told it | The agent only fills fields left empty and never changes or clears what the user logged, today or up to 7 days back. |
| Routines | The app, or an agent through MCP (`created_by: llm`) | The agent changes and ends only its own, and never confirms, skips or moves a day. Days gone by never change: rescheduling one with past days ends it yesterday and starts a new one. |
| Plan changes | Written by the `Session` and `Routine` models on every change to the plan, whoever makes it | Kept for good. `llm` for a request or MCP call made with an API token. Only the latest change to an item is taken back, and only into a day not gone by (`POST /api/plan_changes/:id/undo`). |
| `users`, `invites` | The setup code (the owner), then the owner's invites | Removing a user removes everything of theirs. Invites belong to the install, not a user. |

## Rules worth knowing

- **Weights are in the gear's unit.** A remembered weight is kept in the
  unit the user's gear for the exercise comes in, a step's (and the sets
  logged for it) in that of the gear the step is done with, a goblet squat
  with a kettlebell in kg while the dumbbells are in lb (`user_equipment.unit`,
  which follows the lb/kg setting until weights are listed; `Step#gear_unit`).
  Every stored weight carries its unit and the API converts at the boundary
  (`app/models/weights.rb`). Relabelling an item's unit relabels the step and
  remembered weights that were one of its owned weights. The setting only
  changes what is shown.
- **Fixed-weight gear steps through owned weights** (`user_equipment.weights`);
  other gear steps by the increments in `config/coach.yml`.
- **The calendar is the sessions table.** A planned session is a day on the
  calendar; `position` orders a day (a new one goes last, and a move or delete
  renumbers the day 1..n). A planned session dated before today reads as
  `missed` but is stored as planned, so moving it to today or later plans it
  again. Only planned sessions move, and only to today or later; a done
  session keeps its status. Archiving a workout deletes its sessions still
  planned from today on, and ends the routines that run it.
- **A routine day is done by what happened.** An activity of the same sport
  family (`public/js/sports.json`: run, running and trail run are all runs) on
  the day it shows on, or one linked to it by hand (on that day or after); a workout routine's by its
  session, or a done session of its workout that day. One activity fulfils one
  day. Nothing fulfilling it, it reads as `missed` once its day has gone by. A
  moved day keeps its move when it is skipped or made tentative again.
- **An agent is named by its token.** What an agent writes over MCP
  (`created_by: llm`, or a note's `author_kind: llm`) carries the name of
  the API token it connected with (`agent_name`, a note's `author_name`), so
  the app shows one name for it everywhere; rows written before that have
  none and show a default.
- **The plan keeps its history.** Every change to a planned session (planned,
  moved to another day, removed while planned or missed, note or parts
  changed) or a routine (planned, changed, ended) is a `plan_changes` row,
  written by the models, so a session that goes because its workout was
  archived or its routine changed is recorded too. A routine day confirmed or
  made tentative, a session started, skipped or done, and a finished session
  deleted are not changes to the plan. Moving a session keeps its note: the
  reason goes on the change.
- **Distances are metres.** `distance_m` and `climb_m` are whole metres;
  `settings.distance_unit` (km or mi) only changes how they are shown.
- **Constraints live in the database too:** check constraints on `steps`,
  `blocks`, `workouts`, `programs`, `sessions`, `activities`, `goals`,
  `coach_notes`, `check_ins`, `routines`, `routine_days`, `plan_changes` and `settings`,
  a partial unique index on `activities (user_id, source, external_id)`,
  partial unique indexes on `sessions` and `activities (routine_id,
  routine_date)`, a
  unique index on `set_logs (session_id, step_ref, set_number, COALESCE(side, ''))`, and the
  composite foreign keys that keep a user's records to that user.
- **Schema changes are migrations; content changes are seeds and examples.**
  Never change exercises or programs in a migration.
