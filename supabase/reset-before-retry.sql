-- One-time cleanup: run this ONLY if a previous migration attempt partially
-- applied and left objects behind (e.g. "relation already exists" errors).
-- Safe on a fresh project with no real data yet -- this drops everything
-- 0001_init.sql creates, so you can then re-run that file from a clean slate.
drop table if exists suggestions cascade;
drop table if exists sop_events cascade;
drop table if exists sops cascade;
drop table if exists departments cascade;
drop function if exists login_department(text, text);
drop function if exists approve_sop(text, text, text);
drop function if exists disapprove_sop(text, text, text);
drop function if exists edit_sop(text, text, text, jsonb);
drop function if exists add_sop(text, text, jsonb);
drop function if exists add_suggestion(text, text, text, text);
drop function if exists approve_suggestion(text, text, text);
drop function if exists _check_passcode(text, text);
drop function if exists _unique_sop_id(text);
drop function if exists _event_stamp_date(bigint);
drop function if exists _event_stamp_month(bigint);
