import { PAGES, TABS, MORE, SIDEBAR, SIDEBAR_SECONDARY } from "./routes.js";
import { escape, icon } from "./html.js";
import { ACCOUNT_KEY, adoptAccount, checkSignedIn, signInHref } from "./account.js";

// Every page with the navigation is for someone signed in. Nobody signed in
// (or the device was signed out elsewhere, or something in front of the app
// wants a sign-in): the sign-in page, back here afterwards. Someone else
// than last time: forget the last one's things on this device and draw the
// page again. Offline: carry on with what is here. An installed app may stay
// open for days and has no reload button on iOS (#222), so the page asks
// again when the connection returns after it was offline, and when it comes
// back on screen after being offline or away for a while. Those later checks
// leave a session under way alone; its sets wait in the outbox.
// Signed in with a temporary password: the sign-in page asks for a new one.
const RECHECK_MS = 5 * 60 * 1000;
let wasOffline = false;
let checkedAt = 0;
let checking = null;
function checkAccount(options) {
  // `online` and `visibilitychange` often come together: one check at a time.
  checking ??= askAccount(options).finally(() => { checking = null; });
  return checking;
}

async function askAccount({ again = false } = {}) {
  if (again && document.body.dataset.focus) return;
  checkedAt = Date.now();
  const storage = (() => { try { return localStorage; } catch { return null; } })();
  const me = await checkSignedIn({ storage, caches: globalThis.caches });
  if (again && document.body.dataset.focus) return;
  if (me.signedOut || me.user?.password_change_required) return location.assign(signInHref(location, { gate: me.gate }));
  if (!me.user) {
    wasOffline = true;
    return;
  }
  wasOffline = false;
  const { switched } = await adoptAccount(me.user, { storage, caches: globalThis.caches });
  if (switched) location.reload();
}

// The app shell. On wide screens a sidebar with every page stays on the
// left. On phones a top bar names the page and a tab bar in thumb reach holds
// the main pages, with the rest (Exercises, Equipment, Settings) under More.
// Pages that run a session full screen hide it all with `body[data-focus]`.
export function mountNav(current) {
  checkAccount();
  addEventListener("online", () => {
    if (wasOffline) checkAccount({ again: true });
  });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") return;
    if (wasOffline || Date.now() - checkedAt > RECHECK_MS) checkAccount({ again: true });
  });
  // Signed in or out in another tab: this page shows someone else's things.
  addEventListener("storage", (event) => {
    if (event.key === ACCOUNT_KEY || event.key === null) location.reload();
  });
  const links = (pages) => pages
    .map((page) => `<li><a href="${page.href}" data-page="${page.id}">${escape(page.label)}</a></li>`).join("");
  const tabs = TABS
    .map((page) => `<a class="tab" href="${page.href}" data-page="${page.id}">${icon(page.icon)}<span>${escape(page.label)}</span></a>`).join("");

  document.body.classList.add("with-nav");
  document.body.insertAdjacentHTML("afterbegin", `
    <a class="skip-link" id="skip-link">Skip to content</a>
    <header class="topbar">
      <span class="topbar-brand">${icon("mark")}Lazy Runner</span>
      <span class="topbar-title" id="topbar-title" aria-hidden="true"></span>
    </header>
    <nav class="sidebar" id="sidebar" aria-label="Main">
      <p class="sidebar-brand">${icon("mark")}The Lazy Runner</p>
      <p class="sidebar-tagline">Strength for people who'd rather just run.</p>
      <ul>${links(SIDEBAR)}</ul>
      <ul class="sidebar-secondary">${links(SIDEBAR_SECONDARY)}</ul>
    </nav>
    <div class="scrim" id="scrim" hidden></div>
    <nav class="tabbar" id="tabbar" aria-label="Main">
      ${tabs}
      <ul class="more-sheet" id="more-sheet" hidden>${links(MORE)}</ul>
      <button class="tab" id="more-button" aria-controls="more-sheet" aria-expanded="false">${icon("more")}<span>More</span></button>
    </nav>`);

  const button = document.getElementById("more-button");
  const sheet = document.getElementById("more-sheet");
  const scrim = document.getElementById("scrim");
  const title = document.getElementById("topbar-title");

  const setOpen = (open) => {
    button.setAttribute("aria-expanded", String(open));
    sheet.hidden = !open;
    scrim.hidden = !open;
    if (open) sheet.querySelector("a")?.focus();
  };

  // Past the navigation to the view that shows. It points at that view's
  // main, but moves focus itself: on the home page the hash is the route.
  const skip = document.getElementById("skip-link");
  const shownMain = () => {
    const main = [...document.querySelectorAll("main")].find((element) => !element.hidden);
    if (main) main.id ||= "main";
    return main;
  };
  const aimSkip = () => {
    const main = shownMain();
    if (main) skip.setAttribute("href", `#${main.id}`);
  };
  aimSkip();
  skip.addEventListener("focus", aimSkip);
  skip.onclick = (event) => {
    event.preventDefault();
    const main = shownMain();
    if (!main) return;
    main.setAttribute("tabindex", "-1");
    main.focus();
  };

  button.onclick = () => setOpen(sheet.hidden);
  scrim.onclick = () => setOpen(false);
  sheet.addEventListener("click", (event) => {
    if (event.target.closest("a")) setOpen(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !sheet.hidden) {
      setOpen(false);
      button.focus();
    }
  });

  const setCurrent = (id) => {
    for (const link of document.querySelectorAll(".sidebar a, .tabbar a, .more-sheet a")) {
      if (link.dataset.page === id) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    }
    button.classList.toggle("current", MORE.some((page) => page.id === id));
    title.textContent = PAGES.find((page) => page.id === id)?.label ?? "";
  };
  setCurrent(current);

  // The top bar shows the brand; once the page's own title scrolls under it,
  // the title takes its place, as in native apps.
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.target.offsetParent) continue; // a hidden view
      title.textContent = entry.target.textContent;
      document.body.classList.toggle("title-in-bar", !entry.isIntersecting && entry.boundingClientRect.top < 0);
    }
  }, { rootMargin: "-56px 0px 0px 0px" });
  document.querySelectorAll(".brand h1").forEach((h1) => observer.observe(h1));
  return { setCurrent };
}
