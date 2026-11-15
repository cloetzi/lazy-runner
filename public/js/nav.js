import { PAGES, TABS, MORE, SIDEBAR, SIDEBAR_SECONDARY } from "./routes.js";
import { escape, icon } from "./html.js";
import { ACCOUNT_KEY, adoptAccount, checkSignedIn, signInHref } from "./account.js";
import { offline } from "./api.js";
import { localToday } from "./calendar.js";
import { fetchAhead } from "./offline.js";
import { createOutbox } from "./outbox.js";

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
// Signed in and online, the page fetches ahead what the app reads, so all
// of it opens offline (offline.js), once the page's own requests are out.
const RECHECK_MS = 5 * 60 * 1000;
const AHEAD_AFTER_MS = 2000;
let wasOffline = false;
let checkedAt = 0;
let checking = null;
function checkAccount(options) {
  // `online` and `visibilitychange` often come together: one check at a time.
  checking ??= askAccount(options).finally(() => { checking = null; });
  return checking;
}

const storage = (() => { try { return localStorage; } catch { return null; } })();

// A session screen is on (app.js sets data-focus, to an empty string).
const inSession = () => document.body.hasAttribute("data-focus");

async function askAccount({ again = false } = {}) {
  if (again && inSession()) return;
  checkedAt = Date.now();
  const me = await checkSignedIn({ storage, caches: globalThis.caches });
  if (again && inSession()) return;
  if (me.signedOut || me.user?.password_change_required) return location.assign(signInHref(location, { gate: me.gate }));
  if (!me.user) {
    wasOffline = true;
    showOffline();
    return;
  }
  wasOffline = false;
  showOffline();
  const { switched } = await adoptAccount(me.user, { storage, caches: globalThis.caches });
  if (switched) return location.reload();
  setTimeout(ahead, AHEAD_AFTER_MS);
  if (!again) keepData();
}

// Asks the browser to keep the outbox and a session under way through its
// clean-ups (Safari clears a site's data after seven days without a visit).
// Browsers decide on their own; Firefox asks the user, so at most once a
// day on this device.
const PERSIST_KEY = "persist-asked";
async function keepData() {
  try {
    if (!navigator.storage?.persist || (await navigator.storage.persisted())) return;
    if (storage?.getItem(PERSIST_KEY) === localToday()) return;
    storage?.setItem(PERSIST_KEY, localToday());
    await navigator.storage.persist();
  } catch {
    // Not offered here, or storage blocked.
  }
}

// Not in the middle of a session: its sets come first. Only once the
// service worker controls the page (on a first visit it takes over after
// installing), since it is what keeps the answers.
let fetching = null;
async function ahead() {
  if (fetching || inSession() || offline() || !(await controlled())) return;
  if (inSession() || offline()) return;
  fetching = fetchAhead({ storage, date: localToday(), halt: inSession }).finally(() => { fetching = null; });
}

let control = null;
function controlled() {
  const workers = navigator.serviceWorker;
  if (!workers) return Promise.resolve(false);
  if (workers.controller) return Promise.resolve(true);
  control ??= new Promise((resolve) => {
    workers.addEventListener("controllerchange", () => resolve(true), { once: true });
    setTimeout(() => resolve(Boolean(workers.controller)), 60_000);
  }).finally(() => { control = null; });
  return control;
}

// One quiet note in the top bar (phones) or the sidebar while the device is
// offline or the server is out of reach, with the changes waiting to sync.
let outbox = null;
let offlinePoll = null;
function showOffline() {
  const notes = document.querySelectorAll(".offline-badge");
  if (notes.length === 0) return;
  const shown = offline() || wasOffline;
  outbox ??= createOutbox({ storage, fetch: () => Promise.reject(new Error("read only")) });
  const pending = shown ? outbox.pending() : 0;
  const text = pending ? `Offline · ${pending} ${pending === 1 ? "change" : "changes"} waiting` : "Offline";
  // Written only when it changes: each write is read out again.
  for (const note of notes) {
    if (note.hidden !== !shown) note.hidden = !shown;
    if (note.textContent !== text) note.textContent = text;
  }
  // The page queues changes while offline: keep the count current.
  if (shown && !offlinePoll) offlinePoll = setInterval(showOffline, 5000);
  if (!shown && offlinePoll) offlinePoll = clearInterval(offlinePoll) ?? null;
}

// The app shell. On wide screens a sidebar with every page stays on the
// left. On phones a top bar names the page and a tab bar in thumb reach holds
// the main pages, with the rest (Exercises, Equipment, Settings) under More.
// Pages that run a session full screen hide it all with `body[data-focus]`.
export function mountNav(current) {
  checkAccount();
  addEventListener("online", () => {
    showOffline();
    if (wasOffline) checkAccount({ again: true });
  });
  addEventListener("offline", () => {
    wasOffline = true;
    showOffline();
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
      <span class="offline-badge" role="status" hidden></span>
    </header>
    <nav class="sidebar" id="sidebar" aria-label="Main">
      <p class="sidebar-brand">${icon("mark")}The Lazy Runner</p>
      <p class="sidebar-tagline">Strength for people who'd rather just run.</p>
      <p class="offline-badge" role="status" hidden></p>
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
  showOffline();

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
