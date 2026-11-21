// The check-ins on screen: Today's card with its two rows, a day's rows on
// the Calendar, and the two sheets, "Last night" and "How I feel today".
// Each sheet only asks; the caller sends the request it is given (through
// the outbox), so a check-in made offline is kept.

import { html, icon, showSheet } from "./html.js";
import { longDay } from "./calendar.js";
import { agentName } from "./coach.js";
import { CHOICES, NIGHT_TAGS, SORE_AREAS, NOTE_LENGTH, FIELDS, nightSummary, daySummary, nightTitle, dayTitle, checkInRequest, clearRequest } from "./check-ins.js";

const GLYPHS = { night: "night", day: "check-in" };
const HINTS = { night: "Sleep, drinks, a late one", day: "Energy, stress, anything sore or off" };
const summaryOf = (group, fields) => (group === "night" ? nightSummary(fields) : daySummary(fields));
const titleOf = (group, date, today) => (group === "night" ? nightTitle(date, today) : dayTitle(date, today));

// Who logged it, when an agent did: "Added by Coach agent from your chat".
const byAgent = (checkIn, group) => (checkIn?.[group]?.logged_by === "llm" ? `Added by ${agentName(checkIn)} from your chat` : "");

// The row's lines: the summary, then the note, then who added it.
function rowLines(checkIn, group) {
  const fields = checkIn?.[group];
  return [summaryOf(group, fields), fields?.note, byAgent(checkIn, group), fields?.pending && "not synced yet"].filter(Boolean);
}

// Today: one card under the day's, a row for each group with Add until it
// is filled. `attribute` holds the group a tap opens.
export function todayCheckInHtml(checkIn, date) {
  const row = (group) => {
    const filled = Boolean(checkIn?.[group]);
    const [first, ...rest] = filled ? rowLines(checkIn, group) : [HINTS[group]];
    return html`
      <li>
        <button class="row checkin-row${filled ? "" : " empty"}" type="button" data-check-in="${group}">
          <span class="checkin-tile" aria-hidden="true">${icon(GLYPHS[group])}</span>
          <span class="row-text">
            <span class="row-title">${titleOf(group, date, date)}</span>
            ${first ? html`<span class="row-meta${filled ? " checkin-summary" : ""}">${first}</span>` : ""}
            ${rest.map((line) => html`<span class="row-meta">${line}</span>`)}
          </span>
          ${filled ? icon("chevron-right") : html`<span class="checkin-add">${icon("plus")}Add</span>`}
        </button>
      </li>`;
  };
  return html`
    <header class="checkin-card-head"><h2 class="eyebrow" id="checkin-title">Check-in</h2><span class="muted checkin-why">Optional · for your coach</span></header>
    <ul class="list checkin-list">${row("night")}${row("day")}</ul>`;
}

// A day's row on the Calendar for one group, or nothing when it is empty.
export function checkInRow(checkIn, group, today) {
  if (!checkIn?.[group]) return "";
  const [first, ...rest] = rowLines(checkIn, group);
  return html`
    <li class="cal-row checkin-cal-row ${group}-row">
      <button class="row" data-check-in="${group}" data-date="${checkIn.date}">
        <span class="checkin-tile" aria-hidden="true">${icon(GLYPHS[group])}</span>
        <span class="row-text">
          <span class="row-title">${titleOf(group, checkIn.date, today)}</span>
          ${first ? html`<span class="row-meta">${first}</span>` : ""}
          ${rest.map((line) => html`<span class="row-meta">${line}</span>`)}
        </span>
      </button>
    </li>`;
}

// The Coach week strip's tiles for a day.
export function checkInTiles(checkIn) {
  return ["night", "day"].filter((g) => checkIn?.[g]).map((g) => html`<span class="checkin-tile small">${icon(GLYPHS[g])}</span>`);
}

// What a screen reader hears of a day's check-ins on the strip.
export function checkInSaid(checkIn) {
  return [
    checkIn?.night && `night: ${nightSummary(checkIn.night) || "logged"}`,
    checkIn?.day && `felt: ${daySummary(checkIn.day) || "logged"}`,
  ].filter(Boolean);
}

// One of a few, where a second tap clears it.
const segmented = (name, legend, chosen) => html`
  <div class="field">
    <span class="field-label" id="checkin-${name}-label">${legend}</span>
    <div class="segmented fill" role="group" aria-labelledby="checkin-${name}-label" data-field="${name}">
      ${CHOICES[name].map(([value, label]) => html`<button type="button" data-value="${value}" aria-pressed="${String(value === chosen)}">${label}</button>`)}
    </div>
  </div>`;

