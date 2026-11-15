import { preferredUnit, setPreferredUnit, adoptServerUnit, unitRequest } from "./weights.js";
import { LEAD_IN_CHOICES, readSettings, writeSetting } from "./preferences.js";
import { GEAR_LEAD_IN } from "./player.js";
import { preferredDistanceUnit, setPreferredDistanceUnit, adoptServerDistanceUnit, distanceUnitRequest } from "./activities.js";
import { createOutbox } from "./outbox.js";
import { storedAccount, pageAccount, signOut, signOutHere, deviceName, startOidc, oidcOutcome } from "./account.js";
import { getJson, send, errorMessage } from "./api.js";
import { escape, busy } from "./html.js";
import { mountNav } from "./nav.js";
import { mountExamples } from "./example-list.js";

// The Settings page: each choice is a segmented control, saved as soon as it
// is tapped. Units are kept on the server for every device (through the
// outbox, so a change made offline is sent later) and copied here; the rest
// are kept on this device.

const storage = (() => {
  try {
    return localStorage;
  } catch {
    return null; // blocked: the defaults show and nothing is kept
  }
})();

const units = document.getElementById("units");
const distanceUnits = document.getElementById("distance-units");
const leadIn = document.querySelector('[data-setting="leadIn"]');
document.getElementById("gear-lead-in").textContent = GEAR_LEAD_IN;
leadIn.innerHTML = LEAD_IN_CHOICES.map((seconds) => `<button data-value="${seconds}">${seconds} s</button>`).join("");

if (!("vibrate" in navigator)) {
  document.querySelector('[data-setting="vibration"]').hidden = true;
  document.getElementById("vibration-unsupported").hidden = false;
}

const press = (group, value) => {
  for (const button of group.querySelectorAll("[data-value]")) {
    button.setAttribute("aria-pressed", String(button.dataset.value === String(value)));
  }
};

function render() {
  press(units, preferredUnit(storage));
  press(distanceUnits, preferredDistanceUnit(storage));
  const settings = readSettings(storage);
  for (const group of document.querySelectorAll("[data-setting]")) press(group, settings[group.dataset.setting]);
}

const outbox = storage && createOutbox({ storage, fetch: (...args) => fetch(...args), locks: navigator.locks, user: pageAccount(storage).id });

units.onclick = (event) => {
  const value = event.target.closest("[data-value]")?.dataset.value;
  if (!value) return;
  setPreferredUnit(storage, value);
  render();
  if (outbox) {
    outbox.enqueue(unitRequest(value));
    outbox.flush();
  } else {
    send("/api/settings", { method: "PATCH", body: { unit: value } }).catch(() => {});
  }
};

distanceUnits.onclick = (event) => {
  const value = event.target.closest("[data-value]")?.dataset.value;
  if (!value) return;
  setPreferredDistanceUnit(storage, value);
  render();
  if (outbox) {
    outbox.enqueue(distanceUnitRequest(value));
    outbox.flush();
  } else {
    send("/api/settings", { method: "PATCH", body: { distance_unit: value } }).catch(() => {});
  }
};

// The server's units win over this device's copies, unless a change is queued.
async function loadUnit() {
  try {
    const { data, stale } = await getJson("/api/settings");
    adoptServerUnit(storage, data.unit, { queued: outbox?.queued() ?? [], stale });
    adoptServerDistanceUnit(storage, data.distance_unit, { queued: outbox?.queued() ?? [], stale });
    render();
  } catch {
    // Offline: the copy on this device shows.
  }
}

for (const group of document.querySelectorAll("[data-setting]")) {
  group.onclick = (event) => {
    const value = event.target.closest("[data-value]")?.dataset.value;
    if (value == null) return;
    writeSetting(storage, group.dataset.setting, JSON.parse(value));
    render();
  };
}

// ---------- Account ----------

const $ = (id) => document.getElementById(id);

function showError(element, message) {
  element.textContent = message ?? "";
  element.hidden = !message;
}

function renderAccount() {
  const account = storedAccount(storage);
  $("account-who").innerHTML = account ? `Signed in as <strong>${escape(account.username)}</strong>.` : "Signed in.";
}

