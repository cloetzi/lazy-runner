import { mountNav, showCoachNews } from "./nav.js";
import { getJson, loadProblem, offline, paths, sendChange, STALE_NOTE } from "./api.js";
import { html, icon } from "./html.js";
import { localToday, shortDay, longDay, weekdayDay, STATUS_LABELS } from "./calendar.js";
import { STATE_LABELS, routineTitle } from "./routines.js";
import { routineTile } from "./routine-sheets.js";
import { activityTitle, sportIcon, preferredDistanceUnit } from "./activities.js";
import {
  authorLabel, writtenOn, writtenMonth, knownCoaches, weekDays, agentName, sameReview, focusLines,
  KIND_LABELS, JOURNAL_FILTERS, journalPath, tidyCountPath, tidyRequest,
  noteRequest, changeNoteRequest, resolveRequest, deleteNoteRequest,
  addGoalRequest, changeGoalRequest, deleteGoalRequest, acceptRequest, dismissRequest, movedPosition,
} from "./coach.js";
import {
  openNoteSheet, openGoalSheet, openResolveSheet, openTidySheet, openReplySheet, openConcernSheet, repliesHtml, byline as author, badgeHtml, aboutLabel, aboutChoices,
} from "./coach-sheets.js";
import { newsGroups, hasNews, newsCount, seenRequest } from "./coach-news.js";
import { undoButton, undoRequest } from "./plan-changes.js";

// The Coach tab. Four kinds of thing, each with its own look and place:
// - what is new, and what waits for an answer: a tinted band that goes away
//   (what agents did since you last looked, each change with its reason and
//   a way back; an agent's goal proposals, to accept or dismiss);
// - the coach's reading: the status, the focus and the open concerns as one
//   card, the only white one on the page;
// - what stands: the goals (only the user changes them) and this week as a
//   strip, in quiet outlined panels;
// - the record: the notes as a timeline, the statuses and focus since
//   replaced in their place.
// Every entry says who wrote it: you, a coach you named, or the agent. What
// was written since you last looked is marked New where it lives. Changes
// are sent straight away and the board read again; they need a connection.

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
  unfolded: new Set(), // the earlier statuses and focus opened in the timeline, by id
  past: null, // achieved, dropped and dismissed goals, once asked for
  reviewing: false, // the waiting goal proposals are open
  editingGoals: false, // the goals show Add, their arrows and Past goals
};
// Two columns from here, as in app.css.
const wide = matchMedia("(min-width: 60rem) and (orientation: landscape)");
wide.addEventListener("change", () => render());

const today = () => localToday();
const unit = () => (storage ? preferredDistanceUnit(storage) : "km");

async function load() {
  try {
    const [{ data, stale }] = await Promise.all([getJson(paths.coach(today())), loadJournal(), loadNews()]);
    state.board = data;
    state.stale = stale;
    state.failed = null;
  } catch (error) {
    state.failed = loadProblem("the coach board", error);
  }
  render();
}

// What agents did since the user last looked. Without it (offline with no
// copy) the band just doesn't show. A fresh answer sets the Coach tab's dot.
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
  $("coach-write").hidden = !board;
  if (!board) {
    $("coach-board").innerHTML = state.failed ? "" : html`<p class="muted">Loading…</p>`;
    return;
  }
  const written = everyNote();
  state.agentSeen = board.proposals.length > 0 || written.some((note) => note.author_kind === "llm");
  const empty = !board.goals.length && !board.proposals.length && written.length === 0;
  // Review closes once there is nothing left to review, and Edit with no goals.
  if (!board.proposals.length) state.reviewing = false;
  if (!board.goals.length) state.editingGoals = false;
  // What agents wrote since the user last looked: marked New where it shows.
  const fresh = new Set(hasNews(state.news) ? state.news.notes.map((note) => note.id) : []);
  const pinned = html`${goalsPanel(board)}${weekStrip(board)}`;
  // One column, fastest-changing first: what is new, the reading, what
  // stands, the record. Side by side in landscape, the reading leads on the
  // left with the notes under it; what is new, the goals and the week sit
  // beside it, and come first in the page's order (app.css places them),
  // so what waits for an answer is reached before the notes.
  $("coach-board").classList.toggle("wide", wide.matches);
  $("coach-board").innerHTML = html`${empty ? introCard() : ""}${wide.matches
    ? html`<div class="coach-side">${newBand(board, fresh)}${pinned}</div><div class="coach-main">${readingCard(board, fresh)}${timeline(board, fresh)}</div>`
    : html`${newBand(board, fresh)}${readingCard(board, fresh)}<div class="coach-pinned">${pinned}</div>${timeline(board, fresh)}`}`;
}

