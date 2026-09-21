-- Pro-X Network — Friends Referral system: qualification + manual
-- flagging.
--
-- Functions: public.qualify_referral(p_referral_id uuid)
--            public.flag_referral(p_referral_id uuid, p_reason text)
--
-- Context: per the FINAL LOCKED referral design (Design Revision v2),
-- this migration implements ONLY the qualification and manual-flag
-- foundation. It reads (never writes) public.referral_config
-- (0044_create_referral_config.sql), and reads/writes
-- public.referrals (0043_create_referrals.sql) and
-- public.mining_state.referral_count — nothing else. None of 0043,
-- 0044, or 0045_record_pending_referral.sql is modified.
--
-- Explicitly NOT part of this migration (all deferred, per the locked
-- migration sequence):
--   - Any Edge Function, and any pg_cron/scheduling wiring — neither
--     function below is called from anywhere yet.
--   - auth-telegram, index.html, admin.html — untouched.
--   - referral_milestones / referral_milestone_claims /
--     claim_referral_milestone / grant_miner_reward — no reward logic
--     of any kind exists yet; this migration never reads mpxn_ledger,
--     miner_catalog, or mining_inventory, and never credits anything.
--   - monthly_referral_leaderboard / monthly_referral_snapshot — do
--     not exist yet. Per the explicit instruction for this step, this
--     migration does NOT invent that table and does NOT make
--     qualification depend on it. qualify_referral() still fully
--     qualifies the referral and increments
--     mining_state.referral_count on its own; the exact point where a
--     later migration will add the leaderboard upsert is marked with
--     a "MONTHLY LEADERBOARD INTEGRATION POINT" comment below, so
--     that future step can be added without touching anything else in
--     this function.
--
-- Server-authoritative qualification: both functions operate ONLY on
-- an existing public.referrals row identified by p_referral_id. There
-- is no parameter on either function that accepts a caller-supplied
-- referrer_user_id or referred_user_id, and neither function ever
-- writes those two columns — only status and its associated
-- timestamps/reason columns are ever changed. This mirrors
-- 0045_record_pending_referral.sql's own guarantee that the
-- relationship itself is immutable once created.
--
-- Concurrency: qualify_referral() locks the target referrals row with
-- `select ... for update` before evaluating or changing anything —
-- the same idiom already used throughout this schema (e.g.
-- 0034_marketplace_rpcs.sql's listing/inventory locks). Holding that
-- lock for the duration of the transaction is what actually prevents
-- two concurrent qualification attempts on the same row from both
-- incrementing referral_count; the `where status = 'pending'` guard
-- on every subsequent UPDATE is defense-in-depth on top of that lock,
-- not the primary safeguard. mining_state.referral_count is
-- incremented with a single atomic `update ... set referral_count =
-- referral_count + 1 ... returning`, the same pattern
-- adjust_claimed_total (0030) and every mining_state writer in this
-- schema already uses — no other mining_state column is read or
-- written by either function.
--
-- Error/no-op philosophy: every ordinary "this referral does not
-- currently qualify" condition (already qualified/flagged/rejected,
-- cooldown not elapsed, thresholds not met, banned, burst detected)
-- is a SILENT NO-OP — both functions return a boolean describing what
-- happened, never an exception, for any of those cases. Exceptions
-- are raised only for genuine misuse (an unknown p_referral_id) or
-- server misconfiguration (no public.referral_config row, or the
-- referrer somehow having no public.mining_state row), continuing
-- this schema's existing PXNnn convention (next free codes after
-- PXN51, introduced by 0045):
--   PXN52 — qualify_referral: p_referral_id does not reference an
--           existing public.referrals row               -> 404
--   PXN53 — qualify_referral: the referred user's public.users row is
--           missing (data-integrity violation; should be unreachable
--           given the referrals table's own FK, listed only as
--           defense-in-depth)                            -> 500
--   PXN54 — qualify_referral: the referrer has no public.mining_state
--           row to increment (server misconfiguration/edge case —
--           qualification is rolled back entirely so the referral
--           stays 'pending' and can be retried once the referrer's
--           mining_state row exists)                      -> 500
--   PXN55 — flag_referral: p_referral_id does not reference an
--           existing public.referrals row               -> 404
--
-- Note on the banned-user check: the FINAL LOCKED DESIGN's original
-- anti-fraud section describes excluding a banned referrer OR
-- referred user. The specific rule list handed down for this
-- migration step names only the REFERRED user's public.users.is_banned
-- as a qualification-time hard rule, so that is exactly what is
-- implemented below (guarded by referral_config.exclude_banned, which
-- is expected to always be true). A referrer-banned check is
-- intentionally NOT added here, to avoid this migration silently
-- introducing a rule beyond what was specified for this step; it can
-- be added in a small follow-up migration if desired.

