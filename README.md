# The Cave Handbook — SOP Repository Hub

A team-facing hub for standard operating procedures at A Man & His Cave: a
static site anyone with the link can open (no Claude account needed),
backed by a real Postgres database (Supabase) for shared, persistent data.

**See [SETUP.md](SETUP.md) for how to stand this up** (create the Supabase
project, run the migration, set department passcodes, turn on GitHub
Pages).

## How it works

- **`web/`** — the actual app: a single-page static site (`index.html` +
  `js/config.js` + `js/api.js`). This is what GitHub Pages deploys.
- **`supabase/migrations/0001_init.sql`** — the database schema, row-level
  security policies, and the passcode-gated RPC functions that back every
  write (approve, edit, add SOP, disapprove, suggestions).
- **`supabase/seed.sql`** — the handbook's current content (SOPs,
  departments, approval history), migrated in for the initial rollout.
- **`.github/workflows/deploy-pages.yml`** — deploys `web/` to GitHub Pages
  on every push to `main`.

Access control model: reads are public: anyone with the link can browse the
whole handbook. Writes require being "logged in" as a department (picked
from the avatar menu, top right), which means knowing that department's
shared passcode — verified server-side on every single write, not just a
client-side label. See SETUP.md's "Security notes" section for the
tradeoffs of this approach versus real per-person accounts.

## Features

- Home dashboard, department-filterable Library (grid/list), SOP detail
  pages, and a phone-first Run mode for actually walking through a
  procedure step by step.
- Department-gated **Approve**, **Edit**, **Disapprove** (delete), and
  **Add SOP** actions on every SOP.
- Per-SOP **Suggestions & feedback**, plus a dedicated Suggestions review
  page for approving them (gated by the target SOP's department).
- Update history (who approved/edited a SOP and when) on every SOP page.

## Running locally

`web/` is a plain static site — serve it and point `web/js/config.js` at
your Supabase project:

```
cd web
python3 -m http.server 8000
```

Then open `http://localhost:8000/index.html`.

## Superseded prototype

`index.html`, `library.html`, `sop.html`, `run.html` and `assets/` at the
repo root are an earlier, backend-less static prototype (no persistence,
no auth) that predates `web/`. They're left in place rather than deleted
unilaterally — if you're happy the `web/` app has replaced them, they can
be removed.