// Until anything is written: what the page is for, and the two ways in.
function introCard() {
  return html`
    <section class="card coach-card coach-intro" aria-labelledby="intro-title">
      <h2 id="intro-title">Your training notebook</h2>
      <p>Goals, where things stand, what to work on next and notes along the way. You write here, and so can a coach you work with or an AI assistant you connect. Start with a goal.</p>
      <div class="card-actions">
        <button class="primary small" data-add-goal>${icon("plus")}Add a goal</button>
        <a class="button secondary small" href="/settings.html#api-tokens">Connect an assistant</a>
      </div>
    </section>`;
}

const newBadge = (on) => (on ? html` <span class="badge">New</span>` : "");

// "Since you last looked", and what waits for an answer: gone when there is
// neither. What only tells you something is a plain line, with Show (its
// day on the Calendar) or Read (where it is on this page); a change that
// can be taken back is a row with the button, and so are the goal
// proposals. Either way a change says the reason the agent gave. Several
// agents each get their name over what they did. Mark as seen clears the
// news, up to the newest thing shown; proposals stay until answered.
function newBand(board, fresh) {
  const news = hasNews(state.news);
  const { proposals, goals } = board;
  if (!news && !proposals.length) return "";
  // A copy kept on the device can't say what can still be taken back.
  const live = !state.newsStale;
  const groups = news ? newsGroups(state.news, { today: today(), unit: unit() }) : [];
  // What was written is in the reading when a status, focus or concern is new, else among the notes.
  const written = [board.status, board.focus, ...board.concerns].some((note) => note && fresh.has(note.id)) ? "#reading" : "#notes";
  const agents = [...new Set(proposals.map((p) => agentName(p)))];
  const byId = new Map(goals.map((g) => [g.id, g]));
  const waiting = proposals.length ? html`
    <li class="new-row proposals${state.reviewing ? " open" : ""}">
      <button class="row proposals-line" data-review aria-expanded="${state.reviewing}">
        <span class="row-text">
          <span class="row-title">${proposals.length === 1 ? "1 goal proposal waits for your answer" : `${proposals.length} goal proposals wait for your answer`}</span>
          <span class="row-meta">From ${agents.length > 1 ? `${agents.slice(0, -1).join(", ")} and ${agents.at(-1)}` : agents[0]}</span>
        </span>
        <span class="proposals-toggle">${state.reviewing ? "Close" : "Review"}${icon(state.reviewing ? "chevron-up" : "chevron-down")}</span>
      </button>
      ${state.reviewing ? proposals.map((p, i) => proposalHtml(p, i, goals, byId)) : ""}
    </li>` : "";
  const who = (group) => html`<p class="new-who">${group.who}<span class="muted"> · ${group.when}</span></p>`;
  const show = (item) => (item.href ? html`<a class="link" href="${item.href}" aria-label="${item.showLabel ?? `Show ${item.title} on the calendar`}">Show</a>` : "");
  const what = (item) => html`<span class="new-text"><span class="new-what">${item.text}</span>${item.reason ? html`<span class="new-reason">${item.reason}</span>` : ""}</span>`;
  // One agent signs in the head; several each sign what they did.
  const several = groups.length > 1;
  const did = groups.map((group, i) => {
    const told = group.items.filter((item) => !(live && item.undo));
    const asked = group.items.filter((item) => live && item.undo);
    // The proposals close the one agent's rows, so the band ends on what waits.
    const closing = !several && i === groups.length - 1 ? waiting : "";
    return html`
      ${several && group.items.length ? who(group) : ""}
      ${told.length ? html`<ul class="new-told">${told.map((item) => html`
        <li>
          ${what(item)}
          ${item.kind === "wrote" ? html`<a class="link" href="${written}" data-read aria-label="${`Read what ${group.who} wrote`}">Read</a>` : show(item)}
        </li>`)}</ul>` : ""}
      ${asked.length || closing ? html`<ul class="new-rows">${asked.map((item) => html`
        <li class="new-row">
          ${what(item)}
          <span class="new-actions">${show(item)}${undoButton(item.undo, item.title, { disabled: state.busy })}</span>
        </li>`)}${closing}</ul>` : ""}`;
  });
  return html`
    <section class="coach-new" aria-labelledby="news-title">
      <header class="coach-new-head">
        <div>
          <h2 id="news-title">${news ? "Since you last looked" : "Waiting for you"}</h2>
          ${several ? "" : groups.map(who)}
        </div>
        ${news ? html`<button class="secondary small" data-seen${state.busy || !live ? " disabled" : ""}>Mark as seen</button>` : ""}
      </header>
      ${did}
      ${waiting && groups.length !== 1 ? html`<ul class="new-rows">${waiting}</ul>` : ""}
    </section>`;
}