-- =====================================================================
-- A) public.qualify_referral(p_referral_id uuid)
-- =====================================================================

create or replace function public.qualify_referral(
  p_referral_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_referrer_user_id           uuid;
  v_referred_user_id           uuid;
  v_status                     text;
  v_qualification_eligible_at  timestamptz;

  v_referred_created_at        timestamptz;
  v_referred_is_banned         boolean;

  v_claim_count                integer;
  v_level                      integer;
  v_mined_balance_total        numeric(20,8);

  v_min_account_age_hours      integer;
  v_min_claim_count            integer;
  v_min_level                  integer;
  v_min_mined_balance_total    numeric(20,8);
  v_exclude_banned             boolean;
  v_burst_window_minutes       integer;
  v_burst_max_referrals        integer;

  v_recent_referral_count      integer;
  v_new_referral_count         integer;
begin
  -- ---------------------------------------------------------------
  -- 1. Lock the target referral row. A null or unknown p_referral_id
  --    naturally finds no row here (select ... where id = null is
  --    always "not found" in SQL) — treated as genuine misuse, not a
  --    normal qualification outcome, since a caller should only ever
  --    pass an id it already knows exists.
  -- ---------------------------------------------------------------
  select referrer_user_id, referred_user_id, status, qualification_eligible_at
    into v_referrer_user_id, v_referred_user_id, v_status, v_qualification_eligible_at
    from public.referrals
   where id = p_referral_id
     for update;

  if not found then
    raise exception 'qualify_referral: referral % not found', p_referral_id
      using errcode = 'PXN52';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Only a currently-'pending' row can ever be qualified here.
  --    Already-qualified/flagged/rejected is a silent no-op — this is
  --    also the row lock's own idempotency boundary: once this branch
  --    is passed, no concurrent call on the same row can reach it
  --    again until this transaction commits or rolls back, and by
  --    then status will no longer be 'pending'.
  -- ---------------------------------------------------------------
  if v_status <> 'pending' then
    return false;
  end if;

  -- ---------------------------------------------------------------
  -- 3. Cooldown: the timestamp frozen onto this row at insert time
  --    by record_pending_referral() (0045) — no referral_config read
  --    needed for this specific check, it was already resolved then.
  -- ---------------------------------------------------------------
  if now() < v_qualification_eligible_at then
    return false;
  end if;

  -- ---------------------------------------------------------------
  -- 4. Load current qualification thresholds. Read fresh on every
  --    call (not cached), since referral_config may be updated by a
  --    future admin RPC between calls, and each evaluation must use
  --    the values in effect right now.
  -- ---------------------------------------------------------------
  select min_account_age_hours, min_claim_count, min_level,
         min_mined_balance_total, exclude_banned,
         burst_window_minutes, burst_max_referrals
    into v_min_account_age_hours, v_min_claim_count, v_min_level,
         v_min_mined_balance_total, v_exclude_banned,
         v_burst_window_minutes, v_burst_max_referrals
    from public.referral_config
   where id = true;

  if not found then
    raise exception 'qualify_referral: no public.referral_config row exists (server misconfiguration)'
      using errcode = 'PXN51';
  end if;

  -- ---------------------------------------------------------------
  -- 5. Load the REFERRED user's account-age and ban status. Should
  --    always exist given public.referrals' FK to public.users
  --    (on delete cascade) — if it is somehow missing, that is data
  --    corruption, not a normal "not yet qualified" case, so this
  --    raises rather than silently no-op-ing.
  -- ---------------------------------------------------------------
  select created_at, is_banned
    into v_referred_created_at, v_referred_is_banned
    from public.users
   where id = v_referred_user_id;

  if not found then
    raise exception 'qualify_referral: referred user % for referral % is missing from public.users',
      v_referred_user_id, p_referral_id
      using errcode = 'PXN53';
  end if;

  -- 6. Minimum account age (hard rule).
  if now() < v_referred_created_at + make_interval(hours => v_min_account_age_hours) then
    return false;
  end if;

  -- ---------------------------------------------------------------
  -- 7. Banned-user exclusion (hard rule). A brand-new referred user
  --    may not have a mining_state row yet even after clearing the
  --    account-age check above, but public.users always exists by
  --    now (step 5), so is_banned is always readable here.
  -- ---------------------------------------------------------------
  if v_exclude_banned and v_referred_is_banned then
    return false;
  end if;

  -- ---------------------------------------------------------------
  -- 8. Minimum mining activity (hard rules): claim_count, level,
  --    mined_balance_total. A missing mining_state row for the
  --    referred user (they have not started mining yet) is treated as
  --    "does not currently meet the minimum" — a normal, expected,
  --    silent no-op, not an error; the row will simply be re-evaluated
  --    again on a later sweep once mining_state exists and catches up.
  -- ---------------------------------------------------------------
  select claim_count, level, mined_balance_total
    into v_claim_count, v_level, v_mined_balance_total
    from public.mining_state
   where user_id = v_referred_user_id;

  if not found then
    return false;
  end if;

  if v_claim_count < v_min_claim_count
     or v_level < v_min_level
     or v_mined_balance_total < v_min_mined_balance_total then
    return false;
  end if;

  -- ---------------------------------------------------------------
  -- 9. Burst / anti-fraud flagging (SOFT signal — routes to admin
  --    review, never a hard rejection). Counts every referrals row
  --    for this same referrer created within the rolling window,
  --    regardless of that other row's status (a burst is a volume
  --    signal on referral CREATION, not on qualification outcome) —
  --    including this row itself, since it already exists in the
  --    table with its own created_at. Only THIS referral (the one
  --    currently being evaluated) is ever flagged here: earlier
  --    referrals from the same burst that already qualified or were
  --    already flagged/rejected on a prior call are never revisited
  --    or re-flagged by this pass.
  -- ---------------------------------------------------------------
  select count(*)
    into v_recent_referral_count
    from public.referrals
   where referrer_user_id = v_referrer_user_id
     and created_at >= now() - make_interval(mins => v_burst_window_minutes);

  if v_recent_referral_count > v_burst_max_referrals then
    update public.referrals
       set status      = 'flagged',
           flagged_at  = now(),
           flag_reason = 'BURST_REFERRAL_THRESHOLD'
     where id = p_referral_id
       and status = 'pending';

    -- Not qualified: no referral_count increment, no leaderboard
    -- points, no reward of any kind. Awaits admin review
    -- (admin_review_referral — not implemented yet).
    return false;
  end if;

  -- ---------------------------------------------------------------
  -- 10. All hard rules passed and no soft signal fired: qualify,
  --     atomically, in this same transaction.
  -- ---------------------------------------------------------------
  update public.referrals
     set status       = 'qualified',
         qualified_at = now()
   where id = p_referral_id
     and status = 'pending';

  -- Only the REFERRER's counter ever moves; the referred user's own
  -- mining_state row (if any) is never touched by this function.
  update public.mining_state as ms
     set referral_count = ms.referral_count + 1
   where ms.user_id = v_referrer_user_id
  returning ms.referral_count into v_new_referral_count;

  if not found then
    -- Roll back the whole transaction, including the status update
    -- above: it must never be possible for a referral to end up
    -- 'qualified' without its referrer's counter having actually
    -- moved. The referral stays 'pending' and can be retried once the
    -- referrer has a mining_state row.
    raise exception 'qualify_referral: referrer % has no public.mining_state row to increment (referral %)',
      v_referrer_user_id, p_referral_id
      using errcode = 'PXN54';
  end if;

  -- ---------------------------------------------------------------
  -- MONTHLY LEADERBOARD INTEGRATION POINT (not implemented in this
  -- migration). Per the FINAL LOCKED DESIGN, a future migration will
  -- add an upsert here — e.g.
  --   insert into public.monthly_referral_leaderboard
  --     (period_key, user_id, qualified_referral_count)
  --   values (to_char(now(), 'YYYY-MM'), v_referrer_user_id, 1)
  --   on conflict (period_key, user_id)
  --   do update set qualified_referral_count =
  --     monthly_referral_leaderboard.qualified_referral_count + 1;
  -- — inserted directly after the mining_state update above, inside
  -- this same transaction, once that table exists. Nothing about the
  -- referral-relationship logic above needs to change to accommodate
  -- it: this qualify_referral() definition will simply be replaced
  -- (create or replace function) by that later migration, adding only
  -- the block described here.
  -- ---------------------------------------------------------------

  return true;
