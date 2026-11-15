import { mountNav } from "./nav.js";
import { getJson, loadProblem, offline, paths, sendChange, STALE_NOTE } from "./api.js";
import { escape, icon } from "./html.js";
import { localToday, dayName, shortDay, longDay, STATUS_LABELS, shownStatus } from "./calendar.js";
import { activityTitle, activityFacts, sportIcon, preferredDistanceUnit } from "./activities.js";
import {
  authorLabel, authorBadge, writtenOn, knownCoaches, weekDays, KIND_LABELS,
  noteRequest, changeNoteRequest, resolveRequest, deleteNoteRequest,
  addGoalRequest, changeGoalRequest, deleteGoalRequest, acceptRequest, dismissRequest, movedPosition,
} from "./coach.js";
import { openNoteSheet, openGoalSheet, openResolveSheet, aboutChoices } from "./coach-sheets.js";

// The Coach tab: the goals that anchor everything (only the user changes
// them; an agent's proposals wait here to be accepted or dismissed), the
// current status and focus, this week as a plain list, open concerns, and
// the notes. Every entry says who wrote it: you, a coach you named, or the
// agent. Changes are sent straight away and the board read again; they need
// a connection.

const $ = (id) => document.getElementById(id);
const storage = (() => { try { return localStorage; } catch { return null; } })();
mountNav("coach");

const state = {
  board: null,
  stale: false,
  failed: null,
  older: [], // journal notes paged in below the latest
  olderNext: undefined, // the `before` for the next page; null when there is none
  past: null, // achieved, dropped and dismissed goals, once asked for
};

const today = () => localToday();
const unit = () => (storage ? preferredDistanceUnit(storage) : "km");

async function load() {
  try {
    const { data, stale } = await getJson(paths.coach(today()));
    state.board = data;
    // The latest notes may have moved on: page the journal again from them.
    state.older = [];
    state.olderNext = undefined;
    state.stale = stale;
    state.failed = null;
  } catch (error) {
    state.failed = loadProblem("the coach board", error);
  }
  render();
}

// Sends a change; the board is read again once it is saved. Resolves to the
// problem to show, or nothing.
async function change(request) {
  const problem = await sendChange(request);
  if (problem) return problem;
  await load();
  if (state.past) await loadPast();
  return null;
}

// Past goals, read when asked for.
async function loadPast() {
  try {
    const { data } = await getJson("/api/goals");
    state.past = data.past.filter((g) => g.status !== "dismissed");
  } catch (error) {
    alert(loadProblem("your past goals", error, { hint: false }));
  }
  render();
}

// ---------- Drawing ----------

function render() {
  const notes = [];
  if (state.failed) notes.push(state.failed);
  else if (state.stale) notes.push(STALE_NOTE);
  // Unlike the rest of the app, notes and goals are sent straight away.
  if (state.stale || offline()) notes.push("Writing notes and goals needs a connection.");
  $("coach-note").textContent = notes.join(" ");
  $("coach-note").hidden = notes.length === 0;
  const board = state.board;
  if (!board) {
    $("coach-board").innerHTML = state.failed ? "" : `<p class="muted">Loading…</p>`;
    return;
  }
  $("coach-board").innerHTML = [goalsCard(board), currentCard("status", board.status), currentCard("focus", board.focus),
    weekCard(board), concernsCard(board), notesCard(board)].join("");
}

function author(note) {
  const badge = authorBadge(note);
  return `<span class="author"><span class="author-badge ${note.author_kind}" aria-hidden="true">${badge.icon ? icon(badge.icon) : escape(badge.initials)}</span>` +
    `<strong>${escape(authorLabel(note))}</strong><span class="muted"> · ${escape(writtenOn(note))}</span></span>`;
}

function aboutTag(note) {
  if (!note.about && !note.date) return "";
  const label = note.about
    ? `${note.about.label ?? (note.about.type === "activity" ? "Activity" : "Session")}, ${shortDay(note.about.date)}`
    : longDay(note.date);
  return `<span class="tag">${escape(label)}</span>`;
}

