-- Some contributors just want to host a document as the SOP permanently,
-- rather than have it converted into step-by-step content -- see
-- add_sop_document (0009_sop_document_upload.sql). That RPC inserted a
-- single placeholder step so the "at least one step" rule was satisfied;
-- this marks that step so the frontend can tell "just a document, no
-- real steps yet" apart from "someone wrote real content", and render
-- the document itself instead of a fake Step 1.

create or replace function add_sop_document(
  p_login_id text, p_passcode text, p_last_name text, p_department_tag text,
  p_title text, p_file_url text, p_file_name text, p_notes text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id text;
begin
  perform _check_login(p_login_id, p_passcode);
  if p_title is null or trim(p_title) = '' then
    raise exception 'title can''t be empty';
  end if;
  if trim(coalesce(p_last_name, '')) = '' then
    raise exception 'enter your last name before saving';
  end if;
  if not exists (select 1 from departments where id = p_department_tag) then
    raise exception 'unknown department';
  end if;
  if p_file_url is null or trim(p_file_url) = '' then
    raise exception 'attach a document before submitting';
  end if;

  v_id := _unique_sop_id(p_title);

  insert into sops (
    id, title, department, status, owner_name, owner_initials, version,
    subtitle, steps, source_document_url, source_document_name
  ) values (
    v_id, p_title, p_department_tag, 'draft', p_last_name, _initials(p_last_name), 'v1 (draft)',
    'Hosted as an uploaded document.',
    jsonb_build_array(jsonb_build_object(
      'title', 'Uploaded document',
      'body', coalesce(nullif(trim(p_notes), ''), 'See the attached document.'),
      'type', 'info',
      'placeholder', true
    )),
    p_file_url, nullif(p_file_name, '')
  );

  perform _notify_slack(':page_facing_up: *' || p_last_name || '* uploaded a document for *' || p_title || '* -- pending review');

  return v_id;
end;
$$;

grant execute on function add_sop_document(text, text, text, text, text, text, text, text) to anon, authenticated;
