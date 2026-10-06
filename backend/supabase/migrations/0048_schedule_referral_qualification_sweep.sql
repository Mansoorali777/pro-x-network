-- Pro-X Network — Friends Referral system: automatic qualification
-- sweep scheduling.
--
-- Context: per the FINAL LOCKED referral design (Design Revision v2,
-- §4 "QUALIFICATION SWEEP"), this migration adds ONLY the scheduling
-- layer for the already-deployed referral-qualification-sweep Edge
-- Function (https://zsjibrckzhaxagdqxdil.supabase.co/functions/v1/referral-qualification-sweep).
-- It does not create, alter, or drop any referral table/RPC, mining
-- table, reward table, leaderboard table, or frontend file — nothing
-- from 0043-0047 is touched, and auth-telegram/index.html/admin.html
-- are untouched. This migration's only job is: enable pg_cron/pg_net,
-- then schedule exactly one recurring job that POSTs to that Edge
-- Function every 5 minutes, authorized via a Supabase Vault secret
-- that is never written into this file or any other file in source
-- control.
--
-- ------------------------------------------------------------------
-- 1. Extensions (idempotent).
-- ------------------------------------------------------------------
-- pg_cron: provides cron.schedule()/cron.unschedule()/cron.job — the
--          in-database job scheduler that fires this job every 5
--          minutes.
-- pg_net:  provides net.http_post() — the only mechanism a scheduled
--          job running inside Postgres has for making an outbound
--          HTTPS call to an Edge Function. net.http_post() is
--          fire-and-forget/asynchronous: it queues the request and
--          returns immediately with a request_id, it does not block
--          the cron worker waiting for the Edge Function's response.
-- Both are standard Supabase-provided extensions; `create extension
-- if not exists` is a no-op if either is already enabled on this
-- project, so this migration is safe to apply regardless of prior
-- state.
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ------------------------------------------------------------------
-- 2. Vault secret this job authorizes with — REQUIRES ONE MANUAL,
--    ONE-TIME STEP OUTSIDE THIS MIGRATION. Never run as part of this
--    file, never committed to source control.
-- ------------------------------------------------------------------
-- referral-qualification-sweep requires its caller to present the
-- project's service-role key as a bearer token (see that function's
-- own AUTH section). Per requirement #7/#8 of this step, that key
-- must never be hard-coded into migration source — instead it is
-- looked up at RUN TIME (every 5 minutes, fresh) from Supabase Vault,
-- which stores it encrypted at rest and exposes it in plaintext only
-- through vault.decrypted_secrets to a database session with
-- sufficient privilege (which the cron.schedule job body below has,
-- running as the role that owns the job).
--
-- Before (or at any point after) this migration is applied, run the
-- following ONCE, by hand, in the Supabase SQL editor (or via the
-- Supabase dashboard's Vault UI) — substituting your project's real
-- service_role key for the placeholder. Do NOT put the real key in
-- this migration file, in any other file, or in any commit:
--
--   select vault.create_secret(
--     '<paste your Supabase service_role key here>',
--     'referral_sweep_service_role_key',
--     'service_role key used only by the referral-qualification-sweep pg_cron job (0048_schedule_referral_qualification_sweep.sql) to authorize its scheduled POST to that Edge Function.'
--   );
--
-- If this secret does not exist yet at the moment a scheduled run
-- fires, the lookup below simply returns no row, the Authorization
-- header becomes 'Bearer ' (empty), and the Edge Function correctly
-- responds 401 — a harmless no-op, not an error, and nothing further
-- needs to change once the secret is created: the very next
-- scheduled run (within 5 minutes) will pick it up automatically.

-- ------------------------------------------------------------------
-- 3. (Re)schedule the job idempotently.
-- ------------------------------------------------------------------
-- This migration may be applied more than once (e.g. re-run in a
-- fresh environment, or replayed). If a job with this exact name
-- already exists, unschedule it first so the cron.schedule call right
-- after always results in exactly ONE job with this name and
-- definition — never a duplicate, and never an error from trying to
-- create a job name that already exists.
do $$
begin
  if exists (
    select 1
      from cron.job
     where jobname = 'referral-qualification-sweep-every-5-min'
  ) then
    perform cron.unschedule('referral-qualification-sweep-every-5-min');
  end if;
end;
$$;

-- pg_cron triggers the command below every 5 minutes
-- ('*/5 * * * *' — standard 5-field cron syntax: minute, hour,
-- day-of-month, month, day-of-week; "every 5th minute of every hour,
-- every day"). Each trigger runs exactly one statement: pg_net's
-- net.http_post(), which makes one asynchronous POST request to the
-- referral-qualification-sweep Edge Function with
-- Content-Type: application/json and an Authorization header built
-- from the Vault secret looked up fresh on every run (see section 2
-- above). This job does not itself decide anything about
-- qualification — all of that logic lives entirely inside the Edge
-- Function and the RPCs it calls
-- (get_and_lock_pending_referrals_batch, qualify_referral,
-- flag_referral — 0046/0047), which are unchanged by this migration.
-- coalesce(..., '') guards against the secret being momentarily
-- absent (see section 2) so this job body itself never errors either
-- way.
select cron.schedule(
  'referral-qualification-sweep-every-5-min',
  '*/5 * * * *',
  $cron$
  select net.http_post(
    url := 'https://zsjibrckzhaxagdqxdil.supabase.co/functions/v1/referral-qualification-sweep',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || coalesce(
        (
          select decrypted_secret
            from vault.decrypted_secrets
           where name = 'referral_sweep_service_role_key'
           limit 1
        ),
        ''
      )
    ),
    body := jsonb_build_object(
      'trigger', 'pg_cron',
      'triggered_at', now()
    )
  ) as request_id;
  $cron$
);

-- ------------------------------------------------------------------
-- No table, RPC, policy, reward/leaderboard object, or frontend file
-- is created, altered, or dropped by this migration beyond enabling
-- pg_cron/pg_net and scheduling the single named job above. 0043-0047
-- and auth-telegram/index.html/admin.html are all untouched. The
-- Vault secret this job depends on is intentionally NOT created by
-- this migration and must be set once, manually, as described in
-- section 2 — the job will simply no-op (401, logged by the Edge
-- Function, no error here) every 5 minutes until that secret exists.
-- ------------------------------------------------------------------
