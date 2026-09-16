-- Lets a suggestion be deleted by an Admin, or by whoever submitted it.
--
-- "Whoever submitted it" is enforced by matching login_id + last_name
-- against what's stored on the suggestion -- the same soft-identity
-- model the rest of this app uses (last_name is attribution, typed at
-- login, never itself verified; the shared passcode is the only real
-- credential). This is a courtesy check, not a hard security boundary:
-- anyone who knows the Member passcode could type someone else's name.
-- That matches the trust level already assumed everywhere else here.

create or replace function delete_suggestion(
  p_suggestion_id text, p_login_id text, p_passcode text, p_last_name text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_owner_login_id text;
  v_owner_last_name text;
  v_can_admin boolean;
begin
  perform _check_login(p_login_id, p_passcode);

  select login_id, last_name into v_owner_login_id, v_owner_last_name
  from suggestions where id = p_suggestion_id;
  if v_owner_login_id is null then
    raise exception 'suggestion not found';
  end if;

  select can_manage_sops into v_can_admin from logins where id = p_login_id;

  if v_can_admin is not true
     and not (v_owner_login_id = p_login_id and v_owner_last_name = p_last_name) then
    raise exception 'only an Admin or the person who submitted this can delete it' using errcode = '28000';
  end if;

  delete from suggestions where id = p_suggestion_id;
end;
$$;

grant execute on function delete_suggestion(text, text, text, text) to anon, authenticated;
