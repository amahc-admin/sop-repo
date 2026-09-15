-- Replaces the 7 per-department logins + the general-employee ("AMAHC
-- Member") login with exactly 2 shared logins: Admin (full management --
-- approve/disapprove/add/edit) and Member (view, suggest, add a draft SOP,
-- and propose edits to an existing SOP -- but an edit proposal only takes
-- effect once an Admin approves it). Every login now also asks for the
-- person's last name, purely for attribution (who did what) -- it carries
-- no auth weight, the shared passcode still does all the gating.
--
-- Departments (Operations, Sales, CX, Installations, Marketing, Accounts,
-- Exec) stop being logins entirely and become a plain categorization tag
-- on a SOP (which team does this procedure belong to), picked explicitly
-- when adding a SOP rather than implied by who's logged in.

-- ============================== logins ==============================
-- Safe to re-run: the Supabase SQL Editor commits each statement as it
-- succeeds (not one atomic transaction for the whole pasted script), so a
-- run that failed partway through can leave this table already created.
drop table if exists logins cascade;
create table logins (
  id text primary key,
  name text not null,
  code text not null,
  passcode_hash text not null,
  can_manage_sops boolean not null default false
);

alter table logins enable row level security;

create policy "logins are publicly readable (id/name/code only)"
  on logins for select
  using (true);
-- passcode_hash and can_manage_sops are never exposed to anon/authenticated:
-- see the column-scoped grant near the bottom of this file.

-- Temporary passcodes -- change these for real right after running this
-- migration (see the follow-up "set real passcodes" statement).
insert into logins (id, name, code, passcode_hash, can_manage_sops) values
  ('admin', 'Admin', 'ADM', crypt('changeme-admin', gen_salt('bf')), true),
  ('member', 'Member', 'MEM', crypt('changeme-member', gen_salt('bf')), false);

-- ============================== sop_events / suggestions ==============
-- These columns used to hold the acting DEPARTMENT's id/name/code. They
-- now hold the acting LOGIN's id ('admin'/'member') and the person's last
-- name instead. Historical rows keep their old department values as-is --
-- harmless, since these are just attribution labels, not foreign keys
-- anything depends on. The FK to departments(id) is dropped since login_id
-- no longer refers to a row in that table. This has to happen BEFORE the
-- departments cleanup below, since suggestions.department_id still had a
-- 'general' row referencing departments('general') until this FK is gone.
alter table sop_events drop constraint if exists sop_events_department_id_fkey;
alter table sop_events rename column department_id to login_id;
alter table sop_events rename column department_name to actor_last_name;
alter table sop_events drop column if exists department_code;

alter table suggestions drop constraint if exists suggestions_department_id_fkey;
alter table suggestions drop constraint if exists suggestions_approved_by_dept_id_fkey;
alter table suggestions rename column department_id to login_id;
alter table suggestions rename column department_name to last_name;
alter table suggestions rename column approved_by_dept_id to approved_by_login_id;
alter table suggestions rename column approved_by_dept_name to approved_by_last_name;

-- departments is now a plain lookup of SOP category tags -- drop the
-- login-only columns and the general-employee row that lived here.
delete from departments where id = 'general';
alter table departments drop column if exists passcode_hash;
alter table departments drop column if exists can_manage_sops;
-- No sensitive column is left on departments, so a plain full-table grant
-- (see bottom of file) replaces the old column-scoped one.

-- ============================== sop_edit_proposals ======================
-- A Member's edit to an EXISTING SOP doesn't apply immediately -- it's
-- stored here as a pending proposal (same p_fields shape edit_sop always
-- took) until an Admin approves or rejects it. Approving applies the
-- fields exactly like edit_sop does and logs the same kind of sop_events
-- row (so the existing "what changed" fields JSON is what the UI can use
-- to highlight the diff, both at review time and after approval).
create table sop_edit_proposals (
  id text primary key,
  sop_id text not null references sops(id) on delete cascade,
  login_id text not null references logins(id),
  last_name text not null,
  fields jsonb not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by_last_name text,
  decided_date text,
  ts bigint not null,
  created_at timestamptz not null default now()
);

alter table sop_edit_proposals enable row level security;

create policy "sop_edit_proposals are publicly readable"
  on sop_edit_proposals for select
  using (true);

-- ============================== helpers ==============================

