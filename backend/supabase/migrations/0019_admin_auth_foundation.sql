-- Pro-X Network — Secure admin authentication/authorization foundation.
--
-- Table: public.admin_users.
-- Function: public.is_current_user_admin().
--
-- Context: admin.html currently gates itself with a hardcoded,
-- client-side passcode ("proxadmin") — explicitly documented in that
-- file as a demo-only convenience, not real security. This migration
-- is the database-side foundation that replaces it: a real
-- authorization table plus a single, minimal, server-enforced check
-- an authenticated caller can run against themselves. It does NOT
-- touch mining_config, mining_state, mining_inventory, public.users,
-- adjust_pxn_balance, purchase_miner, set_miner_applied, or any
-- existing function/table, does NOT alter PLAYER_ID, does NOT touch
-- auth-telegram or the Telegram auth flow in any way, and does NOT
-- create a custom JWT/JWKS/private-JWK system or reference
-- SUPABASE_JWT_SECRET / PXN_JWT_SECRET.
--
-- Identity: admin_users.user_id references auth.users(id) directly
-- (not public.users(id)). public.users rows only ever exist for
-- Telegram-authenticated players (created by auth-telegram — see
-- 0002_users.sql / auth-telegram/index.ts, which provisions a real
-- auth.users row with the SAME id as the public.users row). Admin
-- accounts are a separate concern: an admin may or may not also be a
-- player, so anchoring to auth.users(id) — the one identity space
-- every authenticated Supabase session shares, regardless of how
-- that session was established — is the more general, correct
-- foreign key, and auth.uid() (used throughout this project's RLS
-- policies, e.g. users_select_own in 0002_users.sql) is always an
-- auth.users(id) value.
--
-- Authorization model (every requirement below is enforced by
-- Postgres/RLS/grants, not by application code):
--   - RLS is enabled on admin_users with ZERO policies for `anon` or
--     `authenticated`. Under Postgres RLS, a table with RLS enabled
--     and no matching policy for a role denies that role EVERY
--     operation (select/insert/update/delete) by default. So no
--     authenticated player — admin or not — can read, insert,
--     update, or delete admin_users rows directly, no matter what
--     client-side code claims. Only service_role (which bypasses RLS
--     entirely, same as every other privileged table in this schema)
--     can write to it — e.g. from the Supabase SQL editor/dashboard,
--     which is the intended way an already-privileged operator grants
--     admin access to a new auth.users id. This alone satisfies
--     "normal players can't make themselves admin" and "only an
--     already-authorized admin/service-role process can grant admin
--     access" without needing any INSERT policy or self-service RPC.
--   - public.is_current_user_admin() is the ONLY way an ordinary
--     authenticated session can learn admin status. It is SECURITY
--     DEFINER (so it can read admin_users despite the caller having
--     no RLS access to that table itself) but only ever answers the
--     single question "is auth.uid() present in admin_users?" as a
--     boolean — it never returns row contents, never accepts a
--     caller-supplied user id (always uses auth.uid() internally, so
--     a caller can only ever check themselves), and performs no
--     writes. Granted to `authenticated` only (not anon — a session
--     is required to even ask).

create table public.admin_users (
  user_id     uuid        primary key references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);

comment on table public.admin_users is
  'Authorization allowlist: a row here means auth.users.id is an admin. Written only by service_role (no RLS policy grants anon/authenticated any access — see is_current_user_admin() for the one safe read path). Never insert/update/delete this table from client code.';

alter table public.admin_users enable row level security;

-- Deliberately no policies here. RLS + zero policies for
-- anon/authenticated = default-deny for every operation on this
-- table for those roles. service_role bypasses RLS as usual.

create or replace function public.is_current_user_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.admin_users as au
     where au.user_id = auth.uid()
  );
$$;

comment on function public.is_current_user_admin() is
  'Returns true iff the CURRENTLY AUTHENTICATED caller (auth.uid()) has a row in admin_users. Always checks the caller''s own id only — never accepts a user id parameter. SECURITY DEFINER so it can read admin_users despite callers having no direct RLS access to that table. Returns false (never an error) for anon/no-session callers, since auth.uid() is null then and no admin_users row has a null user_id.';

-- Postgres grants EXECUTE on newly created functions to PUBLIC by
-- default — revoke that immediately, then grant only to authenticated
-- sessions (a caller needs a real session to have anything to check).
-- Same pattern as every other service-role/definer function in this
-- schema (0015/0016/0017/0018).
revoke all on function public.is_current_user_admin() from public;
revoke all on function public.is_current_user_admin() from anon;
grant execute on function public.is_current_user_admin() to authenticated;

-- No table schema (mining_config, mining_state, mining_inventory,
-- users, user_profiles) is altered by this migration. No existing
-- RLS policy, function, or grant is modified. No new Edge Function is
-- introduced — admin.html calls is_current_user_admin() directly via
-- the existing supabase-js RPC mechanism over the anon key + the
-- admin's own session, exactly like any other authenticated RPC call
-- in this project.
