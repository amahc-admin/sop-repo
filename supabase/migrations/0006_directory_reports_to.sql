-- Adds a "reports to" relationship between people in the Company
-- Directory, so it can render as a real org chart (branching tree) by
-- who reports to whom, instead of a flat list. No RPC signatures change
-- -- reports_to travels inside the existing p_entry/p_fields jsonb blobs
-- that add_directory_entry/edit_directory_entry/propose_directory_edit/
-- approve_directory_edit already take.

alter table directory_entries
  add column if not exists reports_to text references directory_entries(id) on delete set null;

alter table directory_entries
  drop constraint if exists directory_entries_reports_to_not_self;
alter table directory_entries
  add constraint directory_entries_reports_to_not_self check (reports_to is null or reports_to <> id);

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
  v_reports_to text := nullif(p_entry->>'reports_to', '');
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
  if v_reports_to is not null and not exists (select 1 from directory_entries where id = v_reports_to) then
    raise exception 'unknown manager';
  end if;

  v_id := 'p-' || (extract(epoch from now()) * 1000)::bigint || '-' || substr(encode(gen_random_bytes(4), 'hex'), 1, 5);

  insert into directory_entries (id, name, role, department, email, phone, notes, reports_to, status)
  values (
    v_id, v_name, p_entry->>'role', p_entry->>'department',
    nullif(p_entry->>'email', ''), nullif(p_entry->>'phone', ''), nullif(p_entry->>'notes', ''),
    v_reports_to, 'draft'
  );

  perform _notify_slack(':bust_in_silhouette: *' || p_last_name || '* added *' || v_name || '* to the directory');

  return v_id;
end;
$$;

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
  v_reports_to text;
begin
  perform _check_login(p_login_id, p_passcode);
  perform _require_admin(p_login_id);

  select name into v_name from directory_entries where id = p_entry_id;
  if v_name is null then
    raise exception 'directory entry not found';
  end if;

  if p_fields ? 'reports_to' then
    v_reports_to := nullif(p_fields->>'reports_to', '');
    if v_reports_to = p_entry_id then
      raise exception 'a person can''t report to themselves';
    end if;
    if v_reports_to is not null and not exists (select 1 from directory_entries where id = v_reports_to) then
      raise exception 'unknown manager';
    end if;
  end if;

  update directory_entries set
    name = coalesce(p_fields->>'name', name),
    role = coalesce(p_fields->>'role', role),
    department = coalesce(p_fields->>'department', department),
    email = case when p_fields ? 'email' then nullif(p_fields->>'email', '') else email end,
    phone = case when p_fields ? 'phone' then nullif(p_fields->>'phone', '') else phone end,
    notes = case when p_fields ? 'notes' then nullif(p_fields->>'notes', '') else notes end,
    reports_to = case when p_fields ? 'reports_to' then v_reports_to else reports_to end,
    updated_at = now()
  where id = p_entry_id;

  perform _notify_slack(':memo: *' || p_last_name || '* (Admin) edited *' || coalesce(p_fields->>'name', v_name) || '* in the directory');
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
  v_reports_to text;
begin
  perform _check_login(p_login_id, p_passcode);
  perform _require_admin(p_login_id);

  select * into v_proposal from directory_edit_proposals where id = p_proposal_id and status = 'pending';
  if not found then
    raise exception 'proposal not found or already decided';
  end if;

  select name into v_name from directory_entries where id = v_proposal.entry_id;

  if v_proposal.fields ? 'reports_to' then
    v_reports_to := nullif(v_proposal.fields->>'reports_to', '');
    if v_reports_to = v_proposal.entry_id then
      raise exception 'a person can''t report to themselves';
    end if;
    if v_reports_to is not null and not exists (select 1 from directory_entries where id = v_reports_to) then
      raise exception 'unknown manager';
    end if;
  end if;

  update directory_entries set
    name = coalesce(v_proposal.fields->>'name', name),
    role = coalesce(v_proposal.fields->>'role', role),
    department = coalesce(v_proposal.fields->>'department', department),
    email = case when v_proposal.fields ? 'email' then nullif(v_proposal.fields->>'email', '') else email end,
    phone = case when v_proposal.fields ? 'phone' then nullif(v_proposal.fields->>'phone', '') else phone end,
    notes = case when v_proposal.fields ? 'notes' then nullif(v_proposal.fields->>'notes', '') else notes end,
    reports_to = case when v_proposal.fields ? 'reports_to' then v_reports_to else reports_to end,
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
