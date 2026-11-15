// "Since you last looked" on Coach (#259), kept free of the DOM so node can
// test it: what agents did since the user last marked it seen (GET
// /api/coach/news), one group per agent, newest first, a line per change
// to the plan and a line each for the activities copied and the notes and
// goals written. A change links to its day on the Calendar and, while it can
// be, offers the button that takes it back.

import { shortDay } from "./calendar.js";
import { AGENT_NAME, writtenDay } from "./coach.js";
import { dayNear, fieldChanges, undoLabel } from "./plan-changes.js";
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

// A change to the plan as a line: what happened, the day to show, and the
// change when it can be taken back.
function changeItem(change, today, unit) {
  const title = change.title || (change.item_kind === "session" ? "a session" : "a routine");
  const day = (iso) => dayNear(iso, today);
  const item = (text, date) => ({ text, href: date ? calendarHref(date) : null, title, undo: undoLabel(change) ? change : null });
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
// each item { text, href, title, undo } (href and undo may be null). First
// the plan: planned sessions add up to one line ("Planned 6 sessions, Nov
// 16 to Dec 3"), then the other changes in the order made. Then the
// activities copied, then the notes and goals written.
export function newsGroups(news, { today, unit = "km" } = {}) {
  const groups = new Map();
  const group = (name, time) => {
    const who = name || AGENT_NAME;
    const found = groups.get(who) ?? { who, latest: time, plan: [], copied: [], notes: [], goals: [] };
    if (time > found.latest) found.latest = time;
    groups.set(who, found);
    return found;
  };
  for (const change of news?.changes ?? []) group(change.agent_name, change.created_at).plan.push(change);
  for (const copied of news?.activities ?? []) group(copied.agent_name, copied.created_at).copied.push(copied);
  for (const note of news?.notes ?? []) group(note.author_name, note.created_at).notes.push(note);
  for (const goal of news?.goals ?? []) group(goal.agent_name, goal.created_at).goals.push(goal);

  return [...groups.values()].sort((a, b) => (a.latest < b.latest ? 1 : -1)).map((g) => {
    const sessions = g.plan.filter((c) => c.action === "planned" && c.item_kind === "session");
    const items = [];
    if (sessions.length > 1) {
      const days = sessions.map((c) => c.to_date).sort();
      items.push({ text: `Planned ${sessions.length} sessions, ${span(days[0], days.at(-1))}`, href: calendarHref(days[0]), title: "them", undo: null });
    }
    for (const change of [...g.plan].reverse()) {
      if (sessions.length > 1 && sessions.includes(change)) continue;
      const item = changeItem(change, today, unit);
      if (item) items.push(item);
    }
    for (const copied of g.copied) {
      const from = copied.sources.length ? ` from ${listed(copied.sources.map(sourceLabel))}` : "";
      items.push({ text: `Copied ${plural(copied.count, "activity", "activities")}${from}, ${span(copied.from, copied.to)}`, href: calendarHref(copied.to), title: "them", undo: null });
    }
    const wrote = ["status", "focus", "concern", "note"].map((kind) => {
      const count = g.notes.filter((n) => n.kind === kind).length;
      return count ? plural(count, kind, { status: "statuses", focus: "focus notes" }[kind]) : null;
    }).filter(Boolean);
    const said = [wrote.length && `wrote ${listed(wrote)}`, g.goals.length && `proposed ${plural(g.goals.length, "goal")}`].filter(Boolean).join("; ");
    if (said) items.push({ text: said[0].toUpperCase() + said.slice(1), href: null, title: null, undo: null });
    return { who: g.who, when: g.latest ? writtenAt(g.latest, today) : "", items };
  });
}

// How many things are news, as GET /api/me counts them for the Coach tab.
export const newsCount = (news) => (news?.changes?.length ?? 0) + (news?.notes?.length ?? 0) + (news?.goals?.length ?? 0) +
  (news?.activities ?? []).reduce((sum, copied) => sum + copied.count, 0);

// Whether there is anything to show.
export const hasNews = (news) => Boolean(news) && ["changes", "notes", "goals", "activities"].some((key) => news[key]?.length);

// Marking it seen, up to the newest thing shown, so anything made since
// stays news.
export const seenRequest = (news) => ({ method: "POST", path: "/api/coach/seen", body: news?.latest ? { until: news.latest } : {} });