// A waiting proposal, opened: what it is, why, and what each button does.
function proposalHtml(p, i, goals, byId) {
  const replaces = p.replaces_id && byId.get(p.replaces_id);
  const place = replaces ? goals.indexOf(replaces) + 1 : goals.length + 1;
  const accept = replaces
    ? html`It takes the place of goal ${place}, “${replaces.title}”, which moves to past goals.`
    : `It becomes goal ${place}, at the end of your list.`;
  return html`
    <div class="proposal">
      <p class="proposal-title"><strong>${p.title}</strong></p>
      ${replaces ? html`<p class="muted small-print">Instead of goal ${place}, “${replaces.title}”</p>` : ""}
      ${p.proposed_reason ? html`<p>${p.proposed_reason}</p>` : ""}
      <p class="muted small-print">${[p.target_date && `By ${shortDay(p.target_date)}`, p.why, `Proposed ${writtenOn(p)}`].filter(Boolean).join(" · ")}</p>
      <div class="proposal-actions">
        <button class="${i === 0 ? "primary" : "secondary"} small" data-accept="${p.id}">Accept</button>
        <button class="secondary small" data-dismiss="${p.id}">Dismiss</button>
      </div>
      <dl class="proposal-effects small-print">
        <div><dt>Accept</dt><dd>${accept}</dd></div>
        <div><dt>Dismiss</dt><dd>${agentName(p)} won't propose this goal again.</dd></div>
      </dl>
    </div>`;
}

// A note the user didn't write takes a reply, which shows under it with
// its own Edit.
const replyButton = (note) => note.author_kind !== "user"
  ? html`<button class="quiet small" data-reply="${note.id}" aria-label="${`Reply to ${noteName(note)}`}">Reply</button>` : "";
const replies = (note) => repliesHtml(note, (r) => html` <button class="quiet small" data-edit-reply="${r.id}" data-note="${note.id}" aria-label="Edit your reply">Edit</button>`);
// What a note is called by its buttons: its title, else its kind.
const noteName = (note) => (note.title ? `“${note.title}”` : `the ${KIND_LABELS[note.kind].toLowerCase()}`);
// The rest of what a note can do, in its sheet: an agent's shows as written
// with Reply and Delete, anyone else's opens to be edited.
const moreButton = (note) => html`<button class="icon-button" data-more="${note.id}" aria-label="${`${note.author_kind === "llm" ? "Open" : "Edit"} ${noteName(note)}`}">${icon("more")}</button>`;

