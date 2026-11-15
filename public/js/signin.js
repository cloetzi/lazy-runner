import { errorMessage, send } from "./api.js";
import { adoptAccount, checkSignedIn, inviteToken, nextPath, oidcOutcome, signInHref, signOut, startOidc, welcomeHref, whoIsSignedIn } from "./account.js";
import { escape, busy } from "./html.js";

// The sign-in page. It signs you in; on a fresh install it creates the
// owner account with the setup code from the server's log; with an invite
// link (#invite/<token>) it creates yours. Where the install has an
// OpenID Connect provider, it offers that too, for signing in and joining:
// the provider sends the browser back here (`?oidc_error=` when it didn't
// work). Signed in with a temporary
// password (the owner reset yours), it asks for your own first. Then it
// goes back to the page that sent it here (`?next=`), through the welcome
// screen on a first sign-in, forgetting what someone else left on this
// device first (account.js).

const storage = (() => {
  try {
    return localStorage;
  } catch {
    return null;
  }
})();
const status = document.getElementById("signin-status");
const next = nextPath(location.search);
const invite = inviteToken(location.hash);
const forms = ["signin-form", "setup-form", "join-form", "invite-signed-in", "new-password-form", "invite-gone"].map((id) => document.getElementById(id));
const [signinForm, setupForm, joinForm, signedInCard, newPasswordForm, inviteGone] = forms;

async function enter(user) {
  await adoptAccount(user, { storage, caches: globalThis.caches });
  location.replace(user.welcomed ? next : welcomeHref(next));
}

function show(form) {
  status.hidden = true;
  for (const other of forms) other.hidden = other !== form;
  // The first control shown: a provider's button only where there is one.
  [...form.querySelectorAll("input:not([type=hidden]), button")].find((control) => control.getClientRects().length)?.focus();
}

// Signed in: on, unless the password was temporary. `password` is the one
// just typed, so the new-password form needn't ask for it again.
function signedIn(user, password) {
  if (!user.password_change_required) return enter(user);
  newPasswordForm.elements.password.value = password ?? "";
  show(newPasswordForm);
  if (password) newPasswordForm.elements.new_password.focus();
}

function wire(form, path, extra = {}) {
  const error = form.querySelector(".form-error");
  const button = form.querySelector("button[type=submit]");
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    error.hidden = true;
    busy(button);
    const body = { ...Object.fromEntries(new FormData(form)), ...extra };
    try {
      const response = await send(path, { body });
      const json = await response.json().catch(() => null);
      // Already signed in (in another tab, say): carry on as that user.
      if (response.ok || response.status === 409) {
        const me = await whoIsSignedIn();
        if (me.user) return signedIn(me.user, body.new_password ?? body.password);
        if (me.gate) {
          form.hidden = true;
          return offerRetry("Signed in, but something in front of the app (a sign-in page, say) answers instead of it now. Try again to reach it.");
        }
        // The server signed you in, but the browser didn't keep the cookie:
        // a Secure cookie over plain http.
        error.textContent = location.protocol === "http:"
          ? "Signed in, but this browser didn't keep the sign-in over plain http. Reach the app over HTTPS, or start the server with SECURE_COOKIES=false."
          : "Signed in, but this browser didn't keep the sign-in. Allow cookies for this site and try again.";
      } else {
        error.textContent = errorMessage(json, response.status);
      }
    } catch {
      error.textContent = "Can't reach the server. Check the connection and try again.";
    }
    error.hidden = false;
    busy(button, false);
  });
}

wire(signinForm, "/api/auth/login");
wire(setupForm, "/api/auth/create-account");
wire(joinForm, "/api/auth/create-account", { invite });
// Leaving the temporary password signs out every other device, whatever
// the form says.
wire(newPasswordForm, "/api/auth/change-password");

// No answer, or one from something in front of the app: say which, and
// offer to ask again, since an installed app on iOS has no reload button.
// Trying again loads this page with `?gate`, which asks the network too, so
// a sign-in page in front of the app shows (sw.js, #222).
function offerRetry(message) {
  status.textContent = message;
  status.hidden = false;
  document.getElementById("signin-retry").hidden = false;
  document.getElementById("signin-retry-button").onclick = () => {
    const target = `${signInHref({ pathname: next, search: "", hash: "" }, { gate: true })}${location.hash}`;
    // The same address with a fragment would only scroll: load it again.
    if (target === `${location.pathname}${location.search}${location.hash}`) location.reload();
    else location.assign(target);
  };
}

