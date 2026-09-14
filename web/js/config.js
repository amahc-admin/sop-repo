// Fill these in after creating your Supabase project (see SETUP.md).
// The anon key is meant to be public -- it's safe to commit and ship to the
// browser. All real access control happens in Postgres (RLS + the
// passcode-checked RPC functions in supabase/migrations/0001_init.sql), not
// by keeping this key secret.
window.SUPABASE_CONFIG = {
  url: "https://YOUR-PROJECT-REF.supabase.co",
  anonKey: "YOUR-ANON-KEY",
};
