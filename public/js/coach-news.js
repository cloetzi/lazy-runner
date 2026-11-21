// "Since you last looked" on Coach, kept free of the DOM so node can
// test it: what agents did since the user last marked it seen (GET
// /api/coach/news), one group per agent, newest first: a line for the notes
// written, a line per change to the plan with the reason given for it, and a
// line for the activities copied. A change links to its day on the Calendar
// and, while it can be, offers the button that takes it back. The goals an
// agent proposed are not said here: they wait on the page until answered.

import { shortDay } from "./calendar.js";
import { AGENT_NAME, writtenDay } from "./coach.js";
import { dayNear, fieldChanges, undoLabel, rememberedText } from "./plan-changes.js";
import { sourceLabel } from "./activities.js";

// "an activity", "8 activities".
const plural = (count, one, many = `${one}s`) => (count === 1 ? `${/^[aeiou]/.test(one) ? "an" : "a"} ${one}` : `${count} ${many}`);

// "a status, a focus and 2 notes".
function listed(parts) {
  return parts.length > 1 ? `${parts.slice(0, -1).join(", ")} and ${parts.at(-1)}` : parts[0] ?? "";
}

// "Nov 3 to Nov 10", or one day.
const span = (from, to) => (from === to ? shortDay(from) : `${shortDay(from)} to ${shortDay(to)}`);

// "today, 10:35": when, on this device.
export function writtenAt(time, today) {
  const at = new Date(time);
  return `${writtenDay(time, today)}, ${String(at.getHours()).padStart(2, "0")}:${String(at.getMinutes()).padStart(2, "0")}`;
}

const calendarHref = (date) => `/calendar.html#${date}`;

// A change to the plan as a line: what happened, why (the reason the agent
// gave), the day to show, and the change when it can be taken back.
function changeItem(change, today, unit, weightUnit) {
  const title = change.title || { session: "a session", routine: "a routine", workout: "a workout", weight: "an exercise" }[change.item_kind];
  const day = (iso) => dayNear(iso, today);
  const item = (text, date) => ({ kind: "change", text, reason: change.reason || null, href: date ? calendarHref(date) : null, title, undo: undoLabel(change) ? change : null });
  if (change.item_kind === "weight") {
    return { ...item(`Set ${title} to ${rememberedText(change.now, weightUnit)} (was ${rememberedText(change.was, weightUnit)})`, null), title: `${title}'s weight` };
  }
  if (change.item_kind === "workout") {
    const href = change.workout_id ? `/#workout/${change.workout_id}` : null;
    const text = change.action === "archived" ? `Archived ${title}` : `Changed ${title}${change.summary ? `: ${change.summary}` : ""}`;
    return { ...item(text, null), href, showLabel: `Show ${title}` };
  }
  switch (change.action) {
    case "planned":
      return item(`Planned ${title} ${change.item_kind === "routine" ? "from" : "on"} ${day(change.to_date)}`, change.to_date);
    case "moved":
      return item(`Moved ${title} from ${day(change.was?.date ?? change.from_date)} to ${day(change.to_date)}`, change.to_date);
    case "removed":
      return item(`Removed ${title} from ${day(change.from_date)}`, change.from_date);
    case "changed": {
      const fields = fieldChanges(change, unit);
      return item(`Changed ${title}${fields.length ? `: ${fields.join(", ")}` : ""}`, change.to_date ?? change.from_date);
    }
    case "ended":
      return item(`Ended ${title}`, null);
    default:
      return null;
  }
}