// The coach's reading: where things stand, what to work on and what to
// watch, as one card. One review that wrote both the status and the focus
// signs once, under the focus.
function readingCard({ status, focus, concerns }, fresh) {
  const together = sameReview(status, focus);
  const lines = focusLines(focus);
  const part = (kind, note, body, signed) => html`
    <div class="reading-part">
      <div class="reading-head">
        <h2 class="eyebrow">${KIND_LABELS[kind]}</h2>${newBadge(note && fresh.has(note.id))}
        ${note ? html`<span class="reading-actions">${replyButton(note)}${moreButton(note)}</span>` : ""}
      </div>
      ${note ? body : html`<p class="muted">${kind === "status"
        ? `Where things stand: written by you or your coach${state.agentSeen ? " or your coach agent" : ""}.` : "What to work on next."}</p>
        <div class="entry-actions"><button class="quiet small" data-write="${kind}">${icon("plus")}Write ${kind === "status" ? "a status" : "a focus"}</button></div>`}
      ${note ? replies(note) : ""}
      ${note && signed ? html`<p class="note-by">${author(note)}</p>` : ""}
    </div>`;
  const watching = concerns.length ? html`
    <div class="reading-part watching">
      <div class="reading-head"><h2 class="eyebrow">Watching</h2><span class="eyebrow-count"><span aria-hidden="true">${concerns.length}</span><span class="visually-hidden">${concerns.length === 1 ? "1 open concern" : `${concerns.length} open concerns`}</span></span></div>
      <ul class="watch-list">${concerns.map((note) => html`
        <li><button class="row watch" data-concern="${note.id}">
          <span class="concern-dot" aria-hidden="true"></span>
          <span class="row-text">
            <span class="row-title">${note.title}${newBadge(fresh.has(note.id))}</span>
            <span class="watch-body">${note.body}</span>
            <span class="row-meta">${[authorLabel(note), writtenOn(note), note.replies?.length && (note.replies.length === 1 ? "1 reply" : `${note.replies.length} replies`)].filter(Boolean).join(" · ")}</span>
          </span>
          ${icon("chevron-right")}
        </button></li>`)}</ul>
    </div>` : "";
  return html`
    <section class="card coach-reading" id="reading" aria-label="Where things stand">
      ${part("status", status, status && html`
        ${status.title ? html`<p class="reading-headline">${status.title}</p>` : ""}
        <p class="${status.title ? "reading-body" : "reading-body lead"}">${status.body}</p>`, !together)}
      ${part("focus", focus, focus && html`
        ${focus.title ? html`<p class="reading-headline small">${focus.title}</p>` : ""}
        ${lines.length > 1 ? html`<ul class="focus-lines">${lines.map((line) => html`<li>${line}</li>`)}</ul>` : html`<p class="reading-body lead">${lines[0] ?? focus.body}</p>`}`, true)}
      ${watching}
    </section>`;
}

// Goals: what stands for months, the titles and their dates; a goal opens
// to be edited. Edit shows the rest: Add, the arrows that order them (side
// by side, 44 px each) and the past goals, which also show with no goal left.
function goalsPanel({ goals, past_goals: past }) {
  const editing = state.editingGoals;
  const ordering = editing && goals.length > 1;
  const list = goals.length
    ? html`<ol class="goal-list${ordering ? " ordering" : ""}">${goals.map((g, i) => {
        const text = html`
            <span class="goal-number" aria-hidden="true">${i + 1}</span>
            <span class="row-text">
              <span class="row-title">${g.title}</span>
              ${g.target_date ? html`<span class="row-meta">By ${shortDay(g.target_date)}</span>` : ""}
            </span>`;
        return html`
        <li>
          <button class="row goal" data-goal="${g.id}">${text}</button>
          ${ordering ? html`<span class="goal-order">
            <button class="secondary small icon-only" data-goal-up="${g.id}" aria-label="${`Move ${g.title} up`}"${i === 0 ? " disabled" : ""}>${icon("chevron-up")}</button>
            <button class="secondary small icon-only" data-goal-down="${g.id}" aria-label="${`Move ${g.title} down`}"${i === goals.length - 1 ? " disabled" : ""}>${icon("chevron-down")}</button>
          </span>` : ""}
        </li>`;
      })}</ol>`
    : html`<p class="muted">No goals yet. What are you training for? Everything the coach writes ties back to these.</p>`;
  const head = goals.length
    ? html`<button class="quiet small" data-edit-goals aria-expanded="${editing}">${editing ? html`${icon("check")}Done` : "Edit"}</button>`
    : html`<button class="quiet small" data-add-goal>${icon("plus")}Add</button>`;
  return html`
    <section class="pinned coach-goals${editing ? " editing" : ""}" id="goals" aria-labelledby="goals-title">
      <header class="pinned-head"><h2 class="eyebrow" id="goals-title">Goals</h2>${head}</header>
      ${list}
      ${ordering ? html`<p class="muted small-print">Put what matters most at the top.</p>` : ""}
      ${editing || !goals.length ? html`
        ${editing || (past && !state.past) ? html`<div class="goal-tools">
          ${editing ? html`<button class="secondary small" data-add-goal>${icon("plus")}Add a goal</button>` : ""}
          ${past && !state.past ? html`<button class="quiet small" data-past>Past goals</button>` : ""}
        </div>` : ""}
        ${state.past?.length ? pastGoals() : ""}` : ""}
      ${editing && state.agentSeen ? html`<p class="muted small-print">Only you change goals; your coach agent can propose one.</p>` : ""}
    </section>`;
}