function goalsCard({ goals, proposals }) {
  const byId = new Map(goals.map((g) => [g.id, g]));
  const list = goals.length
    ? `<ol class="goal-list">${goals.map((g, i) => `
        <li>
          <button class="row goal" data-goal="${g.id}">
            <span class="goal-number" aria-hidden="true">${i + 1}.</span>
            <span class="row-text">
              <span class="row-title">${escape(g.title)}</span>
              ${g.target_date || g.why ? `<span class="goal-why muted">${[g.target_date && `By ${shortDay(g.target_date)}`, g.why].filter(Boolean).map(escape).join(" · ")}</span>` : ""}
            </span>
          </button>
          ${goals.length > 1 ? `<span class="goal-order">
            <button class="icon-button" data-goal-up="${g.id}" aria-label="${escape(`Move ${g.title} up`)}"${i === 0 ? " disabled" : ""}>${icon("chevron-up")}</button>
            <button class="icon-button" data-goal-down="${g.id}" aria-label="${escape(`Move ${g.title} down`)}"${i === goals.length - 1 ? " disabled" : ""}>${icon("chevron-down")}</button>
          </span>` : ""}
        </li>`).join("")}</ol>`
    : `<p class="muted">No goals yet. What are you training for? Everything the coach writes ties back to these.</p>`;
  const proposed = proposals.map((p) => `
    <div class="proposal">
      <p class="proposal-title"><strong>Proposed: ${escape(p.title)}</strong></p>
      ${p.replaces_id && byId.get(p.replaces_id) ? `<p class="muted small-print">Instead of “${escape(byId.get(p.replaces_id).title)}”</p>` : ""}
      ${p.proposed_reason ? `<p>${escape(p.proposed_reason)}</p>` : ""}
      ${p.why || p.target_date ? `<p class="muted small-print">${[p.target_date && `By ${shortDay(p.target_date)}`, p.why].filter(Boolean).map(escape).join(" · ")}</p>` : ""}
      ${author({ author_kind: "llm", author_name: p.agent_name, created_at: p.created_at })}
      <div class="proposal-actions">
        <button class="primary small" data-accept="${p.id}">Accept</button>
        <button class="secondary small" data-dismiss="${p.id}">Dismiss</button>
      </div>
    </div>`).join("");
  return `
    <section class="card coach-card" aria-labelledby="goals-title">
      <header class="coach-card-head"><h2 id="goals-title">Goals</h2><button class="secondary small" data-add-goal>${icon("plus")}Add</button></header>
      ${list}
      ${proposed}
      ${pastGoals()}
      <p class="muted small-print">Only you change goals; your coach agent can propose one.</p>
    </section>`;
}

function pastGoals() {
  if (!state.past) return `<p><button class="link" data-past>Past goals</button></p>`;
  if (state.past.length === 0) return `<p class="muted small-print">No past goals yet.</p>`;
  return `
    <div class="past-goals">
      <h3>Past goals</h3>
      <ul class="coach-entries">${state.past.map((g) => `
        <li class="coach-entry">
          <p class="entry-title"><strong>${escape(g.title)}</strong> <span class="tag">${g.status === "achieved" ? "Achieved" : "Dropped"}</span></p>
          ${g.decided_at ? `<p class="muted small-print">${escape(writtenOn({ created_at: g.decided_at }))}</p>` : ""}
          <div class="entry-actions">
            <button class="link" data-reactivate="${g.id}">Make it a goal again</button>
            <button class="link danger" data-delete-goal="${g.id}" data-title="${escape(g.title)}">Delete</button>
          </div>
        </li>`).join("")}</ul>
    </div>`;
}

