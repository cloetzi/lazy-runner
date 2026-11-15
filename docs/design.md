# UI and design

The app is a tool used mid-workout: glanceable from two metres, usable with
one sweaty thumb, calm everywhere else.

## Principles

- **The player first.** One step per screen: the count is the screen, inside
  a ring that drains, with the exercise name, a badge for the phase and the
  side, two cues, big Done and Skip buttons at the bottom, and a tap on the
  count to pause.
  Navigation hides during a session and in the workout editor, which has
  its own header (Cancel, the name, Save) so a stray tap can't lose a draft.
- **Never a dead end.** Today offers a workout to start, or, for an account
  with none yet, the example programs and the editor.
- **Gear is never told by colour alone.** Gear the user doesn't own has a
  dashed outline, a cross and "not yours yet" (`gear.js`), with the ways out
  beside a step that needs it: "I have this" and Swap.
- **Light and dark** follow `prefers-color-scheme`; both are checked for every
  change, poses included.
- **Accessible by test**, not by hope: contrast pairs and theme colours are
  enforced in `test/js/contrast.test.js`; reduced motion shows a still frame.
- **No frameworks, no build step.** Plain HTML, CSS and ES modules.

## Design system

Everything lives in `public/css/app.css`, in this order: tokens, base,
components, pages, player, figure.

