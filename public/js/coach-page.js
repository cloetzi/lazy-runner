import { mountNav, showCoachNews } from "./nav.js";
import { getJson, loadProblem, offline, paths, sendChange, STALE_NOTE } from "./api.js";
import { escape, icon } from "./html.js";
import { localToday, dayName, shortDay, longDay, STATUS_LABELS, shownStatus } from "./calendar.js";
import { activityTitle, activityFacts, sportIcon, preferredDistanceUnit } from "./activities.js";
import {
  authorLabel, authorBadge, writtenOn, knownCoaches, weekDays, KIND_LABELS, JOURNAL_FILTERS, journalPath, tidyCountPath, tidyRequest,
  noteRequest, changeNoteRequest, resolveRequest, deleteNoteRequest,
  addGoalRequest, changeGoalRequest, deleteGoalRequest, acceptRequest, dismissRequest, movedPosition,
} from "./coach.js";
import { openNoteSheet, openGoalSheet, openResolveSheet, openTidySheet, aboutChoices } from "./coach-sheets.js";
import { newsGroups, hasNews, newsCount, seenRequest } from "./coach-news.js";
import { undoButton, undoRequest } from "./plan-changes.js";

// The Coach tab: what agents did since you last looked (each change with a
// way to its day and back), the goals that anchor everything (only the user changes
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
  news: null, // GET /api/coach/news: what agents did since the user last looked
  newsStale: false,
  busy: false, // marking seen or taking a change back is on its way
  stale: false,
  failed: null,
  filter: "all", // the journal's filter, a key of JOURNAL_FILTERS
  journal: null, // the journal's notes under the filter, paged in
  journalNext: null, // the `before` for its next page; null when there is none
  journalFailed: false, // the journal could not be read under the filter
  loadingOlder: false,
  journalAsk: 0, // the latest journal read, so an older answer arriving late is dropped
  earlier: [], // the statuses and focus since replaced, folded into one line
  earlierNext: null, // the `before` for their next page; null when there is none
  earlierOpen: false,
  past: null, // achieved, dropped and dismissed goals, once asked for
};

const today = () => localToday();
const unit = () => (storage ? preferredDistanceUnit(storage) : "km");

async function load() {
  try {
    const [{ data, stale }] = await Promise.all([getJson(paths.coach(today())), loadJournal(), loadEarlier(), loadNews()]);
    state.board = data;
    state.stale = stale;
    state.failed = null;
  } catch (error) {
    state.failed = loadProblem("the coach board", error);
  }
  render();
}

// What agents did since the user last looked. Without it (offline with no
// copy) the card just doesn't show. A fresh answer sets the Coach tab's dot.
async function loadNews() {
  const asked = performance.now();
  try {
    const { data, stale } = await getJson(paths.coachNews(today()));
    state.news = data;
    state.newsStale = stale;
    if (!stale) showCoachNews(newsCount(data), asked);
  } catch {
    state.news = null;
  }
}

// Marks it seen, or takes a change back, now; then reads the news again,
// and the whole board after an undo (the week may have changed).
async function newsChange(request, { board = false } = {}) {
  if (state.busy) return;
  state.busy = true;
  render();
  try {
    const problem = await sendChange(request);
    if (!problem || !offline()) await (board ? load() : loadNews());
    if (problem) alert(problem);
  } finally {
    state.busy = false;
    render();
  }
}

// The journal's first page under the filter. The latest notes may have
// moved on, so it starts again from them.
async function loadJournal() {
  const ask = ++state.journalAsk;
  try {
    const { data } = await getJson(journalPath(state.filter));
    // Read again (another filter, or after a change) while this one loaded.
    if (ask !== state.journalAsk) return;
    state.journal = data.notes;
    state.journalNext = data.next_before;
    state.journalFailed = false;
  } catch {
    if (ask !== state.journalAsk) return;
    state.journal = null;
    state.journalFailed = true;
  }
}

// The statuses and focus since replaced (the current ones are the board's),
// a page at a time: `more` adds the next page.
const EARLIER = "/api/coach/notes?journal=true&kind=status,focus&limit=100";
async function loadEarlier(more = false) {
  try {
    const { data } = await getJson(more ? `${EARLIER}&before=${state.earlierNext}` : EARLIER);
    state.earlier = more ? [...state.earlier, ...data.notes] : data.notes;
    state.earlierNext = data.next_before;
  } catch (error) {
    if (more) alert(loadProblem("older notes", error, { hint: false }));
    else state.earlier = [];
  }
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
  const written = everyNote();
  state.agentSeen = board.proposals.length > 0 || written.some((note) => note.author_kind === "llm");
  const empty = !board.goals.length && !board.proposals.length && written.length === 0;
  $("coach-board").innerHTML = [newsCard(), empty ? introCard() : "", goalsCard(board), currentCard("status", board.status), currentCard("focus", board.focus),
    weekCard(board), concernsCard(board), notesCard(board)].join("");
}

