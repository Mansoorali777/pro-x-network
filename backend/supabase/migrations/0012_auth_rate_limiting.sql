-- Pro-X Network — Authentication security.
--
-- Table: auth_attempts.
--
-- Backs rate limiting for the auth-telegram Edge Function. Every call
-- to that function (success or failure) writes one row here; the
-- function checks recent rows before doing any expensive work
-- (HMAC verification, DB upsert) so a flood of bogus requests from
-- one IP gets a fast 429 instead of hammering the database.
--
-- This is infrastructure for authentication itself, not a game
-- system — it belongs in this step, not a later one.

create table public.auth_attempts (
  id                uuid        primary key default gen_random_uuid(),

  -- Best-effort caller IP (from the platform's forwarded-for header).
  -- Nullable because it may be unavailable in local dev.
  ip_address        inet,

  -- Only populated once initData has been successfully verified —
  -- before that point we don't trust any claimed Telegram user id, so
  -- this column is never set from unverified client input.
  telegram_user_id  bigint,

  success           boolean     not null,

  -- Short machine-readable reason, e.g. 'ok', 'bad_signature',
  -- 'expired', 'malformed', 'banned', 'rate_limited'. Never a full
  -- error message or any part of initData/secrets.
  reason            text        not null,

  created_at        timestamptz not null default now()
);

comment on table public.auth_attempts is
  'Append-only log of every auth-telegram call, used to rate-limit by IP. Written and read only by the auth-telegram Edge Function via service_role — never client-readable.';

-- Rate-limit queries filter by ip_address/telegram_user_id and a
-- recent time window, so both need created_at alongside them.
create index auth_attempts_ip_created_at_idx on public.auth_attempts (ip_address, created_at);
create index auth_attempts_telegram_user_id_created_at_idx on public.auth_attempts (telegram_user_id, created_at);

alter table public.auth_attempts enable row level security;
-- Intentionally no policies: default-deny for anon/authenticated,
-- same pattern as admin_settings/audit_logs. Only service_role
-- (inside the auth-telegram function) ever touches this table.
revoke update, delete on public.auth_attempts from authenticated, anon;

-- Housekeeping: old rows have no ongoing value once they age out of
-- every rate-limit window. Not scheduled automatically here (no
-- pg_cron assumption) — call this periodically from an Edge Function
-- cron or ad hoc; safe to run anytime.
create or replace function public.prune_old_auth_attempts(older_than interval default interval '7 days')
returns void
language sql
as $$
  delete from public.auth_attempts where created_at < now() - older_than;
$$;
