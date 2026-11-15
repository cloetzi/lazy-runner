import { escape, icon, busy } from "./html.js";
import { longDay } from "./calendar.js";
import { KINDS, KIND_LABELS, noteFields, goalFields, authorLabel } from "./coach.js";

// The Coach tab's sheets, used by the Coach page and the Calendar: writing
// or editing a note, adding or editing a goal, and resolving a concern. Each
// is a dialog built on demand, like the calendar's sheets. They don't close
// until the server has taken the change: `onSave` resolves to an error
// message to show, or nothing once it is saved.

function sheet(id) {
  return document.getElementById(id) ??
    document.body.appendChild(Object.assign(document.createElement("dialog"), { id, className: "sheet calendar-sheet coach-sheet" }));
}

const HINTS = {
  status: "Where things stand. It replaces the current status, which stays in the notes.",
  focus: "What to work on. It replaces the current focus, which stays in the notes.",
  concern: "Something to watch. It stays open until it's resolved.",
  note: "Goes in the notes, for you and your coach.",
};

// Sends with `save` when the primary button is pressed, keeping the sheet
// open with the problem shown until it is saved.
function saveOnSubmit(dialog, form, read, save) {
  const error = form.querySelector(".form-error");
  const show = (message) => { error.textContent = message; error.hidden = !message; };
  form.querySelector("[data-close]").addEventListener("click", () => dialog.close());
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const { fields, problems } = read();
    if (problems.length) return show(problems.join(" "));
    const button = form.querySelector("button.primary");
    busy(button);
    try {
      const problem = await save(fields);
      if (problem) show(problem);
      else dialog.close();
    } finally {
      busy(button, false);
    }
  });
}

// An agent's note: shown as it wrote it, with Delete. `onDelete()` deletes it.
function openAgentNoteSheet({ note, onDelete }) {
  const dialog = sheet("note-sheet");
  dialog.innerHTML = `
    <form class="howto" novalidate>
      <header>
        <h2>${escape(note.title ?? KIND_LABELS[note.kind])}</h2>
        <button class="icon-button" type="button" data-close aria-label="Close">${icon("close")}</button>
      </header>
      <p class="entry-body">${escape(note.body)}</p>
      <p class="muted small-print">Written by ${escape(authorLabel(note))}. An agent's note stays as it wrote it; write a note of your own to answer it.</p>
      <p class="form-error" role="alert" hidden></p>
      <button class="link danger" type="button" data-delete>${icon("trash")}Delete the note</button>
    </form>`;
  const form = dialog.querySelector("form");
  form.querySelector("[data-close]").addEventListener("click", () => dialog.close());
  form.querySelector("[data-delete]").addEventListener("click", async () => {
    if (!confirm("Delete this note?")) return;
    const problem = await onDelete();
    if (!problem) return dialog.close();
    const error = form.querySelector(".form-error");
    error.textContent = problem;
    error.hidden = false;
  });
  dialog.showModal();
}

