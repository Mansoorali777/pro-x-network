-- Pro-X Network — Friends Referral system: pending-relationship RPC.
--
-- Function: public.record_pending_referral(p_referred_user_id uuid,
--                                           p_start_param text)
--
-- Context: per the FINAL LOCKED referral design (Design Revision v2,
-- §1 "REFERRAL CODE RESOLUTION"), this migration implements ONLY the
-- server-side RPC that turns a Telegram start_param into a pending
-- row in public.referrals (0043_create_referrals.sql), reading its
-- cooldown from public.referral_config (0044_create_referral_config.sql).
-- Neither 0043 nor 0044 is modified by this migration. This RPC:
--   - creates a PENDING relationship only. It never sets status to
--     anything but 'pending', never touches
--     mining_state.referral_count, never credits mpxn_ledger, never
--     grants a miner, and never touches monthly-leaderboard tables
--     (none of that logic/tables exist yet).
--   - is not yet called from anywhere. auth-telegram is NOT modified
--     by this migration — wiring this RPC into auth-telegram's
--     new-user-creation branch is a later, separate step.
--   - is not yet exposed via any Edge Function.
-- Qualification (qualify_referral/flag_referral), rewards
-- (claim_referral_milestone/grant_miner_reward), and the monthly
-- leaderboard/snapshot are all future, separate migrations.
--
-- Referral code = Telegram telegram_user_id (LOCKED). Per Design
-- Revision v2 §1, there is no separate referral-code column or table:
-- the code a new player's start_param carries IS the referrer's own
-- public.users.telegram_user_id, rendered as a plain decimal string.
-- This function resolves it with a single lookup against
-- public.users.telegram_user_id's existing unique index
-- (users_telegram_user_id_key, 0002_users.sql) — no new identifier
-- space, no new storage, no random/generated code of any kind.
--
-- Server-authoritative referrer resolution: the caller supplies only
-- p_start_param (an opaque string) and p_referred_user_id (the
-- brand-new account's own id, already known to the caller because it
-- just created that row). The caller can never supply a
-- referrer_user_id directly — this function is the ONLY thing that
-- ever resolves referrer_user_id, and it always does so itself, via
-- the telegram_user_id lookup below. There is no parameter, code
-- path, or fallback anywhere in this function that accepts a
-- caller-provided referrer id. This closes off "a client picks
-- someone else's UUID as my referrer" entirely.
--
-- Immutable one-time relationship: this function only ever INSERTs
-- into public.referrals, never UPDATEs an existing row's
-- referrer_user_id/referred_user_id — enforced additionally at the
-- table level by 0043's UNIQUE(referred_user_id) and
-- CHECK(referrer_user_id <> referred_user_id), both of which remain
-- completely untouched by this migration.
--
-- Failure philosophy: referral attribution is best-effort and must
-- never block or fail a login/account-creation flow. Every "this
-- start_param doesn't lead anywhere useful" case (malformed, unknown,
-- self-referral, referred user already has a referral) is a SILENT
-- NO-OP — this function returns false and raises no exception for any
-- of those cases. The only exceptions ever raised are for genuine
-- misuse of the function itself (null/unknown p_referred_user_id, or
-- a missing public.referral_config row — a server misconfiguration),
-- which are caller/deployment bugs, not something an ordinary
-- Telegram start_param value could ever trigger.
--
-- Error codes introduced by this migration (continuing this schema's
-- existing PXNnn convention, next free code after PXN49):
--   PXN50 — p_referred_user_id is null, or does not reference an
--           existing public.users row                    -> 400/404
--   PXN51 — no public.referral_config row exists (server
--           misconfiguration; 0044 seeds exactly one row, so this
--           should be unreachable in a correctly migrated database)
--                                                          -> 500

