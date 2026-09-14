-- Slack notifications for: new suggestion submitted, SOP approved, SOP
-- added, SOP edited, SOP disapproved (deleted).
--
-- This calls a Slack Incoming Webhook directly from Postgres via pg_net --
-- no separate server. The webhook URL is stored in Supabase Vault, never
-- in a column anon/authenticated can read. If the secret isn't set yet,
-- _notify_slack silently no-ops rather than failing the write it's
-- attached to -- a notification problem should never block someone from
-- actually approving/editing/adding a SOP.
--
-- One-time setup (see SETUP.md): create a Slack Incoming Webhook, then run
--   select vault.create_secret('https://hooks.slack.com/services/...', 'slack_webhook_url', 'Cave Handbook notifications');
-- in the SQL Editor with your real webhook URL.

create extension if not exists pg_net;

create or replace function _notify_slack(p_text text)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault, net
as $$
declare
  v_url text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'slack_webhook_url';
  if v_url is null then
    return;
  end if;
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('text', p_text)
  );
exception when others then
  -- never let a notification failure break the actual SOP/suggestion write
  null;
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
  if not exists (select 1 from sops where id = p_sop_id and department = p_department_id) then
    raise exception 'only the owning department can remove this SOP';
  end if;

  select title into v_title from sops where id = p_sop_id;
  select name into v_dept_name from departments where id = p_department_id;

  delete from sops where id = p_sop_id;

  perform _notify_slack(':wastebasket: *' || v_dept_name || '* removed *' || v_title || '*');
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
  v_title text;
  v_ts bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  perform _check_passcode(p_department_id, p_passcode);
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

  perform _notify_slack(':new: *' || v_owner_name || '* (' || p_department_id || ') added a new SOP: *' || v_title || '*');

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
  v_sop_title text;
  v_id text := 'sg-' || (extract(epoch from now()) * 1000)::bigint || '-' || substr(encode(gen_random_bytes(4), 'hex'), 1, 5);
begin
  perform _check_passcode(p_department_id, p_passcode);
  if p_text is null or trim(p_text) = '' then
    raise exception 'write a suggestion before sending';
  end if;
  select * into v_dept from departments where id = p_department_id;
  select title into v_sop_title from sops where id = p_sop_id;

  insert into suggestions (id, sop_id, department_id, department_name, text, ts)
  values (v_id, p_sop_id, p_department_id, v_dept.name, p_text, (extract(epoch from now()) * 1000)::bigint);

  perform _notify_slack(':bulb: *' || v_dept.name || '* suggested on *' || v_sop_title || '*:' || chr(10) || '> ' || p_text);

  return v_id;
end;
$$;
