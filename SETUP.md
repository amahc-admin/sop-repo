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

## Commission review (the Commission tab)

A weekly board for discounts over 5%, freight charged under cost,
refunds and sales claims. Reps state their case (with screenshot proof)
while calls are fresh; a reviewer accepts the AI's read, waives, counts
or escalates each flag; anything undecided at month-end counts as-is.
It lives at `#/commission` and has its **own per-person login**, so the
Monday Slack ping can link reps straight to it.

**It is locked down harder than the handbook.** SOPs are public-read, but
commission data is not: those tables have no public read access at all.
Every call checks that person's own passcode, a rep only ever gets their
own orders back, and only reviewers can import, decide, ask or escalate.

### 1. Run the migration

In the Supabase SQL Editor, run `supabase/migrations/0018_commission_review.sql`.
It's safe to re-run. Optionally, also run `supabase/commission-demo-seed.sql`
to load the September orders from the walkthrough deck, so the board isn't
empty on day one. Remove them later with
`delete from commission_flags where period = '2026-09';`.

### 2. Set everyone's passcode

The migration creates Anj and Jaya (reviewers; Jaya is the one Anj
escalates to) and Lachy and Beshoy (reps). Each has the temporary passcode
`changeme-<id>`. Change every one before sharing the link, and give each
person only their own passcode:

```sql
update commission_people set passcode_hash = crypt('their-new-passcode', gen_salt('bf')) where id = 'lachy';
```

Add a rep:

```sql
insert into commission_people (id, name, role, passcode_hash, slack_mention)
values ('newrep', 'Their Name', 'rep', crypt('their-passcode', gen_salt('bf')), '<@SLACKUSERID>');
```

Use `role = 'reviewer'` for a reviewer and `is_approver = true` for whoever
escalations go to. Set `active = false` to remove someone's access without
losing their history.

### 3. Slack: the #commission-review channel

Create a **private** channel, add an Incoming Webhook to it, then:

```sql
select vault.create_secret('https://hooks.slack.com/services/...', 'commission_slack_webhook_url', 'Commission review channel');
select vault.create_secret('https://<your-pages-url>/#/commission', 'commission_board_url', 'Commission board link');
```

This is a separate webhook from the handbook's, so commission numbers never
land in the general channel. Questions to reps, escalations and week
sign-offs post there automatically.

To post the Monday 8am ping automatically, enable the `pg_cron` extension
(Database → Extensions) and schedule it. pg_cron runs in **UTC**: 8am
Monday Sydney time (AEDT, UTC+11) is Sunday 21:00 UTC. Adjust for your
timezone and for daylight saving.

```sql
select cron.schedule('commission-weekly-ping', '0 21 * * 0', 'select commission_weekly_ping()');
```

Reviewers can also preview the ping, or post it by hand, from the board
(**Monday ping**).

### 4. Getting flags in

The board shows the AI's pre-read but doesn't do it itself. Flags come in
through `commission_import`, which takes a JSON array. Paste one into
**Import flags** on the board, or have the overnight job (Shopify +
Fathom/call recordings + website history) post it to
`POST <supabase-url>/rest/v1/rpc/commission_import` with
`{"p_person_id": "<reviewer id>", "p_passcode": "...", "p_rows": [...]}`.
Re-importing an order refreshes its numbers and AI read. It never
overwrites a rep's answer or a reviewer's decision.

One flag, with every field shown (only `order_no`, `order_date`, `rep`
and `amount` are required):

```json
{
  "order_no": "23544", "kind": "discount", "order_date": "2026-09-01",
  "customer": "Karan Singh", "rep": "Beshoy", "gross": 3027, "amount": 509, "pct": 16.8,
  "order_url": "https://admin.shopify.com/store/.../orders/...",
  "slices": [
    {"type": "code", "label": "B33RMONEY", "note": "live site code — company's", "amount": 27, "side": "company"},
    {"type": "rep custom", "label": "Custom discount", "note": "unnamed, rep-keyed", "amount": 91, "side": "rep"}
  ],
  "ai": {
    "verdict": "partial", "waive_amount": 27, "confidence": 80, "discussed_on_call": true,
    "reviewed_at": "2026-10-01T02:00:00Z",
    "summary": "One line for the call view.",
    "points": ["Code B33RMONEY was live on 1 Sep, so its $27 slice is company-side. Waived."],
    "quotes": [{"speaker": "rep", "text": "you're getting the kit for free", "call_id": "c1", "t": 95}]
  },
  "calls": [
    {"id": "c1", "source": "Fathom", "date": "2026-09-01", "rep": "Beshoy", "minutes": 6, "direction": "inbound",
     "audio_url": null, "url": "https://fathom.video/calls/...",
     "lines": [{"speaker": "rep", "name": "Beshoy", "t": 95, "text": "..."}]}
  ]
}
```

- `kind`: `discount`, `freight`, `refund` or `claim`.
- `amount`: the dollars at stake. For freight it's cost minus charged; a
  negative amount means over-recovered, which shows green and counts for
  the rep. Freight also takes `"details": {"service": "...", "charged": 90, "cost": 350}`.
- `ai.verdict`: `waive`, `partial` (with `waive_amount`), `counts`, or for
  claims `related` / `unrelated`.
- A CSV with a header row
  (`order_no,kind,order_date,customer,rep,gross,amount,pct,order_url`, plus
  `service,charged,cost` for freight) also works for a quick manual load,
  but it carries no AI read or breakdown.

### Rules the board enforces

- Reasons that the rule says must be proven (**Osama run**, **Private
  courier**, **Approved by Jaya or Ross**) are refused without a screenshot
  or link attached. This is checked server-side, not just in the form.
- Only a reviewer's click moves money. Every answer, question,
  escalation, decision and reopen is logged with the person's name and
  time, and shown under the order's **History**.
- A week can only be signed off once every flag in it with money at stake
  is decided.
- **Payout totals** and **Export CSV** give accounts the weekly view:
  waived, counted, and still open (which counts as-is at month-end).

### Known limits

- Proof screenshots go to a `commission-proof` storage bucket. Each file
  has a random 128-bit name and the bucket can't be listed, but anyone
  holding a file's exact URL can open it. That matches the rest of the
  app's upload model.
- The board shows dollars that count against each rep's commission base.
  It doesn't calculate the commission rate or payout itself, because
  those rules aren't in this repo.