// Signing in (or joining) with the provider: off to its page, and back
// here. It is the common way in where there is one, so it comes first and
// the password's button steps back.
function offerOidc(form, provider, body) {
  const block = form.querySelector(".oidc");
  const button = block.querySelector("button");
  const error = form.querySelector(".form-error");
  button.textContent = `${button.dataset.oidc} ${provider}`;
  block.hidden = false;
  form.querySelector("button[type=submit]").className = "secondary";
  button.onclick = async () => {
    error.hidden = true;
    busy(button);
    try {
      location.assign(await startOidc({ ...body, next }));
    } catch (failure) {
      error.textContent = failure instanceof TypeError ? "Can't reach the server. Check the connection and try again." : failure.message;
      error.hidden = false;
      busy(button, false);
    }
  };
}

// A Show button beside every password field, so a typo on a touch keyboard
// can be caught before it makes an account no one can get into.
for (const input of document.querySelectorAll("input[type=password]")) {
  // Named by its label's title alone, not the button now inside the label
  // too, and described by the label's hint ("At least 8 characters").
  const label = input.closest("label");
  const title = label?.querySelector("span")?.textContent;
  if (title) input.setAttribute("aria-label", title);
  const hint = label?.querySelector("span.muted");
  if (hint) {
    hint.id ||= `${input.form.id}-${input.name}-hint`;
    input.setAttribute("aria-describedby", hint.id);
  }
  const box = document.createElement("span");
  box.className = "password-box";
  input.replaceWith(box);
  const toggle = document.createElement("button");
  toggle.type = "button";
  toggle.className = "link show-password";
  toggle.innerHTML = `Show<span class="visually-hidden"> password</span>`;
  toggle.onclick = () => {
    const shown = input.type === "password";
    input.type = shown ? "text" : "password";
    toggle.firstChild.textContent = shown ? "Hide" : "Show";
  };
  box.append(input, toggle);
}

// Whether the invite link still works, asked before the form is filled in.
// Only a clear no counts: offline or anything else, the form is shown and
// says so itself if the link is gone.
async function inviteWorks(token) {
  try {
    const response = await send("/api/auth/invite-check", { body: { invite: token } });
    return response.status !== 404;
  } catch {
    return true;
  }
}

document.getElementById("invite-gone-sign-in").onclick = () => {
  history.replaceState(null, "", `${location.pathname}${location.search}`);
  show(signinForm);
};

document.getElementById("invite-sign-out").onclick = async (event) => {
  const button = event.currentTarget;
  const error = signedInCard.querySelector(".form-error");
  error.hidden = true;
  busy(button);
  const outcome = await signOut({ storage, caches: globalThis.caches });
  busy(button, false);
  if (outcome === "done") return show((await inviteWorks(invite)) ? joinForm : inviteGone);
  error.textContent = outcome === "refused"
    ? "The server didn't sign you out. Reload the page and try again."
    : "Couldn't reach the server to sign out. Try again when you're online.";
  error.hidden = false;
};

// What came back from the provider, shown once.
const params = new URLSearchParams(location.search);
const oidcError = params.get("oidc_error");
if (oidcError) {
  params.delete("oidc_error");
  history.replaceState(null, "", `${location.pathname}${params.toString() ? `?${params}` : ""}${location.hash}`);
}

const me = await checkSignedIn({ storage, caches: globalThis.caches });
if (me.signInWith) {
  offerOidc(signinForm, me.signInWith, {});
  offerOidc(joinForm, me.signInWith, { invite });
}
if (me.user && invite) {
  document.getElementById("invite-signed-in-who").innerHTML = `This device is signed in as <strong>${escape(me.user.username)}</strong>.`;
  show(signedInCard);
} else if (me.user) await signedIn(me.user);
// An install with no owner yet needs setting up, invite link or not.
else if (me.setupRequired) show(setupForm);
else if (invite && me.signedOut && !me.gate) show((await inviteWorks(invite)) ? joinForm : inviteGone);
else if (me.signedOut && !me.gate) {
  show(signinForm);
  if (oidcError) {
    const error = signinForm.querySelector(".form-error");
    error.textContent = oidcOutcome(oidcError, me.signInWith ?? undefined).message;
    error.hidden = false;
  }
  // An invite link cut short (wrapped in a message, say) is no invite.
  if (location.hash.startsWith("#invite/")) {
    const error = signinForm.querySelector(".form-error");
    error.textContent = "This invite link is incomplete. Open the whole link, or ask for a new one.";
    error.hidden = false;
  }
}
else {
  offerRetry(me.gate
    ? "Something in front of the app (a sign-in page, say) is answering instead of it. Try again to reach it."
    : "Can't reach the server. Signing in needs a connection; try again once you're online.");
}
