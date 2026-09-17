-- Lets the "Upload a document" form attach supplementary links up
-- front (a Loom walkthrough, a related document, etc.) instead of
-- requiring a second trip through Edit SOP afterward. Reuses the same
-- `forms` column and shape every other SOP already has (an array of
-- plain strings or {name, href} objects) -- new parameter with a
-- default, so this is backwards compatible with any existing caller.

-- Adding a parameter changes the function's signature/identity in
-- Postgres -- create or replace alone would leave the old 8-arg version
-- behind as a separate overload (ambiguous for PostgREST to pick
-- between). Drop it explicitly so only the 9-arg version exists.
drop function if exists add_sop_document(text, text, text, text, text, text, text, text);

create or replace function add_sop_document(
  p_login_id text, p_passcode text, p_last_name text, p_department_tag text,
  p_title text, p_file_url text, p_file_name text, p_notes text,
  p_forms jsonb default '[]'::jsonb
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
    subtitle, steps, source_document_url, source_document_name, forms
  ) values (
    v_id, p_title, p_department_tag, 'draft', p_last_name, _initials(p_last_name), 'v1 (draft)',
    'Hosted as an uploaded document.',
    jsonb_build_array(jsonb_build_object(
      'title', 'Uploaded document',
      'body', coalesce(nullif(trim(p_notes), ''), 'See the attached document.'),
      'type', 'info',
      'placeholder', true
    )),
    p_file_url, nullif(p_file_name, ''), coalesce(p_forms, '[]'::jsonb)
  );

  perform _notify_slack(':page_facing_up: *' || p_last_name || '* uploaded a document for *' || p_title || '* -- pending review');

  return v_id;
end;
$$;

grant execute on function add_sop_document(text, text, text, text, text, text, text, text, jsonb) to anon, authenticated;