$("sign-out").onclick = async () => {
  const pending = outbox?.pending() ?? 0;
  if (pending > 0) {
    const changes = `${pending} ${pending === 1 ? "change" : "changes"}`;
    if (!confirm(`${changes} on this device haven't synced yet. Signing out deletes them. Sign out anyway?`)) return;
  }
  showError($("account-error"), null);
  const outcome = await signOut({ storage, caches: globalThis.caches });
  if (outcome === "done") return location.assign("/signin.html");
  // No server to sign out with (offline, or something in front of the app
  // answers instead): this device can still let go, so it isn't stuck on
  // the last user's copies, and tells the server once it can (#222).
  const unreachable = "Couldn't reach the server to sign out. Sign out on this device now? It forgets your account and any unsynced changes here, and signs out on the server once it can reach it.";
  if (outcome === "refused" || !confirm(unreachable)) {
    return showError($("account-error"), outcome === "refused" ? "The server didn't sign you out. Reload the page and try again." : "Couldn't reach the server to sign out. Try again when you're online.");
  }
  await signOutHere({ storage, caches: globalThis.caches });
  location.assign("/signin.html?gate=1");
};

const passwordForm = $("change-password");
$("change-password-open").onclick = () => {
  passwordForm.hidden = !passwordForm.hidden;
  $("change-password-open").setAttribute("aria-expanded", String(!passwordForm.hidden));
  if (!passwordForm.hidden) (hasPassword ? passwordForm.elements.password : passwordForm.elements.new_password).focus();
};

// Someone who signs in only with the OIDC provider has no current password
// to give: the form sets one.
let hasPassword = true;
function renderPasswordForm() {
  const current = passwordForm.elements.password;
  current.closest(".form-field").hidden = !hasPassword;
  current.required = hasPassword;
  const label = hasPassword ? "Change password" : "Set a password";
  $("change-password-open").textContent = label;
  passwordForm.querySelector("button[type=submit]").textContent = label;
}

passwordForm.onsubmit = async (event) => {
  event.preventDefault();
  const error = passwordForm.querySelector(".form-error");
  const button = passwordForm.querySelector("button[type=submit]");
  const { password, new_password, sign_out_others } = passwordForm.elements;
  const others = sign_out_others.checked;
  showError(error, null);
  busy(button);
  try {
    const response = await send("/api/auth/change-password", {
      body: { ...(hasPassword ? { password: password.value } : {}), new_password: new_password.value, sign_out_others: others },
    });
    const json = await response.json().catch(() => null);
    if (!response.ok) return showError(error, errorMessage(json, response.status));
    passwordForm.reset();
    passwordForm.hidden = true;
    $("change-password-open").setAttribute("aria-expanded", "false");
    const done = hasPassword ? "Password changed" : "Password set";
    $("account-who").insertAdjacentHTML("beforeend", others
      ? ` ${done}; your other devices are signed out and your API tokens revoked.`
      : ` ${done}.`);
    loadDevices();
    loadTokens();
    loadIdentities();
  } catch {
    showError(error, "Couldn't reach the server. Try again when you're online.");
  } finally {
    busy(button, false);
  }
};

const lastUsed = (time) => {
  const date = new Date(time);
  if (Number.isNaN(date.getTime())) return "";
  return date.toDateString() === new Date().toDateString()
    ? "used today"
    : `last used ${date.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" })}`;
};

async function loadDevices() {
  let devices;
  try {
    const { data, stale } = await getJson("/api/account/devices");
    if (stale) throw new Error("offline");
    devices = data.devices;
  } catch {
    $("devices").innerHTML = `<li class="muted">The list shows when the server is reachable.</li>`;
    $("sign-out-others").hidden = true;
    return;
  }
  $("devices").innerHTML = devices.map((device) => `
    <li>
      <span class="device-name">${escape(deviceName(device.device))}${device.current ? " <strong>(this device)</strong>" : ""}<br>
        <span class="muted">${escape(lastUsed(device.last_used_at))}</span></span>
      ${device.current ? "" : `<button class="secondary small danger" data-sign-out-device="${device.id}">Sign out</button>`}
    </li>`).join("");
  $("sign-out-others").hidden = !devices.some((device) => !device.current);
}

$("devices").onclick = async (event) => {
  const id = event.target.closest("[data-sign-out-device]")?.dataset.signOutDevice;
  if (!id) return;
  await send(`/api/account/devices/${id}`, { method: "DELETE" }).catch(() => {});
  loadDevices();
};

$("sign-out-others").onclick = async () => {
  await send("/api/account/devices", { method: "DELETE" }).catch(() => {});
  loadDevices();
};

// ---------- Users and invites (the owner's) ----------

// Copies a shown secret, else selects it for the user to copy.
async function copyFrom(container, button) {
  const input = container.querySelector("input");
  try {
    await navigator.clipboard.writeText(input.value);
    button.textContent = "Copied";
  } catch {
    input.select();
  }
}