// The news in groups, one per agent, the latest first: { who, when, items },
// each item { kind, text, reason, href, title, undo } (reason, href and undo
// may be null; a workout's href opens it, with `showLabel` naming that).
// First what it wrote (kind "wrote"), then the plan (kind "change"): planned
// sessions add up to one line ("Planned 6 sessions, Nov 16 to Dec 3", with
// the reason they share), then
// the other changes in the order made. Then the activities copied (kind
// "copied") and the check-ins it filled in from what the user told it (kind
// "checkin"). An agent that only proposed goals has a group with no items.
export function newsGroups(news, { today, unit = "km", weightUnit } = {}) {
  const groups = new Map();
  const group = (name, time) => {
    const who = name || AGENT_NAME;
    const found = groups.get(who) ?? { who, latest: time, plan: [], copied: [], checkIns: [], notes: [], goals: [] };
    if (time > found.latest) found.latest = time;
    groups.set(who, found);
    return found;
  };
  for (const change of news?.changes ?? []) group(change.agent_name, change.created_at).plan.push(change);
  for (const copied of news?.activities ?? []) group(copied.agent_name, copied.created_at).copied.push(copied);
  for (const checkIn of news?.check_ins ?? []) group(checkIn.agent_name, checkIn.agent_at).checkIns.push(checkIn);
  for (const note of news?.notes ?? []) group(note.author_name, note.created_at).notes.push(note);
  for (const goal of news?.goals ?? []) group(goal.agent_name, goal.created_at).goals.push(goal);

  return [...groups.values()].sort((a, b) => (a.latest < b.latest ? 1 : -1)).map((g) => {
    const sessions = g.plan.filter((c) => c.action === "planned" && c.item_kind === "session");
    const items = [];
    if (sessions.length > 1) {
      const days = sessions.map((c) => c.to_date).sort();
      // The reason, when the sessions were all planned for the same one.
      const reasons = [...new Set(sessions.map((c) => c.reason || null))];
      items.push({ kind: "change", text: `Planned ${sessions.length} sessions, ${span(days[0], days.at(-1))}`, reason: reasons.length === 1 ? reasons[0] : null, href: calendarHref(days[0]), title: "them", undo: null });
    }
    for (const change of [...g.plan].reverse()) {
      if (sessions.length > 1 && sessions.includes(change)) continue;
      const item = changeItem(change, today, unit, weightUnit);
      if (item) items.push(item);
    }
    for (const copied of g.copied) {
      const from = copied.sources.length ? ` from ${listed(copied.sources.map(sourceLabel))}` : "";
      items.push({ kind: "copied", text: `Copied ${plural(copied.count, "activity", "activities")}${from}, ${span(copied.from, copied.to)}`, reason: null, href: calendarHref(copied.to), title: "them", undo: null });
    }
    if (g.checkIns.length) {
      const days = g.checkIns.map((c) => c.date).sort();
      const text = days.length === 1 ? `Added to your check-in, ${span(days[0], days[0])}` : `Added to your check-ins, ${span(days[0], days.at(-1))}`;
      items.push({ kind: "checkin", text, reason: null, href: calendarHref(days.at(-1)), title: days.length === 1 ? "it" : "them", undo: null });
    }
    const wrote = ["status", "focus", "concern", "note"].map((kind) => {
      const count = g.notes.filter((n) => n.kind === kind).length;
      return count ? plural(count, kind, { status: "statuses", focus: "focus notes" }[kind]) : null;
    }).filter(Boolean);
    if (wrote.length) items.unshift({ kind: "wrote", text: `Wrote ${listed(wrote)}`, reason: null, href: null, title: null, undo: null });
    return { who: g.who, when: g.latest ? writtenAt(g.latest, today) : "", items };
  });
}

// How many things are news, as GET /api/me counts them for the Coach tab.
export const newsCount = (news) => (news?.changes?.length ?? 0) + (news?.notes?.length ?? 0) + (news?.goals?.length ?? 0) +
  (news?.activities ?? []).reduce((sum, copied) => sum + copied.count, 0) + (news?.check_ins?.length ?? 0);

// Whether there is anything to show.
export const hasNews = (news) => Boolean(news) && ["changes", "notes", "goals", "activities", "check_ins"].some((key) => news[key]?.length);

// Marking it seen, up to the newest thing shown, so anything made since
// stays news.
export const seenRequest = (news) => ({ method: "POST", path: "/api/coach/seen", body: news?.latest ? { until: news.latest } : {} });
