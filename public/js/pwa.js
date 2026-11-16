// Registers the service worker that keeps the app usable offline (see /sw.js),
// and polishes the app added to the Home Screen.
if (globalThis.navigator && "serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {
    // Not allowed here (e.g. plain http on another host): the app still works online.
  });
}

// Safari on iOS shows :active (the pressed state in app.css) only when a
// touch listener is on the page.
globalThis.document?.addEventListener("touchstart", () => {}, { passive: true });

// The page background in each scheme (--bg in app.css, the theme-color in
// each page), which the app opens on.
export const BACKGROUNDS = { light: "#f6f5f2", dark: "#111418" };

// Safari on iPhone and iPad (the only browser with `navigator.standalone`)
// shows a startup image while an app on the Home Screen opens, and a white
// screen without one, bright in dark mode. It takes the image from the page
// as it is added, matched to the screen exactly, so the page draws its own:
// the background, for this screen in both orientations and both schemes. No
// image files to keep for every iPad and iPhone size. Each is a plain
// colour, so the app's first paint follows on without a flash.
export function startupImages({ width, height, ratio }) {
  const short = Math.round(Math.min(width, height) * ratio);
  const long = Math.round(Math.max(width, height) * ratio);
  return Object.entries(BACKGROUNDS).flatMap(([scheme, colour]) => [
    { media: `(orientation: portrait) and (prefers-color-scheme: ${scheme})`, width: short, height: long, colour },
    { media: `(orientation: landscape) and (prefers-color-scheme: ${scheme})`, width: long, height: short, colour },
  ]);
}

// Whether the app runs from the Home Screen (or installed elsewhere), not in
// a browser tab.
export function installed(nav = globalThis.navigator, media = globalThis.matchMedia) {
  return nav?.standalone === true || Boolean(media?.("(display-mode: standalone)").matches);
}

// The line Settings shows in a browser tab, recommending Add to Home Screen:
// an installed app opens full screen, and Safari doesn't clear its data (the
// outbox, a session under way) after seven days without a visit. Null once
// installed.
export function installHint(nav = globalThis.navigator, media = globalThis.matchMedia) {
  if (installed(nav, media)) return null;
  if (nav && "standalone" in nav) {
    return "Tap Share, then Add to Home Screen. The app then opens full screen from its icon, and Safari keeps its data, such as a session under way or changes waiting to sync, however long you're away.";
  }
  return "Install the app from the browser's menu (Install, or Add to Home screen). It then opens in its own window, and the browser keeps its data, such as a session under way.";
}

// Drawn once a visit: encoding four screen-size images takes a moment, and
// each page of the app would do it again.
function addStartupImages() {
  const images = startupImages({ width: screen.width, height: screen.height, ratio: devicePixelRatio || 1 });
  const key = `startup-images ${images[0].width}x${images[0].height}`;
  let hrefs = null;
  try {
    hrefs = JSON.parse(sessionStorage.getItem(key));
  } catch {
    // Blocked or unreadable: drawn again.
  }
  if (!Array.isArray(hrefs) || hrefs.length !== images.length) {
    const canvas = document.createElement("canvas");
    const context = canvas.getContext("2d");
    if (!context) return;
    hrefs = images.map((image) => {
      canvas.width = image.width;
      canvas.height = image.height;
      context.fillStyle = image.colour;
      context.fillRect(0, 0, image.width, image.height);
      return canvas.toDataURL("image/png");
    });
    try {
      sessionStorage.setItem(key, JSON.stringify(hrefs));
    } catch {
      // Full or blocked: drawn again on the next page.
    }
  }
  images.forEach((image, i) => {
    const link = Object.assign(document.createElement("link"), { rel: "apple-touch-startup-image", href: hrefs[i] });
    link.setAttribute("media", image.media);
    document.head.append(link);
  });
}

// Only in Safari's tab, where the app can be added, and after the page is up.
if (globalThis.document && "standalone" in navigator && !navigator.standalone) {
  addEventListener("load", () => setTimeout(addStartupImages, 1000), { once: true });
}
