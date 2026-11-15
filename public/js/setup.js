// First run, kept free of the DOM: the rows of Today's "Getting set up"
// card, and the weekly routines the welcome makes from the days picked.

// The card's rows from GET /api/account/setup, in the order they are done.
// Adding the app to the Home Screen shows only in a browser tab
// (`standalone` false); inviting and connecting an assistant are the
// owner's (`setup.invited` is null for anyone else).
export function setupRows(setup, { standalone = false } = {}) {
  const rows = [
    { key: "gear", label: "Tell the app what you own", hint: "Workouts keep to your gear, and programs fit its weights.", href: "/equipment.html", done: setup.gear },
    { key: "program", label: "Get a program", hint: "Import an example program, or build a workout of your own.", href: "/settings.html#examples", done: setup.workouts },
    { key: "plan", label: "Plan your week", hint: "Put your training days on the Calendar.", href: "/calendar.html", done: setup.planned },
  ];
  if (!standalone) {
    rows.push({
      key: "install", label: "Add it to your Home Screen",
      hint: "On an iPad or iPhone, tap Share in Safari, then Add to Home Screen; other browsers offer Install in their menu. It opens full screen and keeps a session going offline.",
      href: null, done: false, optional: true,
    });
  }
  if (setup.invited !== null && setup.invited !== undefined) {
    rows.push(
      { key: "invite", label: "Invite someone", hint: "They get their own workouts, calendar and gear.", href: "/settings.html#users", done: setup.invited, optional: true },
      { key: "assistant", label: "Connect a coach assistant", hint: "An AI assistant can read your training and plan workouts.", href: "/settings.html#api-tokens", done: setup.assistant, optional: true },
    );
  }
  return rows;
}

// Whether anything is left to do: gear, a program and the week. The rest
// is offered, never owed (and a browser tab can't tell the app was
// installed from another).
export function setupLeft(rows) {
  return rows.some((row) => !row.done && !row.optional);
}

// The weekly routines for a program's main workouts on the `weekdays`
// picked (ISO, 1 Monday to 7 Sunday): the workouts take turns through the
// week, so with A and B on Monday, Wednesday and Friday, A gets Monday and
// Friday. A workout left without a day gets no routine.
export function weekPlan(workouts, weekdays) {
  const days = [...new Set(weekdays)].sort((a, b) => a - b);
  if (workouts.length === 0) return [];
  return workouts
    .map((workout, i) => ({ workout_id: workout.id, weekdays: days.filter((_, j) => j % workouts.length === i) }))
    .filter((routine) => routine.weekdays.length > 0);
}

// The program the welcome plans: the newest with a main workout, and those
// workouts in order. Null when there is none.
export function programToPlan(programs) {
  for (const program of [...programs].sort((a, b) => b.id - a.id)) {
    const mains = program.workouts.filter((workout) => workout.kind === "workout" && !workout.archived);
    if (mains.length) return { program, workouts: [...mains].sort((a, b) => a.position - b.position) };
  }
  return null;
}
