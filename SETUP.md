# Cave Handbook — GitHub + Supabase setup

This is the real, self-hosted rebuild of the Cave Handbook: a static site
(anyone with the link can open it, no Claude account needed) backed by a
real Postgres database on Supabase. Every write (approve, edit, add SOP,
disapprove/delete, suggestions) is verified server-side by a shared
per-department passcode — see `supabase/migrations/0001_init.sql` for
exactly how that's enforced.

## 1. Create the Supabase project

1. Go to https://supabase.com, sign in, and create a new project (free tier
   is fine). Pick any name/region; save the database password it asks you
   to set (you likely won't need it again, but keep it somewhere safe).
2. Wait for the project to finish provisioning.
3. Open the **SQL Editor** in the Supabase dashboard.
4. Paste the entire contents of `supabase/migrations/0001_init.sql` and run
   it. This creates the tables, the `departments`/`sops`/`sop_events`/
   `suggestions` schema, row-level security policies, and the
   passcode-gated RPC functions (`login_department`, `approve_sop`,
   `edit_sop`, `add_sop`, `disapprove_sop`, `add_suggestion`,
   `approve_suggestion`).
5. Paste the entire contents of `supabase/seed.sql` and run it. This loads
   the current handbook content (27 SOPs, 7 departments, approval history)
   migrated from the previous version of the handbook.

## 2. Set real department passcodes (do this before sharing the link)

`supabase/seed.sql` gives every department a temporary passcode of
`changeme-<department id>` (e.g. `changeme-installations`,
`changeme-sales`). **Change every one of these** before you tell anyone the
site's URL, or anyone who guesses the pattern can act as any department.

In the Supabase SQL Editor, run one `update` per department with your own
passcode:

```sql
update departments set passcode_hash = crypt('your-new-passcode-here', gen_salt('bf'))
where id = 'installations';
```

Repeat for each of: `operations`, `sales`, `cx`, `installations`,
`marketing`, `accounts`, `exec`. Share each department's passcode only with
the people on that team (Slack DM, a password manager entry, etc.) — not in
a company-wide channel.

You can change any department's passcode again at any time the same way,
if it ever needs to be rotated (e.g. someone leaves the team).

## 3. Get your project's API URL and anon key

In the Supabase dashboard: **Project Settings → API**. Copy:

- **Project URL** (looks like `https://xxxxxxxxxxxx.supabase.co`)
- **anon / public key** (a long string starting with `eyJ...`)

The anon key is meant to be public — it's safe to commit to this repo and
ship to every visitor's browser. It does not grant any access by itself;
every actual permission check happens in Postgres (see the migration file).

Open `web/js/config.js` and fill in both values:

```js
window.SUPABASE_CONFIG = {
  url: "https://xxxxxxxxxxxx.supabase.co",
  anonKey: "eyJ...",
};
```

Commit and push that change.

## 4. Turn on GitHub Pages

1. In this repo on GitHub: **Settings → Pages**.
2. Under "Build and deployment", set **Source** to **GitHub Actions** (not
   "Deploy from a branch").
3. The workflow at `.github/workflows/deploy-pages.yml` deploys the `web/`
   folder automatically on every push to `main` that touches `web/`. If
   your default branch isn't `main`, edit the `branches:` line in that
   workflow to match, or just push this work to `main`.
4. Push to `main` (or trigger the workflow manually from the Actions tab)
   and wait for the "Deploy Cave Handbook to GitHub Pages" run to go green.
5. Your site is now live at the URL GitHub Pages shows in
   Settings → Pages (typically `https://<org>.github.io/<repo>/web/` or a
   custom domain if you set one up).

## 5. Try it

- Open the deployed URL. You should see the Home dashboard with real data
  (Library should show all the SOPs).
- Click the avatar icon (top right) → pick a department → enter its
  passcode → you should be logged in (the avatar shows the department's
  code).
- Open a SOP owned by that department and try Approve / Edit / Disapprove
  — they should work. Try them on a SOP owned by a *different* department
  — they should be disabled/rejected.
- Submit a suggestion, then log in as the department that owns that SOP
  and approve it from the Suggestions page.

## What changed from the old Claude Artifact version

- **No Claude account needed.** Anyone with the site link can open it.
- **Real access control.** Each department's write access is gated by a
  passcode that's checked in Postgres on every single write — not just a
  client-side label like the old "Which department?" picker.
- **"Who's viewing" now means "logged in as."** Picking a department shows
  a passcode field; a wrong passcode is rejected by the server, not just
  the UI.
- **No more Slack posting.** That depended on the Claude Artifact's `mcp`
  capability, which doesn't exist outside claude.ai. If you want
  suggestion notifications again, that would need a small server-side
  integration (e.g. a Supabase Edge Function calling Slack's API) — not
  included here.

## Security notes worth knowing

- The shared department passcode is cached in each person's browser
  (`localStorage`) after they log in once, so they aren't asked every time.
  On a shared/public computer, anyone using that browser afterward would
  be able to act as that department until they clear it (the "Not sure /
  log out" option in the department menu does this). Treat passcodes like
  a shared office door code, not a personal password — rotate them if you
  suspect they've leaked, and don't reuse a personal password as a
  department passcode.
- `departments.passcode_hash` is never readable from the browser — Postgres
  itself refuses to return that column to the public/anon role, regardless
  of what the frontend asks for (see the `grant select (id, name, code)`
  line in the migration).
- There's no per-person audit trail beyond department + name-typed-in
  fields (e.g. "Your name" on Add SOP) — this matches the "one shared
  passcode per department" choice made instead of individual logins. If
  you later want to know exactly *which person* on a team made a change,
  that would need real per-person accounts (Supabase Auth supports this)
  instead of shared department passcodes.
