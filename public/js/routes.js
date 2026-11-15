// The app's pages and the URL hash of each view on the home page, kept free
// of the DOM so the routing is testable. `nav.js` draws PAGES as a bottom tab
// bar on phones, a rail on tablets and a sidebar on wide screens. On phones
// the pages marked `more` and the secondary ones sit under More; the rail and
// the sidebar list the secondary ones apart, at the bottom.

export const PAGES = [
  { id: "today", label: "Today", href: "/#today", icon: "today" },
  { id: "calendar", label: "Calendar", href: "/calendar.html", icon: "calendar" },
  { id: "coach", label: "Coach", href: "/coach.html", icon: "coach" },
  { id: "workouts", label: "Workouts", href: "/#workouts", icon: "workouts" },
  { id: "history", label: "History", href: "/#history", icon: "history", more: true },
  { id: "exercises", label: "Exercises", href: "/library.html", icon: "exercises", more: true },
  { id: "equipment", label: "Equipment", href: "/equipment.html", icon: "equipment", secondary: true },
  { id: "settings", label: "Settings", href: "/settings.html", icon: "settings", secondary: true },
];

// The tab bar's pages, the ones under More on phones, and the sidebar's two lists.
export const TABS = PAGES.filter((page) => !page.secondary && !page.more);
export const MORE = PAGES.filter((page) => page.secondary || page.more);
export const SIDEBAR = PAGES.filter((page) => !page.secondary);
export const SIDEBAR_SECONDARY = PAGES.filter((page) => page.secondary);

// Views that show one thing, named by the id after the slash.
const WITH_ID = new Set(["workout", "edit", "exercise-history", "session"]);

// "#workouts" -> { view: "workouts" }, "#workout/3" -> { view: "workout", id: "3" },
// "#edit/3" -> { view: "edit", id: "3" } (the editor; "#edit/new" builds a new one),
// "#exercise-history/5" -> { view: "exercise-history", id: "5" },
// "#session/9" -> { view: "session", id: "9" } (a past session),
// "#running" -> { view: "running" }: a running session's screens,
// "#examples" -> { view: "examples" }: Workouts with the example programs open.
// Anything unknown is the home page.
export function parseRoute(hash) {
  const [view, id] = (hash ?? "").replace(/^#\/?/, "").split("/");
  if (WITH_ID.has(view) && id) return { view, id };
  if (view === "workouts" || view === "history" || view === "running" || view === "examples") return { view };
  return { view: "home" };
}

// The hash for a view. The session screens share "#running", an entry of
// their own in the history, so the phone's back button stays in the app.
export function routeHash(view, id) {
  if (isSessionView(view)) return "#running";
  if (view === "home") return "#today";
  if (WITH_ID.has(view)) return `#${view}/${id}`;
  if (view === "workouts" || view === "history") return `#${view}`;
  return null;
}

export function isSessionView(view) {
  return view === "ready" || view === "player" || view === "finish";
}

// The sidebar entry a view belongs to.
export function pageFor(view) {
  return { home: "today", workout: "workouts", edit: "workouts", workouts: "workouts", history: "history", "exercise-history": "history", session: "history" }[view] ?? null;
}

// The name of each view on the home page: the tab's title, and what a Back
// button that returns to it says.
const VIEW_LABELS = {
  home: "Today", workouts: "Workouts", history: "History", workout: "Workout", "exercise-history": "Exercise", session: "Session",
  edit: "Edit workout", ready: "Get ready", player: "Workout", finish: "Done",
};
export function viewLabel(view) {
  return VIEW_LABELS[view] ?? null;
}
// The views a Back button returns to: not a session's screens (#running),
// the editor that saved the view, or the view itself.
const BACK_TO = new Set(["home", "workouts", "history", "workout", "exercise-history", "session"]);
// A detail's usual parent, for a direct link.
const PARENTS = { workout: "workouts", "exercise-history": "history", session: "history" };

// Where a detail view's Back button goes: the view it was opened from on
// this page (`cameFrom`, a hash), else the page of the app it was opened
// from (`referrer`, a URL on `origin`), else its usual parent. `inPage` says
// the target is a hash on the home page; `page` is the navigation entry to
// show as current.
export function backFor(view, { cameFrom = null, referrer = "", origin = "" } = {}) {
  const from = cameFrom ? parseRoute(cameFrom) : null;
  if (from && from.view !== view && BACK_TO.has(from.view)) {
    return { label: VIEW_LABELS[from.view], href: routeHash(from.view, from.id), page: pageFor(from.view), inPage: true };
  }
  const page = referrer ? pageAt(referrer, origin) : null;
  if (page) return { label: page.label, href: page.href, page: page.id, inPage: false };
  const parent = PARENTS[view] ?? "home";
  return { label: VIEW_LABELS[parent], href: routeHash(parent), page: pageFor(parent), inPage: true };
}

// The page of the app at `url`, another one than the home page.
function pageAt(url, origin) {
  try {
    const { origin: at, pathname } = new URL(url);
    return at === origin ? PAGES.find((page) => page.href === pathname) ?? null : null;
  } catch {
    return null;
  }
}
