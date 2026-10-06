-- Pro-X Network — Friends Referral system: qualification sweep batch
-- fetch.
--
-- Function: public.get_and_lock_pending_referrals_batch(p_batch_size integer)
--
-- Context: per the FINAL LOCKED referral design (Design Revision v2,
-- §4 "QUALIFICATION SWEEP"), this migration implements ONLY the
-- concurrency-safe batch-fetch RPC the future
-- referral-qualification-sweep Edge Function calls to find pending
-- referrals ready for evaluation. It reads public.referrals
-- (0043_create_referrals.sql) and writes NOTHING — no status change,
-- no timestamp, no referral_count increment, no leaderboard row, no
-- reward of any kind. Actually qualifying/flagging a referral remains
-- entirely the job of public.qualify_referral() /
-- public.flag_referral() (0046_qualify_and_flag_referral.sql), which
-- this migration does not modify. 0044 and 0045 are also untouched.
--
-- ============================================================
-- WHY "FOR UPDATE SKIP LOCKED" HERE DOES NOT NEED TO — AND
-- CANNOT — REMAIN HELD ACROSS THE SUBSEQUENT qualify_referral()
-- CALLS.
-- ============================================================
--
-- Each call into this RPC over PostgREST/Supabase's RPC interface
-- runs as its own single, independently-committed transaction; there
-- is no way for a lock taken inside this function's `for update skip
-- locked` to survive past the moment this function returns and that
-- transaction commits. The Edge Function that calls this RPC then
-- makes SEPARATE, LATER calls to public.qualify_referral(id) for each
-- returned row — each of those is, in turn, its own independent
-- transaction. It would therefore be WRONG to assume the row lock
-- taken here is still held by the time qualify_referral() runs for
-- that same row; it is not, and no design here relies on it being so.
--
-- What `for update skip locked` actually buys us, precisely: if two
-- sweep invocations happen to be genuinely, physically concurrent
-- (their transactions overlap in wall-clock time — e.g. an
-- accidental double-trigger, or a slow first run still in flight when
-- a second is kicked off), the second invocation's SELECT will skip
-- any row the first invocation's SELECT is *currently* holding
-- locked, so the two invocations return disjoint batches instead of
-- both returning the same rows during that overlap window. That is
-- the entire (and sufficient) purpose of the lock here: preventing
-- two simultaneously-running batch-fetch calls from both handing the
-- same referral to two different Edge Function workers at once.
--
-- The lock intentionally does NOT need to (and cannot) prevent every
-- possible later race, because the actual, final safety guarantee for
-- correctness is provided entirely by public.qualify_referral()
-- itself (0046): it takes its OWN fresh `select ... for update` lock
-- on the single target row and rechecks `status = 'pending'` before
-- ever mutating anything, inside the SAME transaction as that
-- mutation. So even if this batch RPC were called twice in a row
-- (lock already released between the two calls) and happened to
-- return the same pending referral id both times — or if a slow
-- previous sweep is still working through a batch that overlaps with
-- a new one — at most ONE of the resulting qualify_referral(id) calls
-- can ever actually transition that row, because the second one finds
-- status already 'qualified'/'flagged'/'rejected' and safely returns
-- false. This RPC's locking is therefore a genuine, useful
-- concurrency optimization (avoids handing out obviously-already-
-- claimed work), not the mechanism that makes double-processing
-- unsafe — qualify_referral()'s own lock-and-recheck is.
--
-- p_batch_size validation: NULL -> 500 (the default), clamped to the
-- inclusive range [1, 500] — never rejected with an error, always
-- silently clamped, since an out-of-range batch size from a future
-- caller (e.g. a misconfigured cron payload) is an operational
-- nuisance to cap, not a genuine misuse worth failing the whole sweep
-- over.

create or replace function public.get_and_lock_pending_referrals_batch(
  p_batch_size integer default 500
)
returns table (
  id                          uuid,
  referrer_user_id            uuid,
  referred_user_id            uuid,
  qualification_eligible_at   timestamptz,
  created_at                  timestamptz
)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_batch_size integer;
begin
  -- Clamp, never error: NULL -> 500, minimum 1, maximum 500. This
  -- keeps a single call from ever locking an unbounded number of
  -- rows, regardless of what a future caller passes.
  v_batch_size := coalesce(p_batch_size, 500);
  if v_batch_size < 1 then
    v_batch_size := 1;
  elsif v_batch_size > 500 then
    v_batch_size := 500;
  end if;

  -- Only rows that are actually ready right now: still 'pending' and
  -- past their frozen cooldown (qualification_eligible_at, set once
  -- by record_pending_referral() — 0045). Ordered oldest-eligible
  -- first so a persistent backlog is worked down in a stable, fair
  -- order across repeated sweep runs, with created_at and id as
  -- deterministic tiebreakers. `for update skip locked` is placed
  -- after ORDER BY/LIMIT, which is the only place it can go — see the
  -- header comment above for exactly what this lock does and does not
  -- guarantee.
  return query
    select r.id,
           r.referrer_user_id,
           r.referred_user_id,
           r.qualification_eligible_at,
           r.created_at
      from public.referrals as r
     where r.status = 'pending'
       and r.qualification_eligible_at <= now()
     order by r.qualification_eligible_at asc,
              r.created_at asc,
              r.id asc
     limit v_batch_size
       for update skip locked;
end;
$$;

comment on function public.get_and_lock_pending_referrals_batch(integer) is
  'service_role-only. Returns up to p_batch_size (default/NULL 500, clamped to [1,500]) public.referrals rows with status=''pending'' and qualification_eligible_at <= now(), oldest-eligible first, using SELECT ... FOR UPDATE SKIP LOCKED so two genuinely concurrent invocations return disjoint batches. This function NEVER changes status, timestamps, referral_count, or any reward/leaderboard data — it only reads and briefly locks rows for the duration of its own (short, single-statement) transaction. The lock does NOT and cannot persist across the caller''s subsequent, separate public.qualify_referral(id) calls (each Edge Function call to that RPC is its own independent transaction) — final correctness against double-processing is provided entirely by qualify_referral()''s own fresh row lock + status=''pending'' recheck at mutation time, not by this function''s lock. Not callable by anon/authenticated.';

revoke all on function public.get_and_lock_pending_referrals_batch(integer) from public;
revoke all on function public.get_and_lock_pending_referrals_batch(integer) from anon;
revoke all on function public.get_and_lock_pending_referrals_batch(integer) from authenticated;
grant execute on function public.get_and_lock_pending_referrals_batch(integer) to service_role;

-- ---------------------------------------------------------------
-- No table, policy, or existing function is created, altered, or
-- dropped by this migration beyond the single new function above.
-- 0043_create_referrals.sql, 0044_create_referral_config.sql,
-- 0045_record_pending_referral.sql, and
-- 0046_qualify_and_flag_referral.sql are all untouched. This function
-- is not yet called from anywhere — the referral-qualification-sweep
-- Edge Function that calls it, and any pg_cron/pg_net scheduling of
-- that function, are separate steps (the Edge Function is delivered
-- alongside this migration per the current step; scheduling is
-- explicitly deferred until after manual testing).
-- ---------------------------------------------------------------
