// The app's pages and the URL hash of each view on the home page, kept free
// of the DOM so the routing is testable. `nav.js` draws PAGES as the sidebar
// on wide screens and as a bottom tab bar on phones. On phones the pages
// marked `more` and the secondary ones sit under More; the sidebar lists the
// secondary ones apart, below the others.

export const PAGES = [
  { id: "today", label: "Today", href: "/#today", icon: "today" },
  { id: "calendar", label: "Calendar", href: "/calendar.html", icon: "calendar" },
  { id: "coach", label: "Coach", href: "/coach.html", icon: "coach" },
  { id: "workouts", label: "Workouts", href: "/#workouts", icon: "workouts" },
  { id: "history", label: "History", href: "/#history", icon: "history", more: true },
  { id: "exercises", label: "Exercises", href: "/library.html", icon: "exercises", more: true },
  { id: "equipment", label: "Equipment", href: "/equipment.html", secondary: true },
  { id: "settings", label: "Settings", href: "/settings.html", secondary: true },
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
// "#running" -> { view: "running" }: a running session's screens.
// Anything unknown is the home page.
export function parseRoute(hash) {
  const [view, id] = (hash ?? "").replace(/^#\/?/, "").split("/");
  if (WITH_ID.has(view) && id) return { view, id };
  if (view === "workouts" || view === "history" || view === "running") return { view };
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
