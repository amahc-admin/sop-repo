-- One-time patch: Supabase installs pgcrypto's functions (crypt,
-- gen_random_bytes) into an `extensions` schema, not `public`. These two
-- functions need `extensions` on their search_path to find them. Safe to
-- run any time -- CREATE OR REPLACE FUNCTION doesn't error if it already
-- exists, unlike CREATE TABLE.
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
