import { getJson, send, errorMessage } from "./api.js";
import { html, busy } from "./html.js";
import { byFit, fitLine, gearChips } from "./gear.js";

// The example programs, drawn in a list with an Import button each: in the
// Workouts page's "From an example" sheet and on the welcome screen. Best
// fit first: each says how it fits the gear the user owns and lists that
// gear, a missing piece marked. An imported one says "Imported" in the
// button's place and offers another copy under "What's in it", after asking.

// "2 workouts, 25-30 min": the main workouts and their minutes.
export function exampleSummary(example) {
  const mains = example.workouts.filter((workout) => workout.kind === "workout").map((workout) => workout.estimated_minutes);
  if (mains.length === 0) return "";
  const [low, high] = [Math.min(...mains), Math.max(...mains)];
  return `${mains.length} ${mains.length === 1 ? "workout" : "workouts"}, ${low === high ? low : `${low}-${high}`} min`;
}

// "Session A: Knees and pull · 25 min": a workout of an example, as listed
// under "What's in it". Warm-ups and cool-downs go without minutes.
export function workoutHeading(workout) {
  const title = workout.subtitle ? `${workout.title}: ${workout.subtitle}` : workout.title;
  return workout.kind === "workout" ? `${title} · ${workout.estimated_minutes} min` : title;
}

// The gear an example needs, each piece marked as owned (a tick) or not
// ("not yours yet", with a cross): never told by colour alone.
export function gearLine(example) {
  const gear = example.gear ?? [];
  return gearChips(gear.map((piece) => piece.slug), {
    names: () => gear.map((piece) => piece.name),
    owned: new Set(gear.filter((piece) => piece.owned).map((piece) => piece.slug)),
    label: "Gear it needs", classes: "equipment-list small example-gear", tick: true,
  });
}

// `list` holds the examples, `error` and `done` say how an import went.
// `href` is where the done line sends the user to see the imported workouts;
// `onImported` is called once one is in.
export function mountExamples({ list, error, done, href = "/#workouts", onImported = () => {} }) {
  const showError = (message) => {
    error.textContent = message ?? "";
    error.hidden = !message;
  };

  // `open`: the slugs whose "What's in it" stays open through a redraw.
  async function load(open = new Set()) {
    let examples;
    try {
      const { data, stale } = await getJson("/api/examples");
      if (stale) throw new Error("offline");
      examples = data;
    } catch {
      list.innerHTML = html`<li class="muted">The list shows when the server is reachable.</li>`;
      return;
    }
    list.innerHTML = html`${byFit(examples).map((example) => html`
      <li>
        <div class="example-head">
          <span class="device-name"><strong>${example.name}</strong><br>
            <span class="muted">${exampleSummary(example)}</span></span>
          ${example.imported
            ? html`<span class="imported-mark">Imported <span aria-hidden="true">✓</span></span>`
            : html`<button class="secondary small" data-import="${example.slug}" data-name="${example.name}">Import</button>`}
        </div>
        ${example.description ? html`<p class="example-description">${example.description}</p>` : ""}
        <p class="example-fit${example.missing_exercises ? " short" : ""}">${fitLine(example)}</p>
        ${gearLine(example)}
        <details class="example-contents" data-slug="${example.slug}"${open.has(example.slug) ? " open" : ""}>
          <summary>What's in it</summary>
          <ul>${example.workouts.map((workout) => html`
            <li><strong>${workoutHeading(workout)}</strong>
              <span class="muted">${(workout.exercises ?? []).join(", ")}</span></li>`)}</ul>
          ${example.imported ? html`<button class="quiet small" data-import="${example.slug}" data-name="${example.name}" data-copy="true">Import another copy</button>` : ""}
        </details>
      </li>`)}`;
  }

  list.onclick = async (event) => {
    const button = event.target.closest("[data-import]");
    if (!button) return;
    const copy = button.dataset.copy === "true";
    if (copy && !confirm(`You have ${button.dataset.name} already. Import another copy?`)) return;
    const open = new Set([...list.querySelectorAll("details[open]")].map((details) => details.dataset.slug));
    let imported = false;
    showError(null);
    done.hidden = true;
    busy(button);
    try {
      const response = await send(`/api/examples/${encodeURIComponent(button.dataset.import)}/import`, { body: copy ? { copy: true } : {} });
      const json = await response.json().catch(() => null);
      if (!response.ok) return showError(errorMessage(json, response.status));
      done.innerHTML = html`${json.name} is in your <a href="${href}">workouts</a>.`;
      done.hidden = false;
      imported = true;
      onImported(json);
    } catch {
      showError("Couldn't reach the server. Try again when you're online.");
    } finally {
      busy(button, false);
      // The pressed button goes in the redraw: focus moves to what happened.
      await load(open);
      if (imported) {
        done.setAttribute("tabindex", "-1");
        done.focus();
      }
    }
  };

  return { load };
}
