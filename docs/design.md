# UI and design

The app is a tool used mid-workout: glanceable from two metres, usable with
one sweaty thumb, calm everywhere else.

## Principles

- **The player first.** One step per screen, a huge count, the exercise name
  and two to four cues, big Done and Skip buttons at the bottom, and a tap on
  the time to pause.
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
  current nav item, the up-next badge. *Done* is `--success` (done marks, the
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
- **Layout**: phones and iPads in portrait get a bottom tab bar (Today,
  Calendar, Coach, Workouts) with History, Exercises, Equipment and Settings
  under More; from 60rem a sidebar (`nav.js`, `routes.js`). Every page starts
  at the same left edge.
- **Accessibility in the smoke test**: `test/e2e/smoke.test.js` runs
  axe-core (WCAG A and AA, best practices) on the main screens and sheets.
- **Calendar marks**: done filled in `--success`, planned outlined, up next
  filled in `--accent`, missed dashed, skipped struck through (`.mark` in
  `app.css`).

## Exercise figures

A side-on mannequin drawn as SVG from keyframes on a shared skeleton
(`public/js/skeleton.json`). The format is documented in `public/js/figure.js`;
`figure-view.js` renders it; the seed loader rejects an animation that does
not fit the skeleton. It faces right; per-side moves are authored for the
left side and mirrored for the right; the moving limb is accented and the
target muscle highlighted.
`library.html?review` lays out every exercise for review.

In the player the figure sits above the text; on a short screen it gives way
first, then the cues. In landscape on a tablet or computer (at least 60rem
wide and 30rem tall) it sits beside the text instead, as tall as the stage,
and stays. Either way the drawing is scaled whole into its frame and never
overlaps the text.

A rest never shows a figure: its place holds the rest dial, a ring in
`--rest` that drains with the countdown around a slowly breathing disc
(still under reduced motion, dimmed with pause bars when paused).