// Writes a note, or edits `note`. `kind` picks the kind a new one starts as;
// `date` the day it is about. `about` lists what it can be about, as
// [{ value: "activity:3", label }], and `coaches` the coaches named before.
// `onSave(fields)` sends it; `onDelete()` deletes an edited one.
export function openNoteSheet({ note = null, kind = "note", date = "", about = [], coaches = [], onSave, onDelete }) {
  if (note?.author_kind === "llm") return openAgentNoteSheet({ note, onDelete });
  const dialog = sheet("note-sheet");
  const editing = Boolean(note);
  const current = note ? { kind: note.kind, title: note.title ?? "", body: note.body, date: note.date ?? "" } : { kind, title: "", body: "", date };
  const aboutValue = note?.activity_id ? `activity:${note.activity_id}` : note?.session_id ? `session:${note.session_id}` : "";
  // What it was about stays offered, even when it isn't in this week's list.
  const aboutChoices = aboutValue && !about.some((a) => a.value === aboutValue) && note.about
    ? [{ value: aboutValue, label: `${note.about.label ?? note.about.type}, ${note.about.date}` }, ...about]
    : about;
  const author = note?.author_kind === "human" ? note.author_name : "user";
  const names = [...new Set([...(author !== "user" ? [author] : []), ...coaches])];

  dialog.innerHTML = `
    <form class="howto note-form" novalidate>
      <header>
        <h2>${editing ? "Edit the note" : "Write a note"}</h2>
        <button class="icon-button" type="button" data-close aria-label="Close">${icon("close")}</button>
      </header>
      <div class="segmented kind-choices" role="radiogroup" aria-label="Kind">
        ${KINDS.map((k) => `<label><input type="radio" name="kind" value="${k}"${k === current.kind ? " checked" : ""}><span>${KIND_LABELS[k]}</span></label>`).join("")}
      </div>
      <p class="muted small-print" data-hint>${escape(HINTS[current.kind])}</p>
      <label class="field"><span>Title <span class="muted" data-title-optional>(optional)</span></span>
        <input name="title" maxlength="200" value="${escape(current.title)}">
      </label>
      <label class="field"><span>What's going on</span>
        <textarea name="body" rows="4" maxlength="5000" required>${escape(current.body)}</textarea>
      </label>
      <div class="note-meta">
        <label class="field"><span>About <span class="muted">(optional)</span></span>
          <select name="about">
            <option value="">Nothing in particular</option>
            ${aboutChoices.map((a) => `<option value="${escape(a.value)}"${a.value === aboutValue ? " selected" : ""}>${escape(a.label)}</option>`).join("")}
          </select>
        </label>
        <label class="field"><span>Day <span class="muted">(optional)</span></span>
          <input type="date" name="date" value="${escape(current.date)}">
        </label>
      </div>
      <label class="field"><span>Written by</span>
        <select name="author">
          <option value="user"${author === "user" ? " selected" : ""}>You</option>
          ${names.map((n) => `<option value="${escape(n)}"${n === author ? " selected" : ""}>${escape(n)}</option>`).join("")}
          <option value="other">Another coach…</option>
        </select>
      </label>
      <label class="field" data-author-name hidden><span>Coach's name</span>
        <input name="authorName" maxlength="100" autocomplete="off">
      </label>
      <p class="form-error" role="alert" hidden></p>
      <button class="primary" type="submit">Save</button>
      ${editing ? `<button class="link danger" type="button" data-delete>${icon("trash")}Delete the note</button>` : ""}
    </form>`;

  const form = dialog.querySelector("form");
  const hint = form.querySelector("[data-hint]");
  const titleOptional = form.querySelector("[data-title-optional]");
  const kindNow = () => form.querySelector('input[name="kind"]:checked')?.value;
  const showKind = () => {
    hint.textContent = HINTS[kindNow()] ?? "";
    titleOptional.hidden = kindNow() === "concern";
  };
  form.querySelectorAll('input[name="kind"]').forEach((input) => input.addEventListener("change", showKind));
  showKind();
  const authorSelect = form.elements.author;
  const nameField = form.querySelector("[data-author-name]");
  authorSelect.addEventListener("change", () => {
    nameField.hidden = authorSelect.value !== "other";
    if (!nameField.hidden) form.elements.authorName.focus();
  });
  form.querySelector("[data-delete]")?.addEventListener("click", async () => {
    if (!confirm("Delete this note?")) return;
    const problem = await onDelete();
    if (problem) {
      const error = form.querySelector(".form-error");
      error.textContent = problem;
      error.hidden = false;
    } else dialog.close();
  });

  const read = () => noteFields({
    kind: kindNow(), title: form.elements.title.value, body: form.elements.body.value,
    date: form.elements.date.value, about: form.elements.about.value,
    author: authorSelect.value, authorName: form.elements.authorName.value,
  }, { editing });
  saveOnSubmit(dialog, form, read, onSave);
  dialog.showModal();
  if (!editing) form.elements.body.focus();
}