function reveal(container, value) {
  container.hidden = false;
  const input = container.querySelector("input");
  input.value = value;
  input.select();
  container.querySelector("button").textContent = "Copy";
}

// Sends an owner's change; the error, if any, shows in the Users card.
async function ownerSend(path, options) {
  showError($("users-error"), null);
  try {
    const response = await send(path, options);
    const json = response.status === 204 ? null : await response.json().catch(() => null);
    if (!response.ok) {
      showError($("users-error"), errorMessage(json, response.status));
      return null;
    }
    return json ?? {};
  } catch {
    showError($("users-error"), "Couldn't reach the server. Try again when you're online.");
    return null;
  }
}

const joined = (time) => {
  const date = new Date(time);
  return Number.isNaN(date.getTime()) ? "" : `joined ${date.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" })}`;
};

async function loadUsers() {
  let users;
  let invites;
  try {
    const [usersAnswer, invitesAnswer] = await Promise.all([getJson("/api/users"), getJson("/api/invites")]);
    if (usersAnswer.stale || invitesAnswer.stale) throw new Error("offline");
    users = usersAnswer.data.users;
    invites = invitesAnswer.data.invites;
  } catch (error) {
    // Not the owner after all (the server decides): no card.
    if (error.status === 403) return ($("users").hidden = true);
    $("user-list").innerHTML = `<li class="muted">The list shows when the server is reachable.</li>`;
    $("invite-list").innerHTML = "";
    return;
  }
  const me = storedAccount(storage)?.id;
  $("user-list").innerHTML = users.map((user) => `
    <li>
      <span class="device-name"><strong>${escape(user.username)}</strong>${user.id === me ? " (you)" : ""}<br>
        <span class="muted">${escape([user.owner ? "owner" : "", user.password_change_required ? "temporary password" : "", joined(user.created_at)].filter(Boolean).join(" · "))}</span></span>
      ${user.id === me ? "" : `<span class="account-actions">
        <button class="secondary small" data-reset-user="${user.id}" data-name="${escape(user.username)}">Reset password</button>
        <button class="secondary small danger" data-remove-user="${user.id}" data-name="${escape(user.username)}">Remove</button>
      </span>`}
    </li>`).join("");
  const until = (time) => new Date(time).toLocaleDateString(undefined, { day: "numeric", month: "short" });
  $("invite-list").innerHTML = invites.length === 0
    ? `<li class="muted">No invites waiting.</li>`
    : invites.map((invite) => `
    <li>
      <span class="device-name">Invite link<br><span class="muted">works until ${escape(until(invite.expires_at))}</span></span>
      <button class="secondary small danger" data-revoke-invite="${invite.id}">Revoke</button>
    </li>`).join("");
}

$("user-list").onclick = async (event) => {
  const reset = event.target.closest("[data-reset-user]");
  const remove = event.target.closest("[data-remove-user]");
  if (reset) {
    const name = reset.dataset.name;
    if (!confirm(`Reset ${name}'s password? They are signed out everywhere and their API tokens revoked; they sign in with a temporary password you give them.`)) return;
    const json = await ownerSend(`/api/users/${reset.dataset.resetUser}/password`, { body: {} });
    if (json) {
      $("temporary-password-who").textContent = name;
      $("temporary-password").dataset.user = reset.dataset.resetUser;
      reveal($("temporary-password"), json.password);
    }
  } else if (remove) {
    const name = remove.dataset.name;
    if (!confirm(`Remove ${name} and everything of theirs: workouts, sessions, gear and settings? This can't be undone.`)) return;
    const removed = await ownerSend(`/api/users/${remove.dataset.removeUser}`, { method: "DELETE" });
    // The temporary password shown is moot once its user is gone; another's stays.
    if (removed && $("temporary-password").dataset.user === remove.dataset.removeUser) $("temporary-password").hidden = true;
  } else {
    return;
  }
  loadUsers();
};

$("invite-list").onclick = async (event) => {
  const id = event.target.closest("[data-revoke-invite]")?.dataset.revokeInvite;
  if (!id) return;
  if (!confirm("Revoke this invite? Its link stops working.")) return;
  await ownerSend(`/api/invites/${id}`, { method: "DELETE" });
  loadUsers();
};

$("new-invite").onclick = async () => {
  busy($("new-invite"));
  const json = await ownerSend("/api/invites", { body: {} });
  busy($("new-invite"), false);
  if (!json) return;
  reveal($("new-invite-link"), new URL(json.path, location.origin).href);
  loadUsers();
};