function pastGoals() {
  return html`
    <div class="past-goals">
      <h3>Past goals</h3>
      <ul class="coach-entries">${state.past.map((g) => html`
        <li class="coach-entry">
          <p class="entry-title"><strong>${g.title}</strong> ${g.status === "achieved" ? html`<span class="tag success">Achieved</span>` : html`<span class="tag">Dropped</span>`}</p>
          ${g.decided_at ? html`<p class="muted small-print">${writtenOn({ created_at: g.decided_at })}</p>` : ""}
          <div class="entry-actions">
            <button class="quiet small" data-reactivate="${g.id}">Make it a goal again</button>
            <button class="quiet small danger" data-delete-goal="${g.id}" data-title="${g.title}">Delete</button>
          </div>
        </li>`)}</ul>
    </div>`;
}

// This week as seven days, each a column of the Calendar's tiles (a done
// session filled, a missed one struck, a planned run outlined) that opens
// its day on the Calendar. A run that ticked off its routine's day shows
// once, as the run; the notes dated to a day are one tile. The tiles are a picture; each day says what is on it
// to a screen reader.
function weekStrip({ week }) {
  const now = today();
  const tile = (classes, glyph) => html`<span class="sport-tile small ${classes}">${icon(glyph)}</span>`;
  const days = weekDays(week, now).map(({ date, sessions, routineDays, activities, notes }) => {
    const tiles = [
      ...sessions.map(({ mark }) => tile(mark, "workouts")),
      ...routineDays.map(({ day, routine }) => routineTile(routine, day.state, "small")),
      ...activities.map(({ activity }) => tile("done", sportIcon(activity.sport))),
      ...(notes.length ? [html`<span class="note-tile small">${icon("coach")}</span>`] : []),
    ];
    const said = [
      ...sessions.map(({ session, mark }) => `${session.workout.title}, ${STATUS_LABELS[mark].toLowerCase()}`),
      ...routineDays.map(({ day, routine }) => `${routine ? routineTitle(routine) : "Routine"}, ${STATE_LABELS[day.state].toLowerCase()}`),
      ...activities.map(({ activity }) => activityTitle(activity)),
      ...(notes.length ? [notes.length === 1 ? "1 note" : `${notes.length} notes`] : []),
    ];
    return html`
      <li>
        <a class="strip-day${date === now ? " today" : date < now ? " past" : ""}" href="/calendar.html#${date}">
          <span class="strip-date" aria-hidden="true">${weekdayDay(date).slice(0, 1)} ${Number(date.slice(8))}</span>
          <span class="strip-tiles" aria-hidden="true">${tiles.length ? tiles : html`<span class="strip-rest"></span>`}</span>
          <span class="visually-hidden">${date === now ? "Today, " : ""}${longDay(date)}: ${said.join("; ") || "rest"}</span>
        </a>
      </li>`;
  });
  return html`
    <section class="pinned coach-week" aria-labelledby="week-title">
      <header class="pinned-head"><h2 class="eyebrow" id="week-title">This week</h2><a class="link" href="/calendar.html">Calendar</a></header>
      <ol class="week-strip">${days}</ol>
    </section>`;
}

function aboutTag(note) {
  if (!note.about && !note.date) return "";
  return html`<span class="tag">${aboutLabel(note)}</span>`;
}

