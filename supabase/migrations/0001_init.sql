-- Cave Handbook: schema, RLS and passcode-gated write functions.
--
-- Security model: table reads are public (anyone with the site link can
-- browse). Every write goes through a SECURITY DEFINER function that takes
-- (department_id, passcode) and re-checks the passcode against
-- departments.passcode_hash on every single call -- there is no session,
-- token or JWT to steal or replay. The base tables themselves have RLS
-- enabled with no INSERT/UPDATE/DELETE policies for the anon/authenticated
-- roles, so the only way to write is through these functions.

create extension if not exists pgcrypto;

grant usage on schema public to anon, authenticated;

-- ============================== departments ==============================
create table departments (
  id text primary key,
  name text not null,
  code text not null,
  passcode_hash text not null
);

alter table departments enable row level security;

create policy "departments are publicly readable (id/name/code only)"
  on departments for select
  using (true);
-- passcode_hash is never exposed to anon/authenticated: see the
-- column-scoped grant near the bottom of this file (grant select (id,
-- name, code) on departments ...) -- Postgres itself refuses any select
-- naming that column from those roles, regardless of what a client asks for.

-- ============================== sops ==============================
create table sops (
  id text primary key,
  sop_id text,
  title text not null,
  department text not null references departments(id),
  status text not null default 'draft'
    check (status in ('current','review-due','overdue','draft')),
  confidential boolean not null default false,
  owner_name text not null,
  owner_initials text not null,
  last_reviewed text,
  next_review text,
  version text,
  subtitle text,
  never_do_this text,
  before_you_start jsonb not null default '[]',
  tools_systems jsonb not null default '[]',
  steps jsonb not null default '[]',
  success_criteria jsonb not null default '[]',
  escalation jsonb not null default '[]',
  forms jsonb not null default '[]',
  related_ids jsonb not null default '[]',
  blackout_periods jsonb not null default '[]',
  blackout_flag text,
  signed_off_by jsonb not null default '[]',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table sops enable row level security;

create policy "sops are publicly readable"
  on sops for select
  using (true);
-- No insert/update/delete policies -- all writes go through the RPC
-- functions below, which run as SECURITY DEFINER and bypass RLS.

-- ============================== sop_events (approval + edit history) ======
create table sop_events (
  id bigint generated always as identity primary key,
  sop_id text not null references sops(id) on delete cascade,
  kind text not null check (kind in ('approved','edited')),
  department_id text not null references departments(id),
  department_name text not null,
  department_code text not null,
  ts bigint not null,
  full_date text not null,
  month_year text,
  fields jsonb,
  created_at timestamptz not null default now()
);

alter table sop_events enable row level security;

create policy "sop_events are publicly readable"
  on sop_events for select
  using (true);

-- ============================== suggestions ==============================
create table suggestions (
  id text primary key,
  sop_id text not null references sops(id) on delete cascade,
  department_id text not null references departments(id),
  department_name text not null,
  text text not null,
  ts bigint not null,
  status text not null default 'pending' check (status in ('pending','approved')),
  approved_by_dept_id text references departments(id),
  approved_by_dept_name text,
  approved_date text,
  created_at timestamptz not null default now()
);

alter table suggestions enable row level security;

create policy "suggestions are publicly readable"
  on suggestions for select
  using (true);

-- ============================== helpers ==============================

-- Verifies a department's shared passcode. Raises an exception (which
-- PostgREST turns into an HTTP error) if it doesn't match.
create or replace function _check_passcode(p_department_id text, p_passcode text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
begin
  select passcode_hash into v_hash from departments where id = p_department_id;
  if v_hash is null or p_passcode is null or crypt(p_passcode, v_hash) <> v_hash then
    raise exception 'wrong department or passcode' using errcode = '28000';
  end if;
end;
$$;

-- Slugify + de-duplicate a title into a URL-safe sop id, e.g. for add_sop.
create or replace function _unique_sop_id(p_title text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base text;
  v_id text;
  v_n int := 2;
begin
  v_base := lower(trim(regexp_replace(coalesce(p_title, ''), '[^a-zA-Z0-9]+', '-', 'g')));
  v_base := trim(both '-' from v_base);
  if v_base = '' then v_base := 'new-sop'; end if;
  v_id := v_base;
  while exists (select 1 from sops where id = v_id) loop
    v_id := v_base || '-' || v_n;
    v_n := v_n + 1;
  end loop;
  return v_id;
end;
$$;

create or replace function _event_stamp_date(p_ts bigint)
returns text
language sql
immutable
as $$
  select to_char(to_timestamp(p_ts / 1000.0) at time zone 'utc', 'DD Mon YYYY');
$$;

create or replace function _event_stamp_month(p_ts bigint)
returns text
language sql
immutable
as $$
  select to_char(to_timestamp(p_ts / 1000.0) at time zone 'utc', 'Mon YYYY');
$$;

-- ============================== write RPCs ==============================

-- Confirms a department's login by verifying the passcode. The frontend
-- calls this once when someone picks their department and types the
-- passcode; on success it remembers {department_id, passcode} in
-- localStorage and passes both along on every later write call. There is
-- no session/token: every RPC below re-verifies the passcode itself.
create or replace function login_department(p_department_id text, p_passcode text)
returns table (id text, name text, code text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform _check_passcode(p_department_id, p_passcode);
  return query select d.id, d.name, d.code from departments d where d.id = p_department_id;
end;
$$;

create or replace function approve_sop(
  p_sop_id text, p_department_id text, p_passcode text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_dept departments%rowtype;
  v_ts bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  perform _check_passcode(p_department_id, p_passcode);
  select * into v_dept from departments where id = p_department_id;

  if not exists (select 1 from sops where id = p_sop_id and department = p_department_id) then
    raise exception 'only the owning department can approve this SOP';
  end if;

  update sops set
    status = 'current',
    last_reviewed = _event_stamp_month(v_ts),
    signed_off_by = signed_off_by || jsonb_build_array(jsonb_build_object(
      'name', v_dept.name || ' Team', 'initials', v_dept.code, 'date', _event_stamp_date(v_ts)
    )),
    updated_at = now()
  where id = p_sop_id;

  insert into sop_events (sop_id, kind, department_id, department_name, department_code, ts, full_date, month_year)
  values (p_sop_id, 'approved', p_department_id, v_dept.name, v_dept.code, v_ts, _event_stamp_date(v_ts), _event_stamp_month(v_ts));
end;
$$;

create or replace function disapprove_sop(
  p_sop_id text, p_department_id text, p_passcode text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform _check_passcode(p_department_id, p_passcode);
  if not exists (select 1 from sops where id = p_sop_id and department = p_department_id) then
    raise exception 'only the owning department can remove this SOP';
  end if;
  delete from sops where id = p_sop_id;
end;
$$;

-- p_fields is a JSON object of the same shape as the sops row (title,
-- subtitle, never_do_this, before_you_start, tools_systems, steps,
-- success_criteria, escalation, forms) -- only keys present are applied.
create or replace function edit_sop(
  p_sop_id text, p_department_id text, p_passcode text, p_fields jsonb
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_dept departments%rowtype;
  v_ts bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  perform _check_passcode(p_department_id, p_passcode);
  select * into v_dept from departments where id = p_department_id;

  if not exists (select 1 from sops where id = p_sop_id and department = p_department_id) then
    raise exception 'only the owning department can edit this SOP';
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

  insert into sop_events (sop_id, kind, department_id, department_name, department_code, ts, full_date, month_year, fields)
  values (p_sop_id, 'edited', p_department_id, v_dept.name, v_dept.code, v_ts, _event_stamp_date(v_ts), _event_stamp_month(v_ts), p_fields);
end;
$$;

-- p_sop is a JSON object: {title, subtitle, never_do_this, before_you_start,
-- tools_systems, steps, success_criteria, escalation, forms, owner_name}.
-- Returns the new SOP's generated id.
create or replace function add_sop(
  p_department_id text, p_passcode text, p_sop jsonb
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id text;
  v_title text := p_sop->>'title';
  v_owner_name text := coalesce(p_sop->>'owner_name', '');
  v_initials text;
begin
  perform _check_passcode(p_department_id, p_passcode);
  if v_title is null or trim(v_title) = '' then
    raise exception 'title can''t be empty';
  end if;
  if coalesce(jsonb_array_length(p_sop->'steps'), 0) = 0 then
    raise exception 'add at least one step before saving';
  end if;
  if trim(v_owner_name) = '' then
    raise exception 'enter your name before saving';
  end if;

  select upper(left(string_agg(left(w, 1), '' order by ord), 3))
    into v_initials
    from unnest(regexp_split_to_array(trim(v_owner_name), '\s+')) with ordinality as t(w, ord)
    where w <> '';
  if v_initials is null or v_initials = '' then v_initials := 'NA'; end if;

  v_id := _unique_sop_id(v_title);

  insert into sops (
    id, title, department, status, owner_name, owner_initials, version,
    subtitle, before_you_start, tools_systems, steps, success_criteria,
    escalation, forms, never_do_this
  ) values (
    v_id, v_title, p_department_id, 'draft', v_owner_name, v_initials, 'v1 (draft)',
    coalesce(p_sop->>'subtitle', ''),
    coalesce(p_sop->'before_you_start', '[]'::jsonb),
    coalesce(p_sop->'tools_systems', '[]'::jsonb),
    p_sop->'steps',
    coalesce(p_sop->'success_criteria', '[]'::jsonb),
    coalesce(p_sop->'escalation', '[]'::jsonb),
    coalesce(p_sop->'forms', '[]'::jsonb),
    nullif(p_sop->>'never_do_this', '')
  );

  return v_id;
end;
$$;

create or replace function add_suggestion(
  p_sop_id text, p_department_id text, p_passcode text, p_text text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_dept departments%rowtype;
  v_id text := 'sg-' || (extract(epoch from now()) * 1000)::bigint || '-' || substr(encode(gen_random_bytes(4), 'hex'), 1, 5);
begin
  perform _check_passcode(p_department_id, p_passcode);
  if p_text is null or trim(p_text) = '' then
    raise exception 'write a suggestion before sending';
  end if;
  select * into v_dept from departments where id = p_department_id;

  insert into suggestions (id, sop_id, department_id, department_name, text, ts)
  values (v_id, p_sop_id, p_department_id, v_dept.name, p_text, (extract(epoch from now()) * 1000)::bigint);

  return v_id;
end;
$$;

-- Approving a suggestion is gated by the TARGET SOP's owning department,
-- not the suggestion's own origin department.
create or replace function approve_suggestion(
  p_suggestion_id text, p_department_id text, p_passcode text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_dept departments%rowtype;
  v_sop_id text;
begin
  perform _check_passcode(p_department_id, p_passcode);
  select * into v_dept from departments where id = p_department_id;

  select sop_id into v_sop_id from suggestions where id = p_suggestion_id;
  if v_sop_id is null then
    raise exception 'suggestion not found';
  end if;
  if not exists (select 1 from sops where id = v_sop_id and department = p_department_id) then
    raise exception 'only the SOP''s owning department can approve this suggestion';
  end if;

  update suggestions set
    status = 'approved',
    approved_by_dept_id = p_department_id,
    approved_by_dept_name = v_dept.name,
    approved_date = _event_stamp_date((extract(epoch from now()) * 1000)::bigint)
  where id = p_suggestion_id;
end;
$$;

-- Anyone can call the write RPCs (each one re-checks the real passcode
-- internally); the underlying tables stay locked down to SELECT-only.
grant execute on function login_department(text, text) to anon, authenticated;
grant execute on function approve_sop(text, text, text) to anon, authenticated;
grant execute on function disapprove_sop(text, text, text) to anon, authenticated;
grant execute on function edit_sop(text, text, text, jsonb) to anon, authenticated;
grant execute on function add_sop(text, text, jsonb) to anon, authenticated;
grant execute on function add_suggestion(text, text, text, text) to anon, authenticated;
grant execute on function approve_suggestion(text, text, text) to anon, authenticated;

-- Table-level grants: RLS policies only restrict which ROWS a role sees --
-- the role still needs the underlying table privilege in the first place.
-- Only SELECT is granted here; every write path is one of the RPCs above.
--
-- departments gets a COLUMN-scoped grant (not the whole table): anon and
-- authenticated can never select passcode_hash, full stop, regardless of
-- what the frontend asks for. This is enforced by Postgres itself, not by
-- the frontend remembering to write ?select=id,name,code.
grant select (id, name, code) on departments to anon, authenticated;
grant select on sops to anon, authenticated;
grant select on sop_events to anon, authenticated;
grant select on suggestions to anon, authenticated;