$("copy-invite").onclick = () => copyFrom($("new-invite-link"), $("copy-invite"));
$("copy-temporary-password").onclick = () => copyFrom($("temporary-password"), $("copy-temporary-password"));

// The owner's, as this device knows (or, with storage blocked, as the server
// answers: anyone else gets a 403, which hides the card again).
if (!storage || storedAccount(storage)?.owner) {
  $("users").hidden = false;
  loadUsers();
}

// ---------- Signing in with the OIDC provider ----------

// What came back from linking at the provider (`?oidc=`), shown once.
const oidcResult = new URLSearchParams(location.search).get("oidc");
if (oidcResult) history.replaceState(null, "", `${location.pathname}${location.hash}`);

async function loadIdentities() {
  const section = $("identities");
  let data;
  try {
    let stale;
    ({ data, stale } = await getJson("/api/account/identities"));
    if (stale) return; // An offline copy may be out of date: leave the forms as they are.
  } catch {
    return; // Offline, or no provider to show: the section stays as it is.
  }
  hasPassword = data.password;
  renderPasswordForm();
  if (!data.provider) return;
  const provider = data.provider.name;
  section.hidden = false;
  $("identities-title").textContent = `Sign in with ${provider}`;
  const linked = data.identities.some((identity) => identity.current);
  // A change of password signing out the other devices unlinks these too.
  $("sign-out-others-label").textContent = data.identities.length > 0
    ? "Sign out my other devices, revoke my API tokens and unlink my sign-ins"
    : "Sign out my other devices and revoke my API tokens";
  $("identities-note").textContent = linked
    ? `This account signs in with ${provider}${data.password ? " or its password" : ""}.`
    : `Link your ${provider} sign-in to use it instead of a password.`;
  // The only way in can't be unlinked: set a password first.
  const canUnlink = (identity) => data.password || !identity.current;
  $("identity-list").innerHTML = data.identities.map((identity) => `
    <li>
      <span class="device-name">${escape(identity.username ?? provider)}<br>
        <span class="muted">${escape(identity.last_used_at ? lastUsed(identity.last_used_at) : "never used")}</span></span>
      ${canUnlink(identity) ? `<button class="secondary small danger" data-unlink="${identity.id}">Unlink</button>` : ""}
    </li>`).join("");
  $("link-identity").textContent = `Link ${provider}`;
  $("link-identity").hidden = linked;
  if (oidcResult && !$("identities-outcome").dataset.shown) {
    const { ok, message } = oidcOutcome(oidcResult, provider);
    $("identities-outcome").dataset.shown = "1";
    if (ok) {
      $("identities-outcome").textContent = message;
      $("identities-outcome").hidden = false;
    } else {
      showError(section.querySelector(".form-error"), message);
    }
  }
}

$("link-identity").onclick = async () => {
  const button = $("link-identity");
  const error = $("identities").querySelector(".form-error");
  showError(error, null);
  busy(button);
  try {
    location.assign(await startOidc({ next: "/settings.html" }));
  } catch (failure) {
    showError(error, failure instanceof TypeError ? "Couldn't reach the server. Try again when you're online." : failure.message);
    busy(button, false);
  }
};

$("identity-list").onclick = async (event) => {
  const button = event.target.closest("[data-unlink]");
  if (!button) return;
  if (!confirm("Unlink this sign-in? It won't sign you in any more.")) return;
  const error = $("identities").querySelector(".form-error");
  showError(error, null);
  $("identities-outcome").hidden = true;
  try {
    const response = await send(`/api/account/identities/${button.dataset.unlink}`, { method: "DELETE" });
    if (!response.ok && response.status !== 404) {
      const json = await response.json().catch(() => null);
      showError(error, errorMessage(json, response.status));
    }
  } catch {
    showError(error, "Couldn't reach the server. Try again when you're online.");
  }
  loadIdentities();
};

// ---------- Example programs ----------

const examples = mountExamples({ list: $("example-list"), error: $("examples-error"), done: $("examples-done") });

// ---------- API tokens ----------

