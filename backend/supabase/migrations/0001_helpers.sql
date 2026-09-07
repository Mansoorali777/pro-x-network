-- Pro-X Network — shared helpers.
--
-- One trigger function, reused by every table below that has an
-- `updated_at` column, so we don't repeat the same `CREATE FUNCTION`
-- in every migration.
--
-- IMPORTANT AUTH ASSUMPTION (documented here once, applies to every
-- RLS policy in every later migration):
--
-- Pro-X Network users authenticate via Telegram, not Supabase Auth's
-- normal email/OAuth flows. The intended design is:
--
--   1. The Telegram Mini App sends its `initData` to a (future)
--      Edge Function, e.g. `POST /functions/v1/telegram-auth`.
--   2. That function verifies the Telegram HMAC signature server-side
--      (using TELEGRAM_BOT_TOKEN, which lives only in Supabase
--      secrets — never in this schema, never in the frontend).
--   3. On success, it upserts a row into `public.users` and mints a
--      Supabase-compatible JWT whose `sub` claim equals that user's
--      `users.id` (uuid), signed with the project's JWT secret.
--   4. The frontend stores that JWT and sends it as the `Authorization`
--      bearer token on every subsequent request.
--
-- Supabase/PostgREST reads the `sub` claim into `auth.uid()` for RLS
-- purposes regardless of whether a matching row exists in the
-- built-in `auth.users` table — this is Supabase's documented
-- "custom auth" pattern. That is why every policy below can safely
-- compare `auth.uid() = users.id` / `auth.uid() = <table>.user_id`.
--
-- No such Edge Function is created in this step (schema only, per
-- instructions) — this comment exists so the assumption is explicit
-- and reviewable.

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Generic BEFORE UPDATE trigger: stamps updated_at = now() on every row update. Attached per-table in later migrations.';
