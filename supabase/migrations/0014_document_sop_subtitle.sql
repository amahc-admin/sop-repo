-- The description typed on the "Upload a document" form only ever went
-- into the placeholder step's body -- shown on the SOP page itself, but
-- never on the Library card, which reads sop.subtitle. Every new
-- document SOP got the same generic "Hosted as an uploaded document."
-- subtitle regardless of what was actually typed. Now the description
-- becomes the subtitle too (falling back to that generic line only when
-- left blank), so it actually shows up where people browse.

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
  v_description text := coalesce(nullif(trim(p_notes), ''), 'See the attached document.');
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
    coalesce(nullif(trim(p_notes), ''), 'Hosted as an uploaded document.'),
    jsonb_build_array(jsonb_build_object(
      'title', 'Uploaded document',
      'body', v_description,
      'type', 'info',
      'placeholder', true
    )),
    p_file_url, nullif(p_file_name, ''), coalesce(p_forms, '[]'::jsonb)
  );

  perform _notify_slack(':page_facing_up: *' || p_last_name || '* uploaded a document for *' || p_title || '* -- pending review');

  return v_id;
end;
$$;

-- One-off backfill for document SOPs already created with the old,
-- always-generic subtitle -- pulls their real description back out of
-- the placeholder step's body, same value the SOP page already shows.
update sops
set subtitle = steps->0->>'body'
where source_document_url is not null
  and subtitle = 'Hosted as an uploaded document.'
  and jsonb_typeof(steps) = 'array'
  and jsonb_array_length(steps) > 0
  and coalesce((steps->0->>'placeholder')::boolean, false)
  and coalesce(nullif(trim(steps->0->>'body'), ''), '') <> '';