function currentCard(kind, note) {
  const title = KIND_LABELS[kind];
  const body = note
    ? `
      ${note.title ? `<p class="current-title"><strong>${escape(note.title)}</strong></p>` : ""}
      <p class="current-body">${escape(note.body)}</p>
      <p class="note-by">${author(note)}${note.replaces ? `<span class="muted"> · replaces ${escape(writtenOn(note.replaces))}</span>` : ""}</p>
      <div class="entry-actions">${editButton(note)}</div>`
    : `<p class="muted">${kind === "status" ? "Where things stand: written by you, your coach or your coach agent." : "What to work on next."}</p>`;
  return `
    <section class="card coach-card" aria-labelledby="${kind}-title">
      <header class="coach-card-head"><h2 id="${kind}-title">${title}</h2><button class="secondary small" data-write="${kind}">${note ? "Update" : "Write"}</button></header>
      ${body}
    </section>`;
}

function weekCard({ week }) {
  const days = weekDays(week).filter((d) => d.sessions.length || d.activities.length || d.notes.length);
  const rows = days.map((d) => {
    const items = [
      ...d.sessions.map((s) => `${s.workout.title}, ${STATUS_LABELS[shownStatus(s, today())].toLowerCase()}`),
      ...d.activities.map((a) => [activityTitle(a), ...activityFacts(a, unit())].join(", ")),
      ...d.notes.map((n) => `Note: ${n.title ?? n.body}`),
    ];
    return `<li class="week-day"><span class="muted">${escape(`${dayName(d.date, today())} · ${shortDay(d.date)}`)}</span><span>${items.map(escape).join(" · ")}</span></li>`;
  }).join("");
  return `
    <section class="card coach-card" aria-labelledby="week-title">
      <header class="coach-card-head"><h2 id="week-title">This week</h2><a class="link" href="/calendar.html">Calendar</a></header>
      ${rows ? `<ul class="coach-week">${rows}</ul>` : `<p class="muted">Nothing planned or done yet this week.</p>`}
    </section>`;
}

function noteItem(note, { concern = false } = {}) {
  const resolved = note.resolved_at;
  return `
    <li class="coach-entry${concern ? " concern" : ""}">
      ${note.title || (!concern && note.kind !== "note") ? `<p class="entry-title">${concern ? `<span class="concern-dot" aria-hidden="true"></span>` : ""}${note.title ? `<strong>${escape(note.title)}</strong>` : ""}${!concern && note.kind !== "note" ? ` <span class="tag">${escape(KIND_LABELS[note.kind])}${resolved ? ", resolved" : ""}</span>` : ""}</p>` : ""}
      <p class="entry-body">${escape(note.body)}</p>
      <p class="note-by">${author(note)} ${aboutTag(note)}</p>
      ${resolved ? `<p class="muted small-print">Resolved ${escape(writtenOn({ created_at: resolved }))}${note.resolution ? `: ${escape(note.resolution)}` : ""}</p>` : ""}
      <div class="entry-actions">
        ${concern && !resolved ? `<button class="secondary small" data-resolve="${note.id}">Resolve</button>` : ""}
        ${editButton(note)}
      </div>
    </li>`;
}

// An agent's note stays as it wrote it: it can only go.
function editButton(note) {
  return note.author_kind === "llm"
    ? `<button class="link" data-delete-note="${note.id}">Delete</button>`
    : `<button class="link" data-edit-note="${note.id}">Edit</button>`;
}

function concernsCard({ concerns }) {
  return `
    <section class="card coach-card" aria-labelledby="concerns-title">
      <header class="coach-card-head"><h2 id="concerns-title">Concerns</h2><button class="secondary small" data-write="concern">${icon("plus")}Add</button></header>
      ${concerns.length ? `<ul class="coach-entries">${concerns.map((n) => noteItem(n, { concern: true })).join("")}</ul>` : `<p class="muted">Nothing to watch right now.</p>`}
    </section>`;
}