async function loadTokens() {
  // A list asked for before the secret was shown can't know its token yet.
  const shown = shownTokenId;
  let tokens;
  try {
    const { data, stale } = await getJson("/api/account/tokens");
    if (stale) throw new Error("offline");
    tokens = data.tokens;
  } catch {
    $("tokens").innerHTML = `<li class="muted">The list shows when the server is reachable.</li>`;
    return;
  }
  // Revoked here or elsewhere: the secret on show is no use any more.
  if (shown && shown === shownTokenId && !tokens.some((token) => String(token.id) === shown)) hideSecret();
  $("tokens").innerHTML = tokens.length === 0
    ? `<li class="muted">No tokens yet.</li>`
    : tokens.map((token) => `
    <li>
      <span class="device-name">${escape(token.name)}<br>
        <span class="muted">${escape(token.last_used_at ? lastUsed(token.last_used_at) : "never used")}</span></span>
      <button class="secondary small danger" data-revoke-token="${token.id}" data-name="${escape(token.name)}">Revoke</button>
    </li>`).join("");
}

$("tokens").onclick = async (event) => {
  const button = event.target.closest("[data-revoke-token]");
  if (!button) return;
  if (!confirm(`Revoke "${button.dataset.name}"? Whatever uses it stops working at once.`)) return;
  const error = tokenForm.querySelector(".form-error");
  showError(error, null);
  // Not through the outbox: a revoke has to be known to have worked.
  try {
    const response = await send(`/api/account/tokens/${button.dataset.revokeToken}`, { method: "DELETE" });
    if (!response.ok && response.status !== 404) {
      const json = await response.json().catch(() => null);
      showError(error, `Not revoked: ${errorMessage(json, response.status)}. It still works.`);
    }
  } catch {
    showError(error, "Not revoked: couldn't reach the server. It still works; try again when you're online.");
  }
  loadTokens();
};

// The token whose secret is on show (and in the MCP command), if any.
let shownTokenId = null;

function hideSecret() {
  shownTokenId = null;
  $("new-token-secret").hidden = true;
  $("new-token-secret").querySelector("input").value = "";
  $("copy-token").textContent = "Copy";
  showMcpCommand();
}

const tokenForm = $("new-token");
tokenForm.onsubmit = async (event) => {
  event.preventDefault();
  const error = tokenForm.querySelector(".form-error");
  const button = tokenForm.querySelector("button[type=submit]");
  showError(error, null);
  busy(button);
  try {
    const response = await send("/api/account/tokens", { body: { name: tokenForm.elements.name.value } });
    const json = await response.json().catch(() => null);
    if (!response.ok) return showError(error, errorMessage(json, response.status));
    tokenForm.reset();
    hideSecret();
    $("new-token-secret").hidden = false;
    $("new-token-secret").querySelector("input").value = json.secret;
    $("new-token-secret").querySelector("input").select();
    shownTokenId = String(json.token.id);
    showMcpCommand(json.secret);
    loadTokens();
  } catch {
    showError(error, "Couldn't reach the server. Try again when you're online.");
  } finally {
    busy(button, false);
  }
};

$("copy-token").onclick = () => copyFrom($("new-token-secret"), $("copy-token"));

// How to connect an MCP client: this server's address, and a Claude Code
// command with the newest token in it (a placeholder until one is made).
const mcpUrl = `${location.origin}/mcp`;
$("mcp-url").querySelector("input").value = mcpUrl;
function showMcpCommand(secret = "<token>") {
  $("mcp-command").querySelector("input").value =
    `claude mcp add --transport http lazy-runner ${mcpUrl} --header "Authorization: Bearer ${secret}"`;
  $("copy-mcp-command").textContent = "Copy";
}
showMcpCommand();
$("copy-mcp-url").onclick = () => copyFrom($("mcp-url"), $("copy-mcp-url"));
$("copy-mcp-command").onclick = () => copyFrom($("mcp-command"), $("copy-mcp-command"));

// The running version: the release the server's image was built for, or a
// development build, with the commit it was built from.
async function loadVersion() {
  const build = $("about-build");
  try {
    const { data: { version, commit } } = await getJson("/api/version");
    $("about-version").textContent = version === "dev" ? "The Lazy Runner, development build" : `The Lazy Runner ${version}`;
    build.textContent = commit ? `Commit ${commit}` : "";
    // A release links the MCP docs as they were for it, not as on main.
    if (/^\d+\.\d+\.\d+$/.test(version)) $("mcp-docs").href = `https://github.com/cloetzi/lazy-runner/blob/v${version}/docs/api.md#mcp-server`;
  } catch {
    build.textContent = "The version shows when the server can be reached.";
  }
}

mountNav("settings");
render();
renderAccount();
loadTokens();
loadIdentities();
examples.load();
outbox?.flush();
loadUnit();
loadDevices();
loadVersion();
