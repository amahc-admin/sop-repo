-- Adds a third shared login, "VNC" (Accounts Admin), for the VNC Team --
-- same admin-class rights as the Admin login (can approve/edit/disapprove,
-- not just view/suggest/add like Member), but scoped in the UI to the
-- Accounts department only.
--
-- dept_scope is nullable: null (the existing admin/member rows) means no
-- restriction. Non-null means the frontend only shows Approve/Edit/
-- Disapprove for SOPs and directory entries tagged that department --
-- everything else renders like a Member would see it (Propose edit,
-- disabled Approve/Disapprove).
--
-- Security note: this is the same soft-trust model as everywhere else in
-- this app -- the RPCs below only check can_manage_sops (via
-- _require_admin), not dept_scope, so this is a UI-level convenience, not
-- a hard boundary a determined person can't route around (e.g. by simply
-- choosing the Admin tile instead of VNC at login). The VNC passcode is
-- deliberately set to whatever the Admin passcode currently is (copied by
-- reference below, never written here in the clear) -- meaning anyone
-- who knows the VNC passcode also knows the Admin passcode and could log
-- in as unrestricted Admin directly. If that's not acceptable, give VNC
-- its own distinct passcode instead (update logins set passcode_hash =
-- crypt('...', gen_salt('bf')) where id = 'vnc').

alter table logins add column if not exists dept_scope text references departments(id);

insert into logins (id, name, code, passcode_hash, can_manage_sops, dept_scope)
select 'vnc', 'Accounts Admin', 'VNC', l.passcode_hash, true, 'accounts'
from logins l where l.id = 'admin'
on conflict (id) do update set
  name = excluded.name,
  code = excluded.code,
  passcode_hash = excluded.passcode_hash,
  can_manage_sops = excluded.can_manage_sops,
  dept_scope = excluded.dept_scope;

create or replace function login(p_login_id text, p_passcode text)
returns table (id text, name text, code text, can_manage_sops boolean, dept_scope text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform _check_login(p_login_id, p_passcode);
  return query select l.id, l.name, l.code, l.can_manage_sops, l.dept_scope from logins l where l.id = p_login_id;
end;
$$;