// Until anything is written: what the page is for, and the two ways in.
function introCard() {
  return `
    <section class="card coach-card coach-intro" aria-labelledby="intro-title">
      <h2 id="intro-title">Your training notebook</h2>
      <p>Goals, where things stand, what to work on next and notes along the way. You write here, and so can a coach you work with or an AI assistant you connect. Start with a goal.</p>
      <div class="card-actions">
        <button class="primary small" data-add-goal>${icon("plus")}Add a goal</button>
        <a class="button secondary small" href="/settings.html#api-tokens">Connect an assistant</a>
      </div>
    </section>`;
}

// "Since you last looked": what each agent did, a line each, with Show (its
// day on the Calendar) and the button that takes a change back. Mark as seen
// clears it, up to the newest thing shown.
function newsCard() {
  if (!hasNews(state.news)) return "";
  // A copy kept on the device can't say what can still be taken back.
  const live = !state.newsStale;
  const groups = newsGroups(state.news, { today: today(), unit: unit() }).map((g) => `
    <div class="news-group">
      <p class="author"><span class="author-badge llm" aria-hidden="true">${icon("agent")}</span><strong>${escape(g.who)}</strong><span class="muted"> · ${escape(g.when)}</span></p>
      <ul class="news-items">${g.items.map((item) => `
        <li>
          <span>${escape(item.text)}</span>
          ${item.href ? `<a class="link" href="${escape(item.href)}" aria-label="${escape(`Show ${item.title} on the calendar`)}">Show</a>` : ""}
          ${live && item.undo ? undoButton(item.undo, item.title, { classes: "quiet small", disabled: state.busy }) : ""}
        </li>`).join("")}</ul>
    </div>`).join("");
  return `
    <section class="card coach-card coach-news" aria-labelledby="news-title">
      <header class="coach-card-head"><h2 id="news-title">Since you last looked</h2><button class="secondary small" data-seen${state.busy || !live ? " disabled" : ""}>Mark as seen</button></header>
      ${groups}
    </section>`;
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
  // Only the first waiting proposal is the page's main action.
  const proposed = proposals.map((p, i) => `
    <div class="proposal">
      <p class="proposal-title"><strong>Proposed: ${escape(p.title)}</strong></p>
      ${p.replaces_id && byId.get(p.replaces_id) ? `<p class="muted small-print">Instead of “${escape(byId.get(p.replaces_id).title)}”</p>` : ""}
      ${p.proposed_reason ? `<p>${escape(p.proposed_reason)}</p>` : ""}
      ${p.why || p.target_date ? `<p class="muted small-print">${[p.target_date && `By ${shortDay(p.target_date)}`, p.why].filter(Boolean).map(escape).join(" · ")}</p>` : ""}
      ${author({ author_kind: "llm", author_name: p.agent_name, created_at: p.created_at })}
      <div class="proposal-actions">
        <button class="${i === 0 ? "primary" : "secondary"} small" data-accept="${p.id}">Accept</button>
        <button class="secondary small" data-dismiss="${p.id}">Dismiss</button>
      </div>
    </div>`).join("");
  return `
    <section class="card coach-card" aria-labelledby="goals-title">
      <header class="coach-card-head"><h2 id="goals-title">Goals</h2><button class="secondary small" data-add-goal>${icon("plus")}Add</button></header>
      ${list}
      ${proposed}
      ${pastGoals()}
      ${state.agentSeen ? `<p class="muted small-print">Only you change goals; your coach agent can propose one.</p>` : ""}
    </section>`;
}

function pastGoals() {
  if (!state.past) return `<p><button class="quiet small" data-past>Past goals</button></p>`;
  if (state.past.length === 0) return `<p class="muted small-print">No past goals yet.</p>`;
  return `
    <div class="past-goals">
      <h3>Past goals</h3>
      <ul class="coach-entries">${state.past.map((g) => `
        <li class="coach-entry">
          <p class="entry-title"><strong>${escape(g.title)}</strong> ${g.status === "achieved" ? `<span class="tag success">Achieved</span>` : `<span class="tag">Dropped</span>`}</p>
          ${g.decided_at ? `<p class="muted small-print">${escape(writtenOn({ created_at: g.decided_at }))}</p>` : ""}
          <div class="entry-actions">
            <button class="quiet small" data-reactivate="${g.id}">Make it a goal again</button>
            <button class="quiet small danger" data-delete-goal="${g.id}" data-title="${escape(g.title)}">Delete</button>
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
    : `<p class="muted">${kind === "status" ? `Where things stand: written by you or your coach${state.agentSeen ? " or your coach agent" : ""}.` : "What to work on next."}</p>`;
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
    ? `<button class="quiet small danger" data-delete-note="${note.id}">Delete</button>`
    : `<button class="quiet small" data-edit-note="${note.id}">Edit</button>`;
}

function concernsCard({ concerns }) {
  return `
    <section class="card coach-card" aria-labelledby="concerns-title">
      <header class="coach-card-head"><h2 id="concerns-title">Concerns</h2><button class="secondary small" data-write="concern">${icon("plus")}Add</button></header>
      ${concerns.length ? `<ul class="coach-entries">${concerns.map((n) => noteItem(n, { concern: true })).join("")}</ul>` : `<p class="muted">Nothing to watch right now.</p>`}
    </section>`;
}

