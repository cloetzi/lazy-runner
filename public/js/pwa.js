// Registers the service worker that keeps the app usable offline (see /sw.js).
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {
    // Not allowed here (e.g. plain http on another host): the app still works online.
  });
}