- **Tokens** (one `:root`, one dark override, and an Increase Contrast
  override for each): colours (`--bg`, `--surface`, `--text`, `--muted`,
  `--accent` for fills and primary actions, `--accent-ink` / `--accent-tint`
  for quiet accents, `--link` for links, `--rest` for rest screens,
  `--success`, `--warning` and `--danger` (the first two with an ink and a
  tint), and the figure's `--figure*`, `--accent-far` and `--prop`), type
  (`--text-xs` to `--text-2xl`, `--display-*` for the player), spacing
  (`--space-1` to `--space-6`), control heights (`--control-sm`, `-md`,
  `-lg`), radii, and widths (`--measure` for every page, `--wide` for grids
  beside the sidebar). A new rule uses the nearest token, never a raw value.
- **The root is 17px**, on purpose (`html { font-size: 106.25% }`): every rem
  and token is measured against it, so `--space-1` is 4.25px and body text
  (`--text-md`) 18px. Media queries use the browser's 16px, so `60rem` there
  is 960px.
- **Colour roles**: orange has one job. *Action* is solid `--accent`, at most
  one per view or sheet (the first waiting proposal on Coach, the up-next
  workout's Start). *Now* is `--accent-ink` on `--accent-tint`: today, the
  current nav item, the up-next badge. *Done* is `--success` (Today's done marks, the
  finish badge, achieved goals), *watch out* is `--warning` (sync problems,
  open concerns, changed gear), and `--danger` is for deleting and for
  errors.
  Everything else (plus buttons, sheet icons, disclosure arrows) is neutral.
- **Buttons**: three kinds, `.primary`, `.secondary` and `.quiet` (no
  outline, text colour, for small actions such as Edit or Tidy up), in three
  sizes, `.small`, the default and `.large`, each a control height with its
  own type size; nothing tappable is under `--control-sm` (about 47px) but
  the month grid's date, whose whole day cell takes the tap. `.large`
  is for the session screens and a page's one main action. Underlined text
  (`a.link`, in `--link`) is only for links that go somewhere. Anything that
  deletes or discards adds `.danger` (danger ink, a danger outline on a
  secondary) and sits apart from the safe actions: under a hairline at the
  end of a sheet (`.danger-zone`), or at the far end of a row.
- **Headings**: one `h1` per view (the exercise name in the player), card
  and section titles `h2`, nothing skipped. A sheet opens with `showSheet()`
  (`html.js`), which names it by its heading.
- **Components**: `.card`, `.list` / `.row`, `.icon-button`, `.badge`,
  `.tag`. Icons come from `public/icons/sprite.svg` through `icon()` in
  `public/js/html.js`.
- **Fields**: every input, select and textarea gets one look from the base
  styles, so a form needs no CSS of its own. A `.field` wraps the label (or
  a `.field-label`), the control, a muted hint and a `.form-error`.
- **Selection, two ways**: one of a few is the `.segmented` control (buttons
  with `aria-pressed`, or labels around radios), the chosen one raised; it
  never stretches unless it is `.fill`, and scrolls sideways when it runs
  out of room. Any of several is a check: a native box in lists, in the text
  colour, and `.check-chips` (the weekdays) for compact choices, a tint with
  the accent ink and a tick. Navigation keeps its own current item; solid
  orange never means chosen.
- **Taps register once**: every button, row and tab shows it is pressed at
  once (`:active`), hover styles apply only where a pointer hovers, and a
  button waiting on the server is `busy()` (`html.js`). In the player the
  main button ignores a tap for 0.7 s after its meaning changes, and the
  session screens neither zoom on a double tap nor select text.
- **One action bar** (`.action-bar`): the screen's primary pinned to the
  bottom over the page background, at the end of the page so the last row
  scrolls clear of it; Get ready and the workout view use it.
- **The player speaks**: it redraws only what changed (`setText`, `setHtml`
  in `app.js`), the count carries its unit for a screen reader, and each
  step is said once in a polite live region (`stepAnnouncement` in
  `player.js`, the sentence spoken cues will use).
- **Layout** (`nav.js`, `routes.js`): phones get a top bar naming the page
  and a bottom tab bar (Today, Calendar, Coach, Workouts) with History,
  Exercises, Equipment and Settings under More; from 44rem on a screen at
  least 48rem tall (an iPad in portrait, not a phone on its side) a rail on
  the left with every page, an icon over its name; from 60rem a sidebar, the
  icon beside the name. Who is signed in shows at the
  foot of the rail and the sidebar and at the head of More, and opens
  Settings. Every page starts at the same left edge.
- **Back goes where you came from**: a detail's Back button names and
  returns to the view it was opened from, else the page that linked to it
  (Exercises, Calendar), else its usual parent (`backFor`); through the
  browser's history when that is where it came from. The
  tab's title names the view, and a view that replaces another moves the
  focus to its heading.
- **Accessibility in the smoke test**: `test/e2e/smoke.test.js` runs
  axe-core (WCAG A and AA, best practices) on the main screens and sheets.
- **Calendar marks**: one tile for every item, a session's with the
  workouts icon, an activity's or a routine day's with its sport's
  (`.sport-tile` in `app.css`): dashed is Maybe, outlined is Planned, filled
  in `--accent` is Up next, filled in the text colour is Done, faded and
  struck is Skipped or Missed; an agent's plan has a dot on the tile's
  corner in the month. The Key sheet beside the page title explains them, from the week
  and the month. The month grid takes the full width with the selected day
  under it; its chips say what and how much ("Run 9.4 km", "Session B"),
  and a cell under 6rem wide (a container query) shows the tiles alone.

## Exercise figures

A side-on mannequin drawn as SVG from keyframes on a shared skeleton
(`public/js/skeleton.json`). The format is documented in `public/js/figure.js`;
`figure-view.js` renders it; the seed loader rejects an animation that does
not fit the skeleton. It faces right; per-side moves are authored for the
left side and mirrored for the right; the moving limb is accented and the
target muscle highlighted.
`library.html?review` lays out every exercise for review.

## The player

The stage is a size container: the ring, the name and the figure are
measured against the room it has, not the window.

- **The count in its ring**, about a third of the stage's height in a column
  and as tall as the stage in landscape. The ring drains for holds, lead-ins
  and rests; a set of reps shows its number without one but keeps the place.
  Longer counts and words step down a size (`data-len`) to stay inside.
- **One colour per phase**, on the ring and the phase badge, which always
  says its word: neutral for Get ready, the accent tint for Go and Switch
  sides, `--rest` for Rest. The side is a badge with a large L or R; the set
  is a badge too.
- **Fixed places**: the figure is a fixed share of the stage and the badge
  row keeps its height, so the ring doesn't move between phases. When the
  stage runs out of room the cues at the bottom go first (cut whole, never
  in half), then the figure shrinks down to 10rem; under that it is hidden
  rather than shrunk to a stamp. As a last resort the stage scrolls, with a
  shadow at the edge that has more.
- **Landscape on a tablet or computer** (at least 60rem wide and 30rem tall):
  three columns, the figure with one cue, the ring as tall as the stage
  allows, and the name, badges, buttons and steppers beside it.
- **A set of reps** counts what was done: − and + of 4rem either side of
  the number, which reads "7" over "of 8" once changed.
- **The load line** is a card of its own: the gear and its weight
  ("Kettlebell, 40 lb"), then − and + at `--control-md`.
- **The progress bar fills by time**, not by screens (`progressAt`).

A rest prepares the next set: "Up next · set 2 of 3" over the exercise's
name, its reps and tempo, its load line, and How to and Swap for it (both
pause the rest, and Resume carries on; a swap there changes the sets to come
and stays in the rest). The figure is that exercise standing still (a
moving one reads as "do this now"); the ring is in `--rest` around a slowly
breathing core (still under reduced motion), dimmed when paused, with
"Paused" in place of the unit.
