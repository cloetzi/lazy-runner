// Today's session as the service worker's cache last saw it, made safe to
// start offline. A copy from an earlier day still has that day's session in
// it; starting from it would reopen that session, so it is dropped and the
// workout is planned for `date` instead. Its day's other sessions go too, and
// the next planned session stays only while it is still ahead (one planned
// for the new day itself has no plan in the copy to start it from). The old
// day's activities go too.
export function offlineToday(today, date) {
  if (today.date === date) return { ...today, offline: true };
  const next = today.next_planned?.date > date ? today.next_planned : null;
  return { ...today, date, session: null, source: "default", day: [], activities: [], next_planned: next, offline: true };
}