end;
$$;

comment on function public.qualify_referral(uuid) is
  'service_role-only. Locks and re-evaluates a single public.referrals row (must currently be ''pending''). Hard rules (all from the singleton public.referral_config row, read fresh on every call): cooldown (qualification_eligible_at), min_account_age_hours (referred user''s public.users.created_at), exclude_banned (referred user''s public.users.is_banned), min_claim_count / min_level / min_mined_balance_total (referred user''s public.mining_state). If a burst of referrals from the same referrer within burst_window_minutes exceeds burst_max_referrals, this referral (only this one) is set to ''flagged'' instead of qualified — a soft signal for admin review, never a hard rejection. On full qualification: sets status=''qualified'', qualified_at=now(), and atomically increments ONLY the referrer''s mining_state.referral_count (never the referred user''s). Every unmet condition is a silent no-op (returns false); exceptions (PXN51-PXN54) are raised only for an unknown referral id, a missing referral_config row, referred-user data corruption, or a referrer with no mining_state row (in which case the whole qualification is rolled back). Never writes referrer_user_id/referred_user_id. Does not yet touch any monthly-leaderboard table — see the MONTHLY LEADERBOARD INTEGRATION POINT comment in this function''s body. Not callable by anon/authenticated.';

revoke all on function public.qualify_referral(uuid) from public;
revoke all on function public.qualify_referral(uuid) from anon;
revoke all on function public.qualify_referral(uuid) from authenticated;
grant execute on function public.qualify_referral(uuid) to service_role;


