# UI and design

The app is a tool used mid-workout: glanceable from two metres, usable with
one sweaty thumb, calm everywhere else.

## Principles

- **The player first.** One step per screen, a huge count, the exercise name
  and two to four cues, big Done and Skip buttons at the bottom, and a tap on
  the time to pause.
  Navigation hides during a session.
- **Never a blank state.** Today always offers a workout to start.
- **Light and dark** follow `prefers-color-scheme`; both are checked for every
  change, poses included.
- **Accessible by test**, not by hope: contrast pairs and theme colours are
  enforced in `test/js/contrast.test.js`; reduced motion shows a still frame.
- **No frameworks, no build step.** Plain HTML, CSS and ES modules.

## Design system

Everything lives in `public/css/app.css`, in this order: tokens, base,
components, pages, player, figure.

- **Tokens** (one `:root`, one dark override): colours (`--bg`, `--surface`,
  `--text`, `--muted`, `--accent` for fills and primary actions,
  `--accent-ink` / `--accent-tint` for quiet accents, `--rest` for rest
  screens, `--danger`), type (`--text-xs` to `--text-2xl`, `--display-*` for
  the player), spacing (`--space-1` to `--space-6`, 4px base), radii, and
  widths (`--measure` for reading pages, `--wide` for grids). A new rule uses
  the nearest token, never a raw value.
- **Components**: `.card`, `.list` / `.row`, `.segmented` (pressed state in
  `aria-pressed`), `.icon-button`, `.badge`, `.tag`. Icons come from
  `public/icons/sprite.svg` through `icon()` in `public/js/html.js`.
- **Taps register once**: every button, row and tab shows it is pressed at
  once (`:active`), hover styles apply only where a pointer hovers, and a
  button waiting on the server is `busy()` (`html.js`). In the player the
  main button ignores a tap for 0.7 s after its meaning changes, and the
  session screens neither zoom on a double tap nor select text.
- **The player speaks**: it redraws only what changed (`setText`, `setHtml`
  in `app.js`), the count carries its unit for a screen reader, and each
  step is said once in a polite live region (`stepAnnouncement` in
  `player.js`, the sentence spoken cues will use).
- **Layout**: phones get a bottom tab bar (Today, Calendar, Workouts,
  History) with Exercises, Equipment and Settings under More; from 60rem a
  sidebar (`nav.js`, `routes.js`).
- **Calendar marks**: done filled, planned outlined, up next filled in
  `--accent`, missed dashed, skipped struck through (`.mark` in `app.css`).

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