// The record: the notes under the filter as a timeline, newest first, a
// divider where the month changes. A status or focus since replaced sits in
// its place as one line, and opens.
function timeline({ notes }, fresh) {
  const filters = html`<div class="segmented journal-filters" role="group" aria-label="Show notes">${JOURNAL_FILTERS.map((f) =>
    html`<button type="button" data-filter="${f.key}" aria-pressed="${f.key === state.filter}">${f.label}</button>`)}</div>`;
  // Offline, or not read yet: the board's latest stand in under All.
  const list = state.journal ?? (state.filter === "all" ? notes : []);
  const loading = state.journal == null && state.filter !== "all";
  const empty = loading ? (state.journalFailed ? "Could not load these notes." : "Loading…") : {
    all: `Notes from you${state.agentSeen ? ", your coach and your coach agent" : " and your coach"} show here.`,
    you: "Nothing from you yet.",
    coach: "Nothing from your coach yet.",
    concerns: "No resolved concerns yet; open ones are under Watching.",
  }[state.filter];
  let month = null;
  const entries = list.map((note) => {
    const divider = writtenMonth(note) === month ? "" : html`<li class="timeline-month"><h3>${(month = writtenMonth(note))}</h3></li>`;
    return html`${divider}${timelineEntry(note, fresh)}`;
  });
  const actions = [
    state.journal && state.journalNext != null && html`<button class="secondary small" data-older${state.loadingOlder ? " disabled" : ""}>Older notes</button>`,
    list.length && html`<button class="quiet small" data-tidy>Tidy up</button>`,
  ].filter(Boolean);
  return html`
    <section class="coach-timeline" id="notes" aria-labelledby="notes-title">
      <header class="timeline-head"><h2 id="notes-title">Notes</h2>${filters}</header>
      ${list.length ? html`<ol class="timeline">${entries}</ol>` : html`<p class="muted">${empty}</p>`}
      ${actions.length ? html`<div class="journal-actions">${actions}</div>` : ""}
    </section>`;
}

function timelineEntry(note, fresh) {
  const who = badgeHtml(note);
  const earlier = note.kind === "status" || note.kind === "focus";
  if (earlier && !state.unfolded.has(note.id)) {
    return html`
      <li class="timeline-entry folded">
        ${who}
        <button class="timeline-fold" data-unfold="${note.id}" aria-expanded="false">
          <span class="tag">Earlier ${KIND_LABELS[note.kind].toLowerCase()}</span>
          <span class="timeline-fold-text">${note.title ?? note.body}</span>
          ${newBadge(fresh.has(note.id))}
          <span class="timeline-when">${writtenOn(note)}</span>
        </button>
      </li>`;
  }
  const kind = earlier ? `Earlier ${KIND_LABELS[note.kind].toLowerCase()}` : note.kind === "concern" ? `Concern${note.resolved_at ? ", resolved" : ""}` : "";
  return html`
    <li class="timeline-entry">
      ${who}
      <div class="timeline-body">
        <div class="timeline-top">
          <p class="timeline-meta"><strong>${authorLabel(note)}</strong><span class="timeline-when">${writtenOn(note)}</span>${newBadge(fresh.has(note.id))}${kind ? html`<span class="tag">${kind}</span>` : ""}${aboutTag(note)}</p>
          ${moreButton(note)}
        </div>
        ${note.title ? html`<p class="entry-title"><strong>${note.title}</strong></p>` : ""}
        <p class="entry-body">${note.body}</p>
        ${note.resolved_at ? html`<p class="muted small-print">Resolved ${writtenOn({ created_at: note.resolved_at })}${note.resolution ? html`: ${note.resolution}` : ""}</p>` : ""}
        ${replies(note)}
        ${note.author_kind !== "user" || earlier ? html`<div class="entry-actions">
          ${replyButton(note)}
          ${earlier ? html`<button class="quiet small" data-fold="${note.id}" aria-expanded="true" aria-label="${`Close ${noteName(note)}`}">Close</button>` : ""}
        </div>` : ""}
      </div>
    </li>`;
}

// ---------- Changes ----------

const everyNote = () => {
  const b = state.board;
  return [b.status, b.focus, ...b.concerns, ...b.notes, ...b.week.notes, ...(state.journal ?? [])].filter(Boolean);
};

function writeNote(kind, note = null) {
  const b = state.board;
  openNoteSheet({
    note, kind, date: note ? undefined : "",
    about: aboutChoices({ sessions: b.week.sessions, activities: b.week.activities, label: activityTitle }),
    coaches: knownCoaches(everyNote()),
    onSave: (fields) => change(note ? changeNoteRequest(note, fields) : noteRequest(fields)),
    onDelete: () => change(deleteNoteRequest(note)),
    onReply: (fields) => change(noteRequest(fields)),
  });
}