-- =====================================================================
-- B) public.flag_referral(p_referral_id uuid, p_reason text)
-- =====================================================================

create or replace function public.flag_referral(
  p_referral_id uuid,
  p_reason      text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_status         text;
  v_clean_reason   text;
begin
  -- ---------------------------------------------------------------
  -- 1. Lock the target row. Unknown/null p_referral_id -> genuine
  --    misuse, raised rather than silently ignored, mirroring
  --    qualify_referral's own PXN52 case.
  -- ---------------------------------------------------------------
  select status
    into v_status
    from public.referrals
   where id = p_referral_id
     for update;

  if not found then
    raise exception 'flag_referral: referral % not found', p_referral_id
      using errcode = 'PXN55';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Status can only ever transition to 'flagged' FROM 'pending'.
  --    Any other current status — including already 'flagged'
  --    (idempotent replay), or 'qualified'/'rejected' (already
  --    resolved; flagging something already decided is not an
  --    allowed transition) — is a silent no-op, never an error, so a
  --    caller can never be surprised by an exception here from a
  --    simple race with another admin action.
  -- ---------------------------------------------------------------
  if v_status <> 'pending' then
    return false;
  end if;

  -- ---------------------------------------------------------------
  -- 3. Sanitize the reason: trim, fall back to a safe default when
  --    empty/null, bound the length so an oversized/adversarial
  --    string can never bloat this row.
  -- ---------------------------------------------------------------
  v_clean_reason := btrim(coalesce(p_reason, ''));
  if v_clean_reason = '' then
    v_clean_reason := 'MANUAL_REVIEW';
  end if;
  v_clean_reason := left(v_clean_reason, 200);

  update public.referrals
     set status      = 'flagged',
         flagged_at  = now(),
         flag_reason = v_clean_reason
   where id = p_referral_id
     and status = 'pending';

  return true;
end;
$$;

comment on function public.flag_referral(uuid, text) is
  'service_role-only. Transitions a single public.referrals row from ''pending'' to ''flagged'' only — any other current status (including already ''flagged'') is a silent no-op returning false. Sets flagged_at=now() and flag_reason to a trimmed, non-empty (default ''MANUAL_REVIEW''), length-bounded (200 char) version of p_reason. Never increments mining_state.referral_count, never awards anything, never writes referrer_user_id/referred_user_id. Intended for future privileged/admin workflows (admin_review_referral and equivalents) as well as automated soft-signal detection outside qualify_referral''s own burst check. Raises PXN55 only for an unknown p_referral_id. Not callable by anon/authenticated.';

revoke all on function public.flag_referral(uuid, text) from public;
revoke all on function public.flag_referral(uuid, text) from anon;
revoke all on function public.flag_referral(uuid, text) from authenticated;
grant execute on function public.flag_referral(uuid, text) to service_role;

-- ---------------------------------------------------------------
-- No table, policy, or existing function is created, altered, or
-- dropped by this migration beyond the two new functions above.
-- 0043_create_referrals.sql, 0044_create_referral_config.sql, and
-- 0045_record_pending_referral.sql are all read-only inputs to (or,
-- for 0043, mutated only via ordinary UPDATE on the columns it
-- defines by) these functions and are not modified. mining_config,
-- mpxn_ledger, miner_catalog, and mining_inventory are not touched at
-- all. Neither function is called from anywhere yet — that wiring
-- (a scheduled Edge Function, and future admin_review_referral()) is
-- a separate, later step, as is the monthly leaderboard table these
-- functions are structured to integrate with without further changes
-- to the referral-relationship logic itself.
-- ---------------------------------------------------------------