// Adds a goal, or edits `goal`: its title, why and target date, and for an
// active one Achieved, Dropped and Delete. `onSave(fields)` sends the form,
// `onStatus(status)` and `onDelete()` the rest; each resolves to an error
// message, or nothing.
export function openGoalSheet({ goal = null, onSave, onStatus, onDelete }) {
  const dialog = sheet("goal-sheet");
  const editing = Boolean(goal);
  dialog.innerHTML = `
    <form class="howto goal-form" novalidate>
      <header>
        <h2>${editing ? "Edit the goal" : "Add a goal"}</h2>
        <button class="icon-button" type="button" data-close aria-label="Close">${icon("close")}</button>
      </header>
      <label class="field"><span>Goal</span>
        <input name="title" maxlength="200" required value="${escape(goal?.title ?? "")}" placeholder="Half marathon under 1:50">
      </label>
      <label class="field"><span>Why it matters <span class="muted">(optional)</span></span>
        <textarea name="why" rows="3" maxlength="2000">${escape(goal?.why ?? "")}</textarea>
      </label>
      <label class="field"><span>By <span class="muted">(optional)</span></span>
        <input type="date" name="target_date" value="${escape(goal?.target_date ?? "")}">
      </label>
      <p class="form-error" role="alert" hidden></p>
      <button class="primary" type="submit">Save</button>
      ${editing ? `
      <div class="goal-actions">
        <button class="secondary small" type="button" data-status="achieved">${icon("check")}Achieved</button>
        <button class="secondary small" type="button" data-status="dropped">Drop it</button>
        <button class="link danger" type="button" data-delete>${icon("trash")}Delete</button>
      </div>` : ""}
    </form>`;
  const form = dialog.querySelector("form");
  const error = form.querySelector(".form-error");
  const act = async (run) => {
    const problem = await run();
    if (problem) {
      error.textContent = problem;
      error.hidden = false;
    } else dialog.close();
  };
  form.querySelectorAll("[data-status]").forEach((button) => button.addEventListener("click", () => act(() => onStatus(button.dataset.status))));
  form.querySelector("[data-delete]")?.addEventListener("click", () => {
    if (confirm("Delete this goal? Achieved or Drop it keep it in your past goals.")) act(onDelete);
  });
  saveOnSubmit(dialog, form, () => goalFields({
    title: form.elements.title.value, why: form.elements.why.value, target_date: form.elements.target_date.value,
  }), onSave);
  dialog.showModal();
  if (!editing) form.elements.title.focus();
}

// Resolves a concern, with an optional word on how.
export function openResolveSheet({ note, onResolve }) {
  const dialog = sheet("resolve-sheet");
  dialog.innerHTML = `
    <form class="howto" novalidate>
      <header>
        <h2>Resolve the concern</h2>
        <button class="icon-button" type="button" data-close aria-label="Close">${icon("close")}</button>
      </header>
      <p><strong>${escape(note.title ?? "Concern")}</strong></p>
      <label class="field"><span>How it was resolved <span class="muted">(optional)</span></span>
        <textarea name="resolution" rows="2" maxlength="2000" placeholder="Gone after a week of easy runs"></textarea>
      </label>
      <p class="form-error" role="alert" hidden></p>
      <button class="primary" type="submit">Resolve</button>
    </form>`;
  const form = dialog.querySelector("form");
  saveOnSubmit(dialog, form, () => ({ fields: form.elements.resolution.value, problems: [] }), onResolve);
  dialog.showModal();
}

// What a note can be about: the activities and sessions given, newest day first.
export function aboutChoices({ sessions = [], activities = [], label = (a) => a.title }) {
  return [
    ...activities.filter((a) => a.id != null).map((a) => ({ date: a.date, value: `activity:${a.id}`, label: `${label(a)}, ${longDay(a.date)}` })),
    ...sessions.filter((s) => s.id != null).map((s) => ({ date: s.date, value: `session:${s.id}`, label: `${s.workout.title}, ${longDay(s.date)}` })),
  ].sort((a, b) => b.date.localeCompare(a.date));
}