// A reply to `note`, or `reply` edited.
function writeReply(note, reply = null) {
  openReplySheet({
    note, reply,
    onSave: (fields) => change(reply ? changeNoteRequest(reply, fields) : noteRequest(fields)),
    onDelete: () => change(deleteNoteRequest(reply)),
  });
}

// An open concern, with everything that can be done with it.
function openConcern(note) {
  openConcernSheet({
    note,
    onResolve: () => openResolveSheet({ note, onResolve: (resolution) => change(resolveRequest(note, resolution)) }),
    onReply: () => writeReply(note),
    onEditReply: (reply) => writeReply(note, reply),
    onEdit: () => writeNote(null, note),
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

// Gives the focus back to what was pressed once the board was drawn again
// after a wait: only when drawing it lost the focus (it is nowhere), not
// when the user has moved on, and without scrolling back to it.
function refocus(element) {
  if (document.activeElement === document.body) element?.focus({ preventScroll: true });
}

async function moveGoal(id, direction) {
  const position = movedPosition(state.board.goals, id, direction);
  if (position == null) return;
  const problem = await change(changeGoalRequest({ id }, { position }));
  if (problem) alert(problem);
  // The list is drawn again: the arrow pressed keeps the focus, or its neighbour at an end.
  const pressed = document.querySelector(`[data-goal-${direction < 0 ? "up" : "down"}="${id}"]`);
  refocus(pressed?.disabled ? document.querySelector(`[data-goal-${direction < 0 ? "down" : "up"}="${id}"]`) : pressed);
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
  document.querySelector(`[data-filter="${key}"]`)?.focus();
  await loadJournal();
  render();
  refocus(document.querySelector(`[data-filter="${key}"]`));
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
  // The board is drawn again; the focus goes back to the button pressed.
  const redraw = (selector) => { render(); document.querySelector(selector)?.focus(); };
  if (d.seen !== undefined) return newsChange(seenRequest(state.news));
  if (d.undo) {
    const change = state.news?.changes.find((c) => String(c.id) === d.undo);
    return change && newsChange(undoRequest(change, today()), { board: true });
  }
  if (d.addGoal !== undefined) return editGoal();
  if (d.goal) return editGoal(state.board.goals.find((g) => String(g.id) === d.goal));
  if (d.review !== undefined) { state.reviewing = !state.reviewing; return redraw("[data-review]"); }
  if (d.editGoals !== undefined) { state.editingGoals = !state.editingGoals; return redraw("[data-edit-goals]"); }
  if (d.goalUp) return moveGoal(Number(d.goalUp), -1);
  if (d.goalDown) return moveGoal(Number(d.goalDown), 1);
  if (d.accept) return decide(acceptRequest({ id: d.accept }));
  if (d.dismiss) return decide(dismissRequest({ id: d.dismiss }));
  if (d.more) return writeNote(null, find(d.more));
  if (d.concern) return openConcern(find(d.concern));
  if (d.reply) return writeReply(find(d.reply));
  if (d.editReply) {
    const note = find(d.note);
    return writeReply(note, note?.replies.find((r) => String(r.id) === d.editReply));
  }
  if (d.write) return writeNote(d.write);
  if (d.unfold) { state.unfolded.add(Number(d.unfold)); return redraw(`[data-fold="${d.unfold}"]`); }
  if (d.fold) { state.unfolded.delete(Number(d.fold)); return redraw(`[data-unfold="${d.fold}"]`); }
  if (d.older !== undefined) return older();
  if (d.filter) return filter(d.filter);
  if (d.tidy !== undefined) return tidy();
  if (d.past !== undefined) return loadPast();
  if (d.reactivate) return decide(changeGoalRequest({ id: d.reactivate }, { status: "active" }));
  if (d.deleteGoal) {
    if (!confirm(`Delete "${d.title}" for good?`)) return;
    return decide(deleteGoalRequest({ id: d.deleteGoal }));
  }
});

// Read, on what an agent wrote: when it leads to the notes, they show all of them.
$("coach-board").addEventListener("click", (event) => {
  if (event.target.closest("a[data-read]")?.hash === "#notes") filter("all");
});

// One way in for writing: the sheet asks whether it is a note, a concern, a status or a focus.
$("coach-write").addEventListener("click", () => writeNote("note"));

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") load();
});
// The note on writing offline comes and goes with the connection.
addEventListener("online", load);
addEventListener("offline", render);

load();
