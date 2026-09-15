-- A Company Directory page inside the Handbook: a table of people/roles/
-- contact info, editable through the exact same Admin/Member flow as
-- SOPs. Mirrors the SOPs model on purpose:
--   - any valid login can add a person -- it starts as a 'draft' pending
--     an Admin's approval, same as add_sop.
--   - Admin edits an existing person directly (edit_directory_entry).
--   - Member's edit to an existing person is a pending proposal an Admin
--     must approve or reject (propose/approve/reject_directory_edit),
--     same as propose_sop_edit.
--   - only an Admin can approve or disapprove (remove) a person.

create table directory_entries (
  id text primary key,
  name text not null,
  role text not null,
  department text not null references departments(id),
  email text,
  phone text,
  notes text,
  status text not null default 'draft' check (status in ('current', 'draft')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table directory_entries enable row level security;

create policy "directory_entries are publicly readable"
  on directory_entries for select
  using (true);

create table directory_edit_proposals (
  id text primary key,
  entry_id text not null references directory_entries(id) on delete cascade,
  login_id text not null references logins(id),
  last_name text not null,
  fields jsonb not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  decided_by_last_name text,
  decided_date text,
  ts bigint not null,
  created_at timestamptz not null default now()
);

alter table directory_edit_proposals enable row level security;

create policy "directory_edit_proposals are publicly readable"
  on directory_edit_proposals for select
  using (true);

-- ============================== write RPCs ==============================

-- p_entry is {name, role, department, email, phone, notes}. Returns the
-- new entry's generated id. Always starts as 'draft', same as add_sop --
-- an Admin still has to approve it, even if an Admin was the one adding it.
create or replace function add_directory_entry(
  p_login_id text, p_passcode text, p_last_name text, p_entry jsonb
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id text;
  v_name text := p_entry->>'name';
begin
  perform _check_login(p_login_id, p_passcode);
  if v_name is null or trim(v_name) = '' then
    raise exception 'name can''t be empty';
  end if;
  if p_entry->>'role' is null or trim(p_entry->>'role') = '' then
    raise exception 'role can''t be empty';
  end if;
  if not exists (select 1 from departments where id = p_entry->>'department') then
    raise exception 'unknown department';
  end if;

  v_id := 'p-' || (extract(epoch from now()) * 1000)::bigint || '-' || substr(encode(gen_random_bytes(4), 'hex'), 1, 5);

  insert into directory_entries (id, name, role, department, email, phone, notes, status)
  values (
    v_id, v_name, p_entry->>'role', p_entry->>'department',
    nullif(p_entry->>'email', ''), nullif(p_entry->>'phone', ''), nullif(p_entry->>'notes', ''),
    'draft'
  );

  perform _notify_slack(':bust_in_silhouette: *' || p_last_name || '* added *' || v_name || '* to the directory');

  return v_id;
end;
$$;

create or replace function approve_directory_entry(
  p_entry_id text, p_login_id text, p_passcode text, p_last_name text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name text;
begin
  perform _check_login(p_login_id, p_passcode);
  perform _require_admin(p_login_id);

  select name into v_name from directory_entries where id = p_entry_id;
  if v_name is null then
    raise exception 'directory entry not found';
  end if;

  update directory_entries set status = 'current', updated_at = now() where id = p_entry_id;

  perform _notify_slack(':white_check_mark: *' || p_last_name || '* (Admin) approved *' || v_name || '* in the directory');
end;
$$;

create or replace function disapprove_directory_entry(
  p_entry_id text, p_login_id text, p_passcode text, p_last_name text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name text;
begin
  perform _check_login(p_login_id, p_passcode);
  perform _require_admin(p_login_id);

  select name into v_name from directory_entries where id = p_entry_id;
  if v_name is null then
    raise exception 'directory entry not found';
  end if;

  delete from directory_entries where id = p_entry_id;

  perform _notify_slack(':wastebasket: *' || p_last_name || '* (Admin) removed *' || v_name || '* from the directory');
end;
$$;

-- Admin-only, applies immediately. p_fields is a JSON object of the same
-- shape as directory_entries -- only keys present are applied.
create or replace function edit_directory_entry(
  p_entry_id text, p_login_id text, p_passcode text, p_last_name text, p_fields jsonb
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name text;
begin
  perform _check_login(p_login_id, p_passcode);
  perform _require_admin(p_login_id);

  select name into v_name from directory_entries where id = p_entry_id;
  if v_name is null then
    raise exception 'directory entry not found';
  end if;

  update directory_entries set
    name = coalesce(p_fields->>'name', name),
    role = coalesce(p_fields->>'role', role),
    department = coalesce(p_fields->>'department', department),
    email = case when p_fields ? 'email' then nullif(p_fields->>'email', '') else email end,
    phone = case when p_fields ? 'phone' then nullif(p_fields->>'phone', '') else phone end,
    notes = case when p_fields ? 'notes' then nullif(p_fields->>'notes', '') else notes end,
    updated_at = now()
  where id = p_entry_id;

  perform _notify_slack(':memo: *' || p_last_name || '* (Admin) edited *' || coalesce(p_fields->>'name', v_name) || '* in the directory');
end;
$$;

create or replace function propose_directory_edit(
  p_entry_id text, p_login_id text, p_passcode text, p_last_name text, p_fields jsonb
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_login logins%rowtype;
  v_name text;
  v_id text := 'dp-' || (extract(epoch from now()) * 1000)::bigint || '-' || substr(encode(gen_random_bytes(4), 'hex'), 1, 5);
begin
  perform _check_login(p_login_id, p_passcode);
  if trim(coalesce(p_last_name, '')) = '' then
    raise exception 'enter your last name before saving';
  end if;
  select * into v_login from logins where id = p_login_id;
  select name into v_name from directory_entries where id = p_entry_id;
  if v_name is null then
    raise exception 'directory entry not found';
  end if;

  insert into directory_edit_proposals (id, entry_id, login_id, last_name, fields, ts)
  values (v_id, p_entry_id, p_login_id, p_last_name, p_fields, (extract(epoch from now()) * 1000)::bigint);

  perform _notify_slack(':pencil2: *' || p_last_name || '* (' || v_login.name || ') proposed changes to *' || coalesce(p_fields->>'name', v_name) || '* in the directory -- awaiting Admin approval');

  return v_id;
end;
$$;

create or replace function approve_directory_edit(
  p_proposal_id text, p_login_id text, p_passcode text, p_last_name text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_proposal directory_edit_proposals%rowtype;
  v_name text;
begin
  perform _check_login(p_login_id, p_passcode);
  perform _require_admin(p_login_id);

  select * into v_proposal from directory_edit_proposals where id = p_proposal_id and status = 'pending';
  if not found then
    raise exception 'proposal not found or already decided';
  end if;

  select name into v_name from directory_entries where id = v_proposal.entry_id;

  update directory_entries set
    name = coalesce(v_proposal.fields->>'name', name),
    role = coalesce(v_proposal.fields->>'role', role),
    department = coalesce(v_proposal.fields->>'department', department),
    email = case when v_proposal.fields ? 'email' then nullif(v_proposal.fields->>'email', '') else email end,
    phone = case when v_proposal.fields ? 'phone' then nullif(v_proposal.fields->>'phone', '') else phone end,
    notes = case when v_proposal.fields ? 'notes' then nullif(v_proposal.fields->>'notes', '') else notes end,
    updated_at = now()
  where id = v_proposal.entry_id;

  update directory_edit_proposals set
    status = 'approved',
    decided_by_last_name = p_last_name,
    decided_date = _event_stamp_date((extract(epoch from now()) * 1000)::bigint)
  where id = p_proposal_id;

  perform _notify_slack(':white_check_mark: *' || p_last_name || '* (Admin) approved *' || v_proposal.last_name || '*''s changes to *' || coalesce(v_proposal.fields->>'name', v_name) || '* in the directory');
end;
$$;

create or replace function reject_directory_edit(
  p_proposal_id text, p_login_id text, p_passcode text, p_last_name text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_proposal directory_edit_proposals%rowtype;
  v_name text;
begin
  perform _check_login(p_login_id, p_passcode);
  perform _require_admin(p_login_id);

  select * into v_proposal from directory_edit_proposals where id = p_proposal_id and status = 'pending';
  if not found then
    raise exception 'proposal not found or already decided';
  end if;

  select name into v_name from directory_entries where id = v_proposal.entry_id;

  update directory_edit_proposals set
    status = 'rejected',
    decided_by_last_name = p_last_name,
    decided_date = _event_stamp_date((extract(epoch from now()) * 1000)::bigint)
  where id = p_proposal_id;

  perform _notify_slack(':x: *' || p_last_name || '* (Admin) rejected *' || v_proposal.last_name || '*''s proposed changes to *' || coalesce(v_name, '') || '* in the directory');
end;
$$;

-- ============================== grants ==============================

grant execute on function add_directory_entry(text, text, text, jsonb) to anon, authenticated;
grant execute on function approve_directory_entry(text, text, text, text) to anon, authenticated;
grant execute on function disapprove_directory_entry(text, text, text, text) to anon, authenticated;
grant execute on function edit_directory_entry(text, text, text, text, jsonb) to anon, authenticated;
grant execute on function propose_directory_edit(text, text, text, text, jsonb) to anon, authenticated;
grant execute on function approve_directory_edit(text, text, text, text) to anon, authenticated;
grant execute on function reject_directory_edit(text, text, text, text) to anon, authenticated;

grant select on directory_entries to anon, authenticated;
grant select on directory_edit_proposals to anon, authenticated;