const chips = (name, choices, chosen = []) => html`
  <div class="check-chips checkin-chips" data-field="${name}">
    ${choices.map(([value, label]) => html`<label><input type="checkbox" value="${value}"${chosen.includes(value) ? " checked" : ""}><span>${label}</span></label>`)}
  </div>`;

// A group's sheet. `checkIn` is the day's (or null); `send(request)` takes
// the PUT or DELETE to queue. Save writes what is chosen, Clear the group.
export function openCheckInSheet({ group, date, today, checkIn, send }) {
  const id = `${group}-sheet`;
  const dialog = document.getElementById(id) ??
    document.body.appendChild(Object.assign(document.createElement("dialog"), { id, className: "sheet calendar-sheet checkin-sheet" }));
  const current = { ...FIELDS[group], ...(checkIn?.[group] ?? {}) };
  const filled = Boolean(checkIn?.[group]);
  const title = group === "night" ? (date === today ? "Last night" : nightTitle(date, today)) : (date === today ? "How I feel today" : "How I felt");
  const sore = current.sore && current.sore !== "no";
  const agent = byAgent(checkIn, group);
  const fields = group === "night" ? html`
      ${segmented("sleep", "Sleep", current.sleep)}
      ${segmented("drinks", "Drinks", current.drinks)}
      <fieldset class="field"><legend>Also</legend>${chips("tags", NIGHT_TAGS, current.tags)}</fieldset>
      <label class="field"><span>Note</span><textarea name="note" rows="2" maxlength="${NOTE_LENGTH}" placeholder="Anything about the night">${current.note ?? ""}</textarea></label>` : html`
      ${segmented("feeling", "Overall", current.feeling)}
      ${segmented("stress", "Stress", current.stress)}
      ${segmented("sore", "Sore or niggly", current.sore)}
      <fieldset class="field" data-areas${sore ? "" : " hidden"}><legend>Where</legend>${chips("sore_areas", SORE_AREAS, current.sore_areas)}</fieldset>
      <div class="check-chips checkin-ill"><label><input type="checkbox" name="ill"${current.ill ? " checked" : ""}><span>Ill</span></label></div>
      <label class="field"><span>Note</span><textarea name="note" rows="3" maxlength="${NOTE_LENGTH}" placeholder="How the body feels, anything your coach should know">${current.note ?? ""}</textarea></label>`;

  dialog.setAttribute("aria-labelledby", `${id}-title`);
  dialog.innerHTML = html`
    <form method="dialog" class="howto checkin-form">
      <header>
        <h2 id="${id}-title">${title}</h2>
        <button class="icon-button" type="button" data-close aria-label="Close">${icon("close")}</button>
      </header>
      <p class="muted">${longDay(date)} · all optional, tap again to clear</p>
      ${agent ? html`<p class="muted small-print">${agent}</p>` : ""}
      ${fields}
      <button class="primary" type="submit">Save</button>
      ${filled ? html`<div class="danger-zone"><button class="quiet small danger" type="button" data-clear>${icon("trash")}Clear</button></div>` : ""}
    </form>`;

  const form = dialog.querySelector("form");
  form.querySelector("[data-close]").addEventListener("click", () => dialog.close());
  for (const group of form.querySelectorAll(".segmented[data-field]")) {
    group.addEventListener("click", (event) => {
      const button = event.target.closest("button[data-value]");
      if (!button) return;
      const on = button.getAttribute("aria-pressed") !== "true";
      for (const other of group.querySelectorAll("button")) other.setAttribute("aria-pressed", String(on && other === button));
      if (group.dataset.field === "sore") form.querySelector("[data-areas]").hidden = !(on && button.dataset.value !== "no");
    });
  }
  const read = () => {
    const values = { note: form.elements.note.value };
    for (const group of form.querySelectorAll(".segmented[data-field]")) {
      values[group.dataset.field] = group.querySelector('[aria-pressed="true"]')?.dataset.value ?? null;
    }
    for (const list of form.querySelectorAll(".checkin-chips[data-field]")) {
      values[list.dataset.field] = [...list.querySelectorAll("input:checked")].map((input) => input.value);
    }
    if (form.elements.ill) values.ill = form.elements.ill.checked;
    return values;
  };
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    const request = checkInRequest(date, group, read(), today);
    // Nothing chosen on a day with nothing logged: nothing to send.
    if (request.method === "PUT" || filled) send(request);
    dialog.close();
  });
  form.querySelector("[data-clear]")?.addEventListener("click", () => {
    if (!confirm(`Clear ${group === "night" ? "the night" : "how you felt"} on ${longDay(date)}?`)) return;
    send(clearRequest(date, group));
    dialog.close();
  });
  dialog.returnValue = "";
  showSheet(dialog);
}
