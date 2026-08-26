# The Cave Handbook — SOP Repository Hub

A team-facing hub for standard operating procedures, built from the design
mockups in `SOP_Site_Mockups_standalone.html`. Static front-end prototype —
no build step, no backend. Sample data lives in `assets/js/data.js`.

## Pages

- **`index.html`** — Home dashboard: greeting, department overview tiles
  (SOP counts by status), "Waiting on you" queue, and team health.
- **`library.html`** — Browse all SOPs. Filter by department and status,
  toggle grid/list view, search by title.
- **`sop.html?id=<sop-id>`** — SOP detail: owner, review dates, sign-off
  history, "before you start" checklist, step overview, forms and related
  SOPs.
- **`run.html?id=<sop-id>`** — Phone-first step player for actually running
  a procedure: info steps, checklists that gate progress, decision steps
  with branching options, step-flagging, pause, and a sign-off completion
  screen with a recap of decisions made.

## Design system

Colors, type (Barlow / Barlow Condensed via Google Fonts) and status
badges (current / review due / overdue / draft) live in
`assets/css/styles.css` as CSS custom properties, matching the navy/yellow
brand from the mockups.

## Running locally

No build tooling required — just serve the directory statically:

```
python3 -m http.server 8000
```

Then open `http://localhost:8000/index.html`.

## Data model

Everything is driven by the `SOPS` array in `assets/js/data.js` — each SOP
has metadata (owner, status, review dates, sign-offs) and a `steps` array
consumed by both the detail page (as an outline) and the run mode (as an
interactive player). Add a new SOP by adding an entry there; no other code
changes are needed for it to show up in the library, dashboard counts, and
run mode.

## Next steps

This is a front-end prototype: there's no persistence layer, auth, or real
sign-off/audit trail yet. Natural next steps are a backend (SOP CRUD,
review scheduling, sign-off records) and wiring the "Edit" / "History" /
"New SOP" actions currently stubbed in the UI.