create or replace function public.record_pending_referral(
  p_referred_user_id  uuid,
  p_start_param       text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_code             text;
  v_referrer_tg_id   bigint;
  v_referrer_user_id uuid;
  v_cooldown_hours   integer;
  v_eligible_at      timestamptz;
begin
  -- ---------------------------------------------------------------
  -- 1. Validate p_referred_user_id. This is the one input this
  --    function trusts as an identifier (never as a referrer), and
  --    only because it is expected to be the id the caller (the
  --    future auth-telegram wiring) just created moments earlier in
  --    the same request. Still validated defensively, exactly like
  --    purchase_miner validates p_user_id (0016_secure_miner_purchase.sql).
  -- ---------------------------------------------------------------
  if p_referred_user_id is null then
    raise exception 'record_pending_referral: p_referred_user_id is required'
      using errcode = 'PXN50';
  end if;

  if not exists (select 1 from public.users where id = p_referred_user_id) then
    raise exception 'record_pending_referral: no public.users row for p_referred_user_id %',
      p_referred_user_id
      using errcode = 'PXN50';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Validate + parse p_start_param. Trim whitespace, require
  --    ^[0-9]{5,15}$ (a plain decimal Telegram user id — Telegram's
  --    own start_param charset is [A-Za-z0-9_-]{1,64}, so this is
  --    additionally a strict subset match, not just a length check).
  --    Anything else — empty, non-numeric, wrong length, an organic
  --    install with no start_param at all — is NOT an error: it is
  --    simply "no referral to attribute", so this function returns
  --    false and does nothing further.
  -- ---------------------------------------------------------------
  v_code := btrim(coalesce(p_start_param, ''));

  if v_code !~ '^[0-9]{5,15}$' then
    return false;
  end if;

  -- Safe cast: 15 digits can never overflow bigint (max ~19 digits),
  -- but this defends against any future relaxation of the regex above
  -- rather than assuming the regex alone is sufficient forever.
  begin
    v_referrer_tg_id := v_code::bigint;
  exception
    when others then
      return false;
  end;

  -- ---------------------------------------------------------------
  -- 3. Resolve the referrer server-side, and ONLY server-side, via
  --    the existing unique index on public.users.telegram_user_id.
  --    If no such Telegram user exists, this is an unknown/stale
  --    code — silent no-op, never an error.
  -- ---------------------------------------------------------------
  select id
    into v_referrer_user_id
    from public.users
   where telegram_user_id = v_referrer_tg_id
   limit 1;

  if not found then
    return false;
  end if;

  -- ---------------------------------------------------------------
  -- 4. Self-referral guard. Checked here as the primary, cheap
  --    short-circuit (before ever attempting an insert); the table's
  --    own CHECK(referrer_user_id <> referred_user_id)
  --    (0043_create_referrals.sql) remains as independent
  --    defense-in-depth in case this check is ever bypassed by a
  --    future change to this function.
  -- ---------------------------------------------------------------
  if v_referrer_user_id = p_referred_user_id then
    return false;
  end if;

  -- ---------------------------------------------------------------
  -- 5. Read the cooldown from the singleton public.referral_config
  --    row (0044_create_referral_config.sql) and compute
  --    qualification_eligible_at. Only referral_config.cooldown_hours
  --    is read here — no other configuration column from that table
  --    is used by this function.
  -- ---------------------------------------------------------------
  select cooldown_hours
    into v_cooldown_hours
    from public.referral_config
   where id = true;

  if not found then
    raise exception 'record_pending_referral: no public.referral_config row exists (server misconfiguration)'
      using errcode = 'PXN51';
  end if;

  v_eligible_at := now() + make_interval(hours => v_cooldown_hours);

  -- ---------------------------------------------------------------
  -- 6. Insert the pending relationship. status is always 'pending'
  --    here — this function never sets 'qualified', 'flagged', or
  --    'rejected'; that belongs to the future qualify_referral() /
  --    flag_referral() / admin_review_referral(), none of which exist
  --    yet. A unique_violation on referrals_referred_user_id_key
  --    (0043) means p_referred_user_id already has a referral row —
  --    per the locked design this is also a silent no-op (idempotent:
  --    calling this function twice for the same referred user safely
  --    does nothing the second time), never a user-facing error.
  -- ---------------------------------------------------------------
  begin
    insert into public.referrals (
      referrer_user_id,
      referred_user_id,
      start_param_used,
      status,
      qualification_eligible_at,
      created_by
    ) values (
      v_referrer_user_id,
      p_referred_user_id,
      v_code,
      'pending',
      v_eligible_at,
      'auth-telegram'
    );
  exception
    when unique_violation then
      return false;
  end;

  return true;
end;
$$;

comment on function public.record_pending_referral(uuid, text) is
  'service_role-only. Resolves a Telegram start_param to a referrer by looking it up directly as public.users.telegram_user_id (the LOCKED referral-code design — no separate code column/table), then inserts a single ''pending'' row into public.referrals with qualification_eligible_at = now() + public.referral_config.cooldown_hours. The referrer is ALWAYS resolved server-side from telegram_user_id; the caller can never supply a referrer id directly. Self-referral, an unresolvable/malformed start_param, a referred user who already has a referral row (unique_violation on referrals_referred_user_id_key), and a start_param with no matching telegram_user_id are all silent no-ops (returns false, raises no exception) — referral attribution must never block or fail account creation. Raises PXN50 only for a null/unknown p_referred_user_id and PXN51 only if public.referral_config has no row (server misconfiguration). Never touches mining_state.referral_count, mpxn_ledger, mining_inventory, or any monthly-leaderboard table — this function only ever creates a pending relationship; qualification and rewards are implemented by later, separate functions. Not callable by anon/authenticated.';

-- ---------------------------------------------------------------
-- Lock down exactly like every other privileged RPC in this schema
-- (purchase_miner, adjust_claimed_total, etc.): revoke the default
-- PUBLIC execute grant, then grant only to service_role, which is
-- the only role ever used inside Edge Functions.
-- ---------------------------------------------------------------
revoke all on function public.record_pending_referral(uuid, text) from public;
revoke all on function public.record_pending_referral(uuid, text) from anon;
revoke all on function public.record_pending_referral(uuid, text) from authenticated;
grant execute on function public.record_pending_referral(uuid, text) to service_role;

-- ---------------------------------------------------------------
-- No table, policy, or existing function is created, altered, or
-- dropped by this migration beyond the single new function above.
-- 0043_create_referrals.sql and 0044_create_referral_config.sql are
-- both read-only inputs to this function and are not modified. This
-- function is not yet called from auth-telegram or any Edge
-- Function — that wiring, plus qualify_referral()/flag_referral(),
-- claim_referral_milestone(), grant_miner_reward(), and the monthly
-- snapshot/leaderboard functions, are all separate, later steps.
-- ---------------------------------------------------------------