function notesCard({ notes }) {
  const all = [...notes, ...state.older];
  const more = (state.olderNext === undefined ? state.board.notes_before : state.olderNext) != null;
  return `
    <section class="card coach-card" aria-labelledby="notes-title">
      <header class="coach-card-head"><h2 id="notes-title">Notes</h2><button class="primary small" data-write="note">Write a note</button></header>
      ${all.length ? `<ul class="coach-entries">${all.map((n) => noteItem(n)).join("")}</ul>` : `<p class="muted">Notes from you, your coach and your coach agent show here.</p>`}
      ${more ? `<button class="secondary small" data-older>Older notes</button>` : ""}
    </section>`;
}

// ---------- Changes ----------

const everyNote = () => {
  const b = state.board;
  return [b.status, b.focus, ...b.concerns, ...b.notes, ...b.week.notes, ...state.older].filter(Boolean);
};

function writeNote(kind, note = null) {
  const b = state.board;
  openNoteSheet({
    note, kind, date: note ? undefined : "",
    about: aboutChoices({ sessions: b.week.sessions, activities: b.week.activities, label: activityTitle }),
    coaches: knownCoaches(everyNote()),
    onSave: (fields) => change(note ? changeNoteRequest(note, fields) : noteRequest(fields)),
    onDelete: () => change(deleteNoteRequest(note)),
  });
}

function editGoal(goal = null) {
  openGoalSheet({
    goal,
    onSave: (fields) => change(goal ? changeGoalRequest(goal, fields) : addGoalRequest(fields)),
    onStatus: (status) => change(changeGoalRequest(goal, { status })),
    onDelete: () => change(deleteGoalRequest(goal)),
  });
}

async function moveGoal(id, direction) {
  const position = movedPosition(state.board.goals, id, direction);
  if (position == null) return;
  const problem = await change(changeGoalRequest({ id }, { position }));
  if (problem) alert(problem);
}

async function decide(request) {
  const problem = await change(request);
  if (problem) alert(problem);
}

// The journal's next page, written before the last one shown.
async function older() {
  const before = state.olderNext ?? state.board.notes_before;
  try {
    const { data } = await getJson(`/api/coach/notes?journal=true&limit=20&before=${before}`);
    state.older.push(...data.notes);
    state.olderNext = data.next_before;
  } catch (error) {
    alert(loadProblem("older notes", error, { hint: false }));
  }
  render();
}

$("coach-board").addEventListener("click", (event) => {
  const target = event.target.closest("button");
  if (!target || target.disabled) return;
  const d = target.dataset;
  const find = (id) => everyNote().find((n) => String(n.id) === id);
  if (d.addGoal !== undefined) return editGoal();
  if (d.goal) return editGoal(state.board.goals.find((g) => String(g.id) === d.goal));
  if (d.goalUp) return moveGoal(Number(d.goalUp), -1);
  if (d.goalDown) return moveGoal(Number(d.goalDown), 1);
  if (d.accept) return decide(acceptRequest({ id: d.accept }));
  if (d.dismiss) return decide(dismissRequest({ id: d.dismiss }));
  if (d.write) return writeNote(d.write);
  if (d.editNote) return writeNote(null, find(d.editNote));
  if (d.resolve) {
    const note = find(d.resolve);
    return openResolveSheet({ note, onResolve: (resolution) => change(resolveRequest(note, resolution)) });
  }
  if (d.older !== undefined) return older();
  if (d.past !== undefined) return loadPast();
  if (d.reactivate) return decide(changeGoalRequest({ id: d.reactivate }, { status: "active" }));
  if (d.deleteGoal) {
    if (!confirm(`Delete "${d.title}" for good?`)) return;
    return decide(deleteGoalRequest({ id: d.deleteGoal }));
  }
  if (d.deleteNote) {
    if (!confirm("Delete this note from the agent?")) return;
    return decide(deleteNoteRequest(find(d.deleteNote)));
  }
});

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") load();
});
// The note on writing offline comes and goes with the connection.
addEventListener("online", load);
addEventListener("offline", render);

load();
