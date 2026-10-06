-- Pro-X Network — Allow manual_claim Tasks To Be Awarded.
--
-- Function: public.claim_task(p_user_id uuid, p_task_id uuid, p_request_id uuid)
--           (CREATE OR REPLACE — same function, same signature, same
--           return type, same security model, same grants; see below)
--
-- Context: 0037_task_claims.sql created public.claim_task with
-- manual_claim unconditionally rejecting with TASK_VERIFICATION_
-- REQUIRED (PXN33), because manual_claim has no automatic way to
-- confirm a player actually completed an external action (following a
-- social link, joining a channel, etc. — task_catalog.action_url).
-- 0039_claim_task_requirement_verification.sql then wired up real
-- server-side verification for referral_count/miner_level/claim_count
-- (comparing task_catalog.requirement_value against the caller's
-- mining_state) but explicitly left manual_claim's unconditional
-- rejection alone.
--
-- Product decision (this migration): manual_claim is being changed
-- from "always rejected" to "granted on trust". This does NOT add any
-- verification manual_claim didn't have before, and does not pretend
-- to — it remains true, exactly as before, that public.claim_task
-- cannot confirm a player completed a manual_claim task's external
-- action. What changes is only that the product has decided to award
-- the reward anyway once the ordinary, non-verification-related
-- checks already in this function (task exists, is active, has a
-- valid reward, caller exists, not already claimed) pass — the same
-- trust-based trade-off many task/quest systems make for
-- unverifiable "follow us on X" / "join our channel" style tasks.
--
-- This migration does NOT modify 0037_task_claims.sql,
-- 0038_task_verification_requirements.sql, or
-- 0039_claim_task_requirement_verification.sql — those files are
-- completely untouched. It uses CREATE OR REPLACE FUNCTION to install
-- a new body for the *same* public.claim_task(uuid, uuid, uuid) that
-- 0037 defined and 0039 already replaced once — the normal, additive
-- way Postgres migrations evolve a function over time.
--
-- What is UNCHANGED from 0039's version of this function (verbatim,
-- not re-derived):
--   - Signature, return type, security definer, search_path.
--   - Steps 1-7 exactly as 0039 left them: input validation (PXN29),
--     the p_request_id idempotency fast path (replays an
--     already-committed result rather than re-verifying or
--     re-crediting), the FOR UPDATE lock + load of the task_catalog
--     row and PXN30 (not found), PXN31 (not active), the
--     reward_mpxn >= 0 sanity check (PXN34), confirming a users row
--     exists for the caller (PXN34), and PXN32 (already claimed).
--   - referral_count / miner_level / claim_count verification: byte-
--     identical to 0039 — still loads the caller's mining_state row,
--     still compares it against task_catalog.requirement_value
--     (locked in step 3, never client input), still raises PXN33 on a
--     shortfall and PXN25 if the caller has no mining_state row at
--     all. NOT weakened, NOT bypassed, NOT touched by this migration
--     in any way.
--   - Step 9: the atomic insert into task_claims followed by the
--     adjust_claimed_total() credit — identical statements, identical
--     order, identical idempotency/uniqueness guarantees
--     (UNIQUE(user_id, task_id) on task_claims, plus mpxn_ledger's own
--     unique index backstopping the request_id path) as 0037/0039.
--   - Grants: unaffected by CREATE OR REPLACE (privileges attach to
--     the function's identity, not its body) — still service_role
--     execute only, still revoked from public/anon/authenticated; not
--     re-stated here.
--
-- What CHANGES — ONLY the manual_claim branch of step 8:
--   - Before: unconditionally `raise exception ... using errcode =
--     'PXN33'` (TASK_VERIFICATION_REQUIRED), every single time.
--   - After: no automatic verification is performed (none exists, and
--     none is invented here) — the branch falls straight through to
--     step 9's atomic insert-and-credit, exactly as the
--     referral_count/miner_level/claim_count branch already does once
--     its threshold check passes. A manual_claim task is now claimable
--     exactly once per (user_id, task_id) — the same
--     UNIQUE(user_id, task_id) constraint on task_claims that has
--     always protected every other verification_type continues to
--     protect manual_claim too; nothing new is required for that
--     guarantee, and PXN32 (already claimed, step 7) still catches
--     the common case before step 8 is even reached.
--   - referral_count / miner_level / claim_count and the "unsupported
--     verification_type" else-branch are untouched.
--
-- This migration does NOT:
--   - alter task_catalog, task_claims, mpxn_ledger, mining_state,
--     miner_catalog, mining_config, mining_inventory, marketplace_*,
--     or users in any way (schema, RLS, or data) — it only replaces
--     one function body;
--   - touch mined_balance_total or pxn_balance — claim_task still
--     never reads or writes either column;
--   - change adjust_claimed_total(), level_up_mining(),
--     is_current_user_admin(), set_updated_at(), or any other
--     existing function;
--   - weaken, bypass, or otherwise touch referral_count/miner_level/
--     claim_count verification;
--   - change index.html, admin.html, or any Edge Function. (The
--     player-side action_url-opening convenience for manual_claim
--     tasks lives entirely in index.html's CLAIM click handler and
--     never reaches this function; claim-task/index.ts needs no code
--     change either, since it already just forwards whatever this
--     RPC returns.)
create or replace function public.claim_task(
  p_user_id    uuid,
  p_task_id    uuid,
  p_request_id uuid
)
returns table (
  claim_id      uuid,
  task_id       uuid,
  reward_mpxn   numeric(20,8),
  claimed_total numeric(20,8),
  request_id    uuid
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_task           public.task_catalog%rowtype;
  v_existing_claim public.task_claims%rowtype;
  v_existing_ledger public.mpxn_ledger%rowtype;
  v_mining_state   public.mining_state%rowtype;
  v_new_balance    numeric(20,8);
  v_claim_id       uuid;
begin
  -- ---------------------------------------------------------------
  -- 1. Validate input. Unchanged from 0037/0039.
  -- ---------------------------------------------------------------
  if p_user_id is null then
    raise exception 'claim_task: p_user_id is required'
      using errcode = 'PXN29';
  end if;

  if p_task_id is null then
    raise exception 'claim_task: p_task_id is required'
      using errcode = 'PXN29';
  end if;

  if p_request_id is null then
    raise exception 'claim_task: p_request_id is required'
      using errcode = 'PXN29';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Idempotency fast path. Unchanged from 0037/0039.
  -- ---------------------------------------------------------------
  select *
    into v_existing_ledger
    from public.mpxn_ledger
   where user_id  = p_user_id
     and reason    = 'task_claim'
     and ref_type  = 'task_claim_request'
     and ref_id    = p_request_id;

  if found then
    select tc.*
      into v_existing_claim
      from public.task_claims as tc
     where tc.user_id = p_user_id
       and tc.task_id = p_task_id;

    if not found then
      raise exception 'claim_task: mpxn_ledger row exists for request_id % with no matching task_claims row (user_id %, task_id %)',
        p_request_id, p_user_id, p_task_id
        using errcode = 'PXN34';
    end if;

    return query
      select v_existing_claim.id, v_existing_claim.task_id, v_existing_claim.reward_mpxn,
             v_existing_ledger.balance_after, p_request_id;
    return;
  end if;

  -- ---------------------------------------------------------------
  -- 3. Lock and load the task row. Unchanged from 0037/0039.
  -- ---------------------------------------------------------------
  select *
    into v_task
    from public.task_catalog
   where id = p_task_id
     for update;

  if not found then
    raise exception 'claim_task: task_id % not found', p_task_id
      using errcode = 'PXN30';
  end if;

  -- ---------------------------------------------------------------
  -- 4. Task must be active. Unchanged from 0037/0039.
  -- ---------------------------------------------------------------
  if not v_task.is_active then
    raise exception 'claim_task: task_id % is not active', p_task_id
      using errcode = 'PXN31';
  end if;

  -- ---------------------------------------------------------------
  -- 5. Sanity check on the catalog row's own reward value. Unchanged
  --    from 0037/0039.
  -- ---------------------------------------------------------------
  if v_task.reward_mpxn < 0 then
    raise exception 'claim_task: task_id % has an invalid reward_mpxn (%)', p_task_id, v_task.reward_mpxn
      using errcode = 'PXN34';
  end if;

  -- ---------------------------------------------------------------
  -- 6. Confirm the authenticated caller actually has a users row.
  --    Unchanged from 0037/0039.
  -- ---------------------------------------------------------------
  perform 1
    from public.users as u
   where u.id = p_user_id;

  if not found then
    raise exception 'claim_task: no users row for user_id %', p_user_id
      using errcode = 'PXN34';
  end if;

  -- ---------------------------------------------------------------
  -- 7. Reject if this exact (user, task) was already claimed.
  --    Unchanged from 0037/0039 — this is what continues to protect
  --    manual_claim (and every other verification_type) from a
  --    duplicate reward, together with task_claims'
  --    UNIQUE(user_id, task_id) constraint itself (the race-free
  --    guarantee — see step 9).
  -- ---------------------------------------------------------------
  perform 1
    from public.task_claims as tc
   where tc.user_id = p_user_id
     and tc.task_id = p_task_id;

  if found then
    raise exception 'claim_task: task_id % already claimed by user_id %', p_task_id, p_user_id
      using errcode = 'PXN32';
  end if;

  -- ---------------------------------------------------------------
  -- 8. Verification. THIS MIGRATION CHANGES ONLY THE manual_claim
  --    BRANCH BELOW.
  --
  --      - manual_claim: no automatic verification exists, and none
  --        is invented here — this branch is intentionally a no-op
  --        (does nothing, checks nothing) and falls straight through
  --        to step 9. The task is granted on trust once the ordinary
  --        checks in steps 3-7 above have already passed. This is a
  --        deliberate product trade-off for tasks whose completion
  --        (e.g. following an external link) cannot be confirmed
  --        server-side — it is not, and must never be read as, actual
  --        verification.
  --      - referral_count / miner_level / claim_count: byte-identical
  --        to 0039 — unchanged, unweakened.
  -- ---------------------------------------------------------------
  if v_task.verification_type = 'manual_claim' then
    -- Intentionally unverified: nothing to check. Falls through to
    -- step 9 below.
    null;
  elsif v_task.verification_type in ('referral_count', 'miner_level', 'claim_count') then
    select *
      into v_mining_state
      from public.mining_state
     where user_id = p_user_id;

    if not found then
      raise exception 'claim_task: no mining_state row for user_id %', p_user_id
        using errcode = 'PXN25';
    end if;

    if v_task.verification_type = 'referral_count' then
      if v_mining_state.referral_count < v_task.requirement_value then
        raise exception 'claim_task: task_id % (referral_count) requires referral_count >= % but user_id % has %',
          p_task_id, v_task.requirement_value, p_user_id, v_mining_state.referral_count
          using errcode = 'PXN33';
      end if;
    elsif v_task.verification_type = 'miner_level' then
      if v_mining_state.level < v_task.requirement_value then
        raise exception 'claim_task: task_id % (miner_level) requires level >= % but user_id % has %',
          p_task_id, v_task.requirement_value, p_user_id, v_mining_state.level
          using errcode = 'PXN33';
      end if;
    elsif v_task.verification_type = 'claim_count' then
      if v_mining_state.claim_count < v_task.requirement_value then
        raise exception 'claim_task: task_id % (claim_count) requires claim_count >= % but user_id % has %',
          p_task_id, v_task.requirement_value, p_user_id, v_mining_state.claim_count
          using errcode = 'PXN33';
      end if;
    end if;
    -- Requirement satisfied — fall through to step 9 below.
  else
    raise exception 'claim_task: task_id % has an unsupported verification_type (%)', p_task_id, v_task.verification_type
      using errcode = 'PXN33';
  end if;

  -- ---------------------------------------------------------------
  -- 9. Atomic insert + credit. Unchanged from 0037/0039. reward_mpxn
  --    still comes only from v_task (task_catalog) — never from the
  --    request — for manual_claim exactly as for every other
  --    verification_type.
  -- ---------------------------------------------------------------
  v_claim_id := gen_random_uuid();

  insert into public.task_claims (id, user_id, task_id, reward_mpxn, verification_type, claimed_at)
  values (v_claim_id, p_user_id, p_task_id, v_task.reward_mpxn, v_task.verification_type, now());

  v_new_balance := public.adjust_claimed_total(
    p_user_id,
    v_task.reward_mpxn,
    'task_claim',
    'task_claim_request',
    p_request_id
  );

  return query
    select v_claim_id, p_task_id, v_task.reward_mpxn, v_new_balance, p_request_id;
end;
$$;

comment on function public.claim_task(uuid, uuid, uuid) is
  'Service-role-only, atomic Task Claim. Locks the target task_catalog row, rejects TASK_NOT_FOUND (PXN30) / TASK_INACTIVE (PXN31) / TASK_ALREADY_CLAIMED (PXN32), then verifies completion: manual_claim is intentionally unverified and is granted once the preceding checks pass (0040_claim_task_manual_claim_award.sql — completion of its external action_url cannot be confirmed server-side, so this is a trust-based grant, not verification); referral_count/miner_level/claim_count compare the caller''s mining_state counter (referral_count/level/claim_count) against task_catalog.requirement_value, rejecting with PXN33 if not met, or PXN25 if the caller has no mining_state row (0039_claim_task_requirement_verification.sql). Only then does it insert into task_claims and credit m.PXN via adjust_claimed_total() (0030_mpxn_ledger_primitive.sql), both in this same transaction — either both happen or neither does. Idempotent on (user_id, p_request_id) for a genuine network-level retry, backstopped by task_claims'' own UNIQUE(user_id, task_id) and mpxn_ledger''s unique index for the race case. Never reads or writes pxn_balance, pending_claim, or mined_balance_total. Not callable by anon/authenticated.';

-- Grants are unchanged: CREATE OR REPLACE FUNCTION preserves the
-- existing privileges on public.claim_task(uuid, uuid, uuid) set by
-- 0037_task_claims.sql (service_role execute only; revoked from
-- public/anon/authenticated). Nothing to re-grant here.

-- ---------------------------------------------------------------
-- Nothing else is touched. In particular, this migration does NOT:
--   - alter task_catalog, task_claims, mining_state, mpxn_ledger,
--     miner_catalog, mining_config, mining_inventory, marketplace_*,
--     or users in any way (schema, RLS, or data);
--   - modify or redefine adjust_claimed_total(), level_up_mining(),
--     is_current_user_admin(), set_updated_at(), or any other
--     existing function;
--   - change index.html, admin.html, or any Edge Function (including
--     claim-task/index.ts, which needs no code change — it already
--     just forwards whatever public.claim_task returns);
--   - weaken referral_count/miner_level/claim_count verification in
--     any way.
-- ---------------------------------------------------------------
