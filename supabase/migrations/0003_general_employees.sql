-- General Employees: a shared login for everyone who isn't a department
-- lead. They can log in and submit suggestions/comments on any SOP, same
-- as a real department -- but they cannot approve, edit, add, or remove a
-- SOP. Enforced here in Postgres (not just hidden in the UI), via a new
-- can_manage_sops flag and an explicit check in every SOP-mutating RPC.

alter table departments add column if not exists can_manage_sops boolean not null default true;

insert into departments (id, name, code, passcode_hash, can_manage_sops)
values ('general', 'General Employees', 'GEN', crypt('changeme-general', gen_salt('bf')), false)
on conflict (id) do nothing;

create or replace function _require_manage_sops(p_department_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_can boolean;
begin
  select can_manage_sops into v_can from departments where id = p_department_id;
  if v_can is not true then
    raise exception 'only department leads can do this' using errcode = '28000';
  end if;
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
  v_title text;
  v_ts bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  perform _check_passcode(p_department_id, p_passcode);
  perform _require_manage_sops(p_department_id);
  select * into v_dept from departments where id = p_department_id;

  if not exists (select 1 from sops where id = p_sop_id and department = p_department_id) then
    raise exception 'only the owning department can approve this SOP';
  end if;

  select title into v_title from sops where id = p_sop_id;

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

  perform _notify_slack(':white_check_mark: *' || v_dept.name || '* approved *' || v_title || '*');
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
declare
  v_title text;
  v_dept_name text;
begin
  perform _check_passcode(p_department_id, p_passcode);
  perform _require_manage_sops(p_department_id);
  if not exists (select 1 from sops where id = p_sop_id and department = p_department_id) then
    raise exception 'only the owning department can remove this SOP';
  end if;

  select title into v_title from sops where id = p_sop_id;
  select name into v_dept_name from departments where id = p_department_id;

  delete from sops where id = p_sop_id;

  perform _notify_slack(':wastebasket: *' || v_dept_name || '* removed *' || v_title || '*');
end;
$$;

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
  v_title text;
  v_ts bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  perform _check_passcode(p_department_id, p_passcode);
  perform _require_manage_sops(p_department_id);
  select * into v_dept from departments where id = p_department_id;

  if not exists (select 1 from sops where id = p_sop_id and department = p_department_id) then
    raise exception 'only the owning department can edit this SOP';
  end if;

  select title into v_title from sops where id = p_sop_id;

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

  perform _notify_slack(':memo: *' || v_dept.name || '* edited *' || coalesce(p_fields->>'title', v_title) || '*');
end;
$$;

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
  perform _require_manage_sops(p_department_id);
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

  perform _notify_slack(':new: *' || v_owner_name || '* (' || p_department_id || ') added a new SOP: *' || v_title || '*');

  return v_id;
end;
$$;

-- Approving a suggestion is already gated by "does the target SOP belong
-- to p_department_id", which a general-employee login always fails since
-- General Employees owns no SOPs -- this adds the same explicit check
-- purely for a clearer error message.
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
  perform _require_manage_sops(p_department_id);
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