// The journal: filters, the notes under the one picked, the earlier
// statuses and focus folded into one line (under All), and Tidy up.
function notesCard({ notes }) {
  const filters = `<div class="segmented journal-filters" role="group" aria-label="Show notes">${JOURNAL_FILTERS.map((f) =>
    `<button type="button" data-filter="${f.key}" aria-pressed="${f.key === state.filter}">${escape(f.label)}</button>`).join("")}</div>`;
  // Offline, or not read yet: the board's latest stand in under All.
  const list = state.journal ?? (state.filter === "all" ? notes.filter((n) => n.kind === "note" || n.kind === "concern") : []);
  const earlier = state.filter === "all" && state.earlier.length ? earlierLine() : "";
  const loading = state.journal == null && state.filter !== "all";
  const empty = loading ? (state.journalFailed ? "Could not load these notes." : "Loading…") : {
    all: `Notes from you${state.agentSeen ? ", your coach and your coach agent" : " and your coach"} show here.`,
    you: "Nothing from you yet.",
    coach: "Nothing from your coach yet.",
    concerns: "No resolved concerns yet; open ones are above.",
  }[state.filter];
  const actions = [
    state.journal && state.journalNext != null && `<button class="secondary small" data-older${state.loadingOlder ? " disabled" : ""}>Older notes</button>`,
    (list.length || state.earlier.length) && `<button class="quiet small" data-tidy>Tidy up</button>`,
  ].filter(Boolean);
  return `
    <section class="card coach-card" aria-labelledby="notes-title">
      <header class="coach-card-head"><h2 id="notes-title">Notes</h2><button class="secondary small" data-write="note">Write a note</button></header>
      ${filters}
      ${list.length ? `<ul class="coach-entries">${list.map((n) => noteItem(n)).join("")}</ul>` : `<p class="muted">${empty}</p>`}
      ${earlier}
      ${actions.length ? `<div class="journal-actions">${actions.join("")}</div>` : ""}
    </section>`;
}

// "Earlier status and focus, 3", opening to the notes themselves.
function earlierLine() {
  const count = `${state.earlier.length}${state.earlierNext != null ? "+" : ""}`;
  const kinds = [...new Set(state.earlier.map((n) => n.kind))].sort().map((k) => KIND_LABELS[k].toLowerCase()).join(" and ");
  return `
    <div class="journal-earlier">
      <button class="row earlier-toggle" data-earlier aria-expanded="${state.earlierOpen}">
        <span class="row-text"><span class="row-title">Earlier ${escape(kinds)}, ${count}</span></span>
        ${icon(state.earlierOpen ? "chevron-up" : "chevron-down")}
      </button>
      ${state.earlierOpen ? `<ul class="coach-entries">${state.earlier.map((n) => noteItem(n)).join("")}</ul>
        ${state.earlierNext != null ? `<button class="secondary small" data-earlier-more>Older</button>` : ""}` : ""}
    </div>`;
}

// ---------- Changes ----------

const everyNote = () => {
  const b = state.board;
  return [b.status, b.focus, ...b.concerns, ...b.notes, ...b.week.notes, ...(state.journal ?? []), ...state.earlier].filter(Boolean);
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
  if (state.loadingOlder || !state.journal) return;
  const { filter: asked, journal } = state;
  state.loadingOlder = true;
  render();
  try {
    const { data } = await getJson(journalPath(asked, state.journalNext));
    // The filter changed, or the journal was read again, while this loaded.
    if (state.journal === journal) {
      journal.push(...data.notes);
      state.journalNext = data.next_before;
    }
  } catch (error) {
    if (state.journal === journal) alert(loadProblem("older notes", error, { hint: false }));
  } finally {
    if (state.journal === journal) state.loadingOlder = false;
  }
  render();
}

async function filter(key) {
  if (key === state.filter) return;
  state.filter = key;
  state.journal = null;
  state.journalNext = null;
  state.journalFailed = false;
  state.loadingOlder = false;
  render();
  await loadJournal();
  render();
}

// Tidy up: the agent's notes written before a day go, after a count.
function tidy() {
  openTidySheet({
    count: async (before) => {
      const { data, stale } = await getJson(tidyCountPath(before));
      return { count: data.count, stale };
    },
    onTidy: (before) => change(tidyRequest(before)),
  });
}

$("coach-board").addEventListener("click", (event) => {
  const target = event.target.closest("button");
  if (!target || target.disabled) return;
  const d = target.dataset;
  const find = (id) => everyNote().find((n) => String(n.id) === id);
  if (d.seen !== undefined) return newsChange(seenRequest(state.news));
  if (d.undo) {
    const change = state.news?.changes.find((c) => String(c.id) === d.undo);
    return change && newsChange(undoRequest(change, today()), { board: true });
  }
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
  if (d.filter) return filter(d.filter);
  if (d.earlier !== undefined) { state.earlierOpen = !state.earlierOpen; return render(); }
  if (d.earlierMore !== undefined) return loadEarlier(true).then(render);
  if (d.tidy !== undefined) return tidy();
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