create or replace function _check_login(p_login_id text, p_passcode text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
begin
  select passcode_hash into v_hash from logins where id = p_login_id;
  if v_hash is null or p_passcode is null or crypt(p_passcode, v_hash) <> v_hash then
    raise exception 'wrong login or passcode' using errcode = '28000';
  end if;
end;
$$;

create or replace function _require_admin(p_login_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_can boolean;
begin
  select can_manage_sops into v_can from logins where id = p_login_id;
  if v_can is not true then
    raise exception 'only an Admin can do this' using errcode = '28000';
  end if;
end;
$$;

-- Derives up to 3 initials from a person's name, e.g. for signed_off_by
-- and owner_initials. Falls back to 'NA' if nothing usable is given.
create or replace function _initials(p_name text)
returns text
language plpgsql
immutable
as $$
declare
  v_initials text;
begin
  select upper(left(string_agg(left(w, 1), '' order by ord), 3))
    into v_initials
    from unnest(regexp_split_to_array(trim(coalesce(p_name, '')), '\s+')) with ordinality as t(w, ord)
    where w <> '';
  return coalesce(nullif(v_initials, ''), 'NA');
end;
$$;

drop function if exists _check_passcode(text, text);
drop function if exists _require_manage_sops(text);

-- ============================== write RPCs ==============================

drop function if exists login_department(text, text);
drop function if exists approve_sop(text, text, text);
drop function if exists disapprove_sop(text, text, text);
drop function if exists edit_sop(text, text, text, jsonb);
drop function if exists add_sop(text, text, jsonb);
drop function if exists add_suggestion(text, text, text, text);
drop function if exists approve_suggestion(text, text, text);

create or replace function login(p_login_id text, p_passcode text)
returns table (id text, name text, code text, can_manage_sops boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform _check_login(p_login_id, p_passcode);
  return query select l.id, l.name, l.code, l.can_manage_sops from logins l where l.id = p_login_id;
end;
$$;

create or replace function approve_sop(
  p_sop_id text, p_login_id text, p_passcode text, p_last_name text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_title text;
  v_ts bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  perform _check_login(p_login_id, p_passcode);
  perform _require_admin(p_login_id);

  select title into v_title from sops where id = p_sop_id;
  if v_title is null then
    raise exception 'SOP not found';
  end if;

  update sops set
    status = 'current',
    last_reviewed = _event_stamp_month(v_ts),
    signed_off_by = signed_off_by || jsonb_build_array(jsonb_build_object(
      'name', p_last_name, 'initials', _initials(p_last_name), 'date', _event_stamp_date(v_ts)
    )),
    updated_at = now()
  where id = p_sop_id;

  insert into sop_events (sop_id, kind, login_id, actor_last_name, ts, full_date, month_year)
  values (p_sop_id, 'approved', p_login_id, p_last_name, v_ts, _event_stamp_date(v_ts), _event_stamp_month(v_ts));

  perform _notify_slack(':white_check_mark: *' || p_last_name || '* (Admin) approved *' || v_title || '*');
end;
$$;

create or replace function disapprove_sop(
  p_sop_id text, p_login_id text, p_passcode text, p_last_name text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_title text;
begin
  perform _check_login(p_login_id, p_passcode);
  perform _require_admin(p_login_id);

  select title into v_title from sops where id = p_sop_id;
  if v_title is null then
    raise exception 'SOP not found';
  end if;

  delete from sops where id = p_sop_id;

  perform _notify_slack(':wastebasket: *' || p_last_name || '* (Admin) removed *' || v_title || '*');
end;
$$;

-- Admin-only, applies immediately (unlike propose_sop_edit below). p_fields
-- is the same shape sops itself is: title, subtitle, never_do_this,
-- before_you_start, tools_systems, steps, success_criteria, escalation,
-- forms -- only keys present are applied.
create or replace function edit_sop(
  p_sop_id text, p_login_id text, p_passcode text, p_last_name text, p_fields jsonb
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_title text;
  v_ts bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  perform _check_login(p_login_id, p_passcode);
  perform _require_admin(p_login_id);

  select title into v_title from sops where id = p_sop_id;
  if v_title is null then
    raise exception 'SOP not found';
  end if;

  update sops set
    title = coalesce(p_fields->>'title', title),
    subtitle = coalesce(p_fields->>'subtitle', subtitle),
    never_do_this = case when p_fields ? 'never_do_this' then p_fields->>'never_do_this' else never_do_this end,
    before_you_start = coalesce(p_fields->'before_you_start', before_you_start),
    tools_systems = coalesce(p_fields->'tools_systems', tools_systems),
    steps = coalesce(p_fields->'steps', steps),
    success_criteria = coalesce(p_fields->'success_criteria', success_criteria),
    escalation = coalesce(p_fields->'escalation', escalation),
    forms = coalesce(p_fields->'forms', forms),
    status = 'review-due',
    updated_at = now()
  where id = p_sop_id;

  insert into sop_events (sop_id, kind, login_id, actor_last_name, ts, full_date, month_year, fields)
  values (p_sop_id, 'edited', p_login_id, p_last_name, v_ts, _event_stamp_date(v_ts), _event_stamp_month(v_ts), p_fields);

  perform _notify_slack(':memo: *' || p_last_name || '* (Admin) edited *' || coalesce(p_fields->>'title', v_title) || '*');
end;
$$;

-- p_department_tag is one of the 7 department category ids (Operations,
-- Sales, ...) -- purely a label for filtering/organizing, unrelated to who
-- is logged in. Any valid login (Admin or Member) can add a SOP; it always
-- starts as a draft, same as before, awaiting an Admin's approve_sop call.
create or replace function add_sop(
  p_login_id text, p_passcode text, p_last_name text, p_department_tag text, p_sop jsonb
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id text;
  v_title text := p_sop->>'title';
begin
  perform _check_login(p_login_id, p_passcode);
  if v_title is null or trim(v_title) = '' then
    raise exception 'title can''t be empty';
  end if;
  if coalesce(jsonb_array_length(p_sop->'steps'), 0) = 0 then
    raise exception 'add at least one step before saving';
  end if;
  if trim(coalesce(p_last_name, '')) = '' then
    raise exception 'enter your last name before saving';
  end if;
  if not exists (select 1 from departments where id = p_department_tag) then
    raise exception 'unknown department';
  end if;

  v_id := _unique_sop_id(v_title);

  insert into sops (
    id, title, department, status, owner_name, owner_initials, version,
    subtitle, before_you_start, tools_systems, steps, success_criteria,
    escalation, forms, never_do_this
  ) values (
    v_id, v_title, p_department_tag, 'draft', p_last_name, _initials(p_last_name), 'v1 (draft)',
    coalesce(p_sop->>'subtitle', ''),
    coalesce(p_sop->'before_you_start', '[]'::jsonb),
    coalesce(p_sop->'tools_systems', '[]'::jsonb),
    p_sop->'steps',
    coalesce(p_sop->'success_criteria', '[]'::jsonb),
    coalesce(p_sop->'escalation', '[]'::jsonb),
    coalesce(p_sop->'forms', '[]'::jsonb),
    nullif(p_sop->>'never_do_this', '')
  );

  perform _notify_slack(':new: *' || p_last_name || '* added a new SOP: *' || v_title || '*');

  return v_id;
end;
$$;

create or replace function add_suggestion(
  p_sop_id text, p_login_id text, p_passcode text, p_last_name text, p_text text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_login logins%rowtype;
  v_sop_title text;
  v_id text := 'sg-' || (extract(epoch from now()) * 1000)::bigint || '-' || substr(encode(gen_random_bytes(4), 'hex'), 1, 5);
begin
  perform _check_login(p_login_id, p_passcode);
  if p_text is null or trim(p_text) = '' then
    raise exception 'write a suggestion before sending';
  end if;
  select * into v_login from logins where id = p_login_id;
  select title into v_sop_title from sops where id = p_sop_id;

  insert into suggestions (id, sop_id, login_id, last_name, text, ts)
  values (v_id, p_sop_id, p_login_id, p_last_name, p_text, (extract(epoch from now()) * 1000)::bigint);

  perform _notify_slack(':bulb: *' || p_last_name || '* (' || v_login.name || ') suggested on *' || v_sop_title || '*:' || chr(10) || '> ' || p_text);

  return v_id;
end;
$$;

create or replace function approve_suggestion(
  p_suggestion_id text, p_login_id text, p_passcode text, p_last_name text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform _check_login(p_login_id, p_passcode);
  perform _require_admin(p_login_id);

  if not exists (select 1 from suggestions where id = p_suggestion_id) then
    raise exception 'suggestion not found';
  end if;

  update suggestions set
    status = 'approved',
    approved_by_login_id = p_login_id,
    approved_by_last_name = p_last_name,
    approved_date = _event_stamp_date((extract(epoch from now()) * 1000)::bigint)
  where id = p_suggestion_id;
end;
$$;

-- A Member's edit proposal: same p_fields shape as edit_sop, but it sits
-- pending until an Admin calls approve_sop_edit or reject_sop_edit below.
create or replace function propose_sop_edit(
  p_sop_id text, p_login_id text, p_passcode text, p_last_name text, p_fields jsonb
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_login logins%rowtype;
  v_title text;
  v_id text := 'ep-' || (extract(epoch from now()) * 1000)::bigint || '-' || substr(encode(gen_random_bytes(4), 'hex'), 1, 5);
begin
  perform _check_login(p_login_id, p_passcode);
  if trim(coalesce(p_last_name, '')) = '' then
    raise exception 'enter your last name before saving';
  end if;
  select * into v_login from logins where id = p_login_id;
  select title into v_title from sops where id = p_sop_id;
  if v_title is null then
    raise exception 'SOP not found';
  end if;

  insert into sop_edit_proposals (id, sop_id, login_id, last_name, fields, ts)
  values (v_id, p_sop_id, p_login_id, p_last_name, p_fields, (extract(epoch from now()) * 1000)::bigint);

  perform _notify_slack(':pencil2: *' || p_last_name || '* (' || v_login.name || ') proposed edits to *' || coalesce(p_fields->>'title', v_title) || '* -- awaiting Admin approval');

  return v_id;
end;
$$;

create or replace function approve_sop_edit(
  p_proposal_id text, p_login_id text, p_passcode text, p_last_name text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_proposal sop_edit_proposals%rowtype;
  v_title text;
  v_ts bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  perform _check_login(p_login_id, p_passcode);
  perform _require_admin(p_login_id);

  select * into v_proposal from sop_edit_proposals where id = p_proposal_id and status = 'pending';
  if not found then
    raise exception 'proposal not found or already decided';
  end if;

  select title into v_title from sops where id = v_proposal.sop_id;

  update sops set
    title = coalesce(v_proposal.fields->>'title', title),
    subtitle = coalesce(v_proposal.fields->>'subtitle', subtitle),
    never_do_this = case when v_proposal.fields ? 'never_do_this' then v_proposal.fields->>'never_do_this' else never_do_this end,
    before_you_start = coalesce(v_proposal.fields->'before_you_start', before_you_start),
    tools_systems = coalesce(v_proposal.fields->'tools_systems', tools_systems),
    steps = coalesce(v_proposal.fields->'steps', steps),
    success_criteria = coalesce(v_proposal.fields->'success_criteria', success_criteria),
    escalation = coalesce(v_proposal.fields->'escalation', escalation),
    forms = coalesce(v_proposal.fields->'forms', forms),
    status = 'review-due',
    updated_at = now()
  where id = v_proposal.sop_id;

  insert into sop_events (sop_id, kind, login_id, actor_last_name, ts, full_date, month_year, fields)
  values (v_proposal.sop_id, 'edited', v_proposal.login_id, v_proposal.last_name, v_ts, _event_stamp_date(v_ts), _event_stamp_month(v_ts), v_proposal.fields);

  update sop_edit_proposals set
    status = 'approved',
    decided_by_last_name = p_last_name,
    decided_date = _event_stamp_date(v_ts)
  where id = p_proposal_id;

  perform _notify_slack(':white_check_mark: *' || p_last_name || '* (Admin) approved *' || v_proposal.last_name || '*''s edits to *' || coalesce(v_proposal.fields->>'title', v_title) || '*');
end;
$$;

create or replace function reject_sop_edit(
  p_proposal_id text, p_login_id text, p_passcode text, p_last_name text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_proposal sop_edit_proposals%rowtype;
  v_title text;
begin
  perform _check_login(p_login_id, p_passcode);
  perform _require_admin(p_login_id);

  select * into v_proposal from sop_edit_proposals where id = p_proposal_id and status = 'pending';
  if not found then
    raise exception 'proposal not found or already decided';
  end if;

  select title into v_title from sops where id = v_proposal.sop_id;

  update sop_edit_proposals set
    status = 'rejected',
    decided_by_last_name = p_last_name,
    decided_date = _event_stamp_date((extract(epoch from now()) * 1000)::bigint)
  where id = p_proposal_id;

  perform _notify_slack(':x: *' || p_last_name || '* (Admin) rejected *' || v_proposal.last_name || '*''s proposed edits to *' || coalesce(v_title, '') || '*');
end;
$$;

-- ============================== grants ==============================

grant execute on function login(text, text) to anon, authenticated;
grant execute on function approve_sop(text, text, text, text) to anon, authenticated;
grant execute on function disapprove_sop(text, text, text, text) to anon, authenticated;
grant execute on function edit_sop(text, text, text, text, jsonb) to anon, authenticated;
grant execute on function add_sop(text, text, text, text, jsonb) to anon, authenticated;
grant execute on function add_suggestion(text, text, text, text, text) to anon, authenticated;
grant execute on function approve_suggestion(text, text, text, text) to anon, authenticated;
grant execute on function propose_sop_edit(text, text, text, text, jsonb) to anon, authenticated;
grant execute on function approve_sop_edit(text, text, text, text) to anon, authenticated;
grant execute on function reject_sop_edit(text, text, text, text) to anon, authenticated;

grant select (id, name, code) on logins to anon, authenticated;
grant select on departments to anon, authenticated;
grant select on sop_edit_proposals to anon, authenticated;
