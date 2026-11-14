// Reads from the API. `stale` is true when the service worker answered from
// its cache because the server was out of reach, so a view can say it is
// showing an offline copy.
export async function getJson(path, fetchFn = fetch) {
  const response = await fetchFn(path);
  if (!response.ok) {
    let code;
    try {
      code = (await response.json())?.error?.code;
    } catch {
      // Not the API's JSON error (a proxy's page, say).
    }
    throw Object.assign(new Error(`HTTP ${response.status}`), { status: response.status, code });
  }
  return { data: await response.json(), stale: response.headers.get("x-served-from") === "cache" };
}

// Writes to the API. Every write goes through here or the outbox, so each
// sends what the server's CSRF check wants: a JSON body (or none), from this
// page's origin (the browser adds Sec-Fetch-Site and Origin), and Accept so
// the sign-in routes answer in JSON.
// `user` is the id of the user the change is for (the outbox's entries): the
// server refuses it, 409 user_mismatch, when someone else is signed in.
// `redirect: "manual"` keeps a sign-in page in front of the app from
// passing for the app's answer.
export function send(path, { method = "POST", body, fetchFn = fetch, user, redirect } = {}) {
  const headers = body === undefined ? { Accept: "application/json" } : { "Content-Type": "application/json", Accept: "application/json" };
  if (user != null) headers["X-Lazy-Runner-User"] = String(user);
  return fetchFn(path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    ...(redirect ? { redirect } : {}),
  });
}

// Sends a change now (not through the outbox), for a sheet that stays open
// until it is saved: resolves to the problem to show, or null once the
// server has taken it.
export async function sendChange({ method, path, body }, fetchFn = fetch) {
  try {
    const response = await send(path, { method, body, fetchFn });
    if (response.ok) return null;
    let json = null;
    try {
      json = await response.json();
    } catch {
      // Not the API's JSON error.
    }
    return errorMessage(json, response.status);
  } catch {
    return "Can't reach the server. Try again once you're online.";
  }
}

// The sentence an API error carries: every error is
// { error: { code, message, fields? } }.
export function errorMessage(json, status) {
  return json?.error?.message ?? `HTTP ${status}`;
}

// The note a view shows over an offline copy.
export const STALE_NOTE = "Offline copy: this may be out of date.";
