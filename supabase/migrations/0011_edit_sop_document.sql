-- Lets the Edit SOP form (both the Admin-direct path and the Member
-- proposal path) replace a document-hosted SOP's attached file and edit
-- its description, alongside the usual fields. Same jsonb-extension
-- pattern as never_do_this before it -- no signature changes.

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
    source_document_url = case when p_fields ? 'source_document_url' then p_fields->>'source_document_url' else source_document_url end,
    source_document_name = case when p_fields ? 'source_document_name' then p_fields->>'source_document_name' else source_document_name end,
    status = 'review-due',
    updated_at = now()
  where id = p_sop_id;

  insert into sop_events (sop_id, kind, login_id, actor_last_name, ts, full_date, month_year, fields)
  values (p_sop_id, 'edited', p_login_id, p_last_name, v_ts, _event_stamp_date(v_ts), _event_stamp_month(v_ts), p_fields);

  perform _notify_slack(':memo: *' || p_last_name || '* (Admin) edited *' || coalesce(p_fields->>'title', v_title) || '*');
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
    source_document_url = case when v_proposal.fields ? 'source_document_url' then v_proposal.fields->>'source_document_url' else source_document_url end,
    source_document_name = case when v_proposal.fields ? 'source_document_name' then v_proposal.fields->>'source_document_name' else source_document_name end,
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
