-- Lets someone skip the structured Add SOP form entirely and instead
-- attach a raw document (PDF, Word doc, a photo of a printed procedure,
-- etc). It lands as a normal 'draft' sops row -- the same pending-approval
-- queue every other new SOP already goes through -- with a single
-- placeholder step pointing at the file, so an Admin can open it with the
-- existing Edit SOP page and turn it into real step-by-step content
-- before approving it, exactly like any other draft.
--
-- Storage note: this bucket is public-read and open to anon uploads,
-- matching directory-photos (see 0007_directory_photos.sql) -- the shared
-- passcode gates the actual sops write (via add_sop_document below), not
-- the raw file upload itself.

alter table sops add column if not exists source_document_url text;
alter table sops add column if not exists source_document_name text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sop-documents', 'sop-documents', true, 20971520, array[
  'application/pdf',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'text/plain',
  'image/jpeg', 'image/png', 'image/webp', 'image/gif'
])
on conflict (id) do nothing;

drop policy if exists "sop documents are publicly readable" on storage.objects;
create policy "sop documents are publicly readable"
  on storage.objects for select
  using (bucket_id = 'sop-documents');

drop policy if exists "anyone can upload a sop document" on storage.objects;
create policy "anyone can upload a sop document"
  on storage.objects for insert
  with check (bucket_id = 'sop-documents');

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
    'Submitted as a document -- awaiting conversion into a full SOP.',
    jsonb_build_array(jsonb_build_object(
      'title', 'Uploaded document awaiting conversion',
      'body', coalesce(nullif(trim(p_notes), ''), 'See the attached document. An Admin will convert this into full step-by-step content.'),
      'type', 'info'
    )),
    p_file_url, nullif(p_file_name, '')
  );

  perform _notify_slack(':page_facing_up: *' || p_last_name || '* uploaded a document for *' || p_title || '* -- pending conversion to a full SOP');

  return v_id;
end;
$$;

grant execute on function add_sop_document(text, text, text, text, text, text, text, text) to anon, authenticated;
