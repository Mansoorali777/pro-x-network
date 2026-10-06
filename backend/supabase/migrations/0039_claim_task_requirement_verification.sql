-- Pro-X Network — Unblock Task Claim Verification.
--
-- Function: public.claim_task(p_user_id uuid, p_task_id uuid, p_request_id uuid)
--           (CREATE OR REPLACE — same function, same signature, same
--           return type, same security model, same grants; see below)
--
-- Context: 0037_task_claims.sql created public.claim_task with a
-- verification step (its step 8) that unconditionally rejects every
-- claim with TASK_VERIFICATION_REQUIRED (PXN33), because
-- task_catalog had no structured threshold to compare a player's
-- live mining_state counters against. 0038_task_verification_
-- requirements.sql then added that column (task_catalog.
-- requirement_value) but explicitly left claim_task untouched — its
-- own header says so outright. This migration is the "later,
-- separate step" both of those migrations pointed to: it replaces
-- ONLY claim_task's verification step with real comparisons against
-- requirement_value and the caller's mining_state row.
--
-- This migration does NOT modify 0037_task_claims.sql or
-- 0038_task_verification_requirements.sql — those files, and the
-- rows/columns/constraints/policies/tables they created
-- (task_claims, its RLS policy, task_catalog.requirement_value and
-- its check constraint) are completely untouched. It uses
-- CREATE OR REPLACE FUNCTION to install a new body for the *same*
-- public.claim_task(uuid, uuid, uuid) that 0037 defined — this is
-- the normal, additive way Postgres migrations evolve a function
-- over time; the original migration file remains byte-for-byte as
-- it was.
--
-- What is UNCHANGED from 0037's version of this function (verbatim,
-- not re-derived):
--   - Signature: claim_task(p_user_id uuid, p_task_id uuid, p_request_id uuid)
--   - Return type: table (claim_id uuid, task_id uuid,
--     reward_mpxn numeric(20,8), claimed_total numeric(20,8),
--     request_id uuid)
--   - security definer, set search_path = public, pg_temp
--   - Step 1: input validation (PXN29)
--   - Step 2: idempotency fast path keyed on mpxn_ledger
--     (user_id, 'task_claim', 'task_claim_request', p_request_id) —
--     unchanged replay logic and PXN34 data-integrity guard
--   - Step 3: SELECT ... FOR UPDATE lock + load of the task_catalog
--     row, and PXN30 (not found)
--   - Step 4: PXN31 (task not active)
--   - Step 5: reward_mpxn >= 0 sanity check (PXN34)
--   - Step 6: confirm a public.users row exists for p_user_id (PXN34)
--   - Step 7: PXN32 (already claimed — task_claims'
--     UNIQUE(user_id, task_id) fast-path check)
--   - Step 9: atomic insert into task_claims followed by the
--     adjust_claimed_total() credit — identical statements, identical
--     order (insert before credit, so a racing duplicate fails on
--     task_claims' own unique constraint before any m.PXN moves)
--   - Grants: service_role execute only, revoked from
--     public/anon/authenticated — unaffected by CREATE OR REPLACE
--     (privileges attach to the function's identity, not its body),
--     so they are not re-stated here; still exactly as 0037 left them.
--   - Idempotency, locking, and the task_claims/adjust_claimed_total
--     write path are otherwise byte-identical to 0037.
--
-- What CHANGES — ONLY step 8, the verification step:
--   - manual_claim: UNCHANGED. Still always raises
--     TASK_VERIFICATION_REQUIRED (PXN33) — manual_claim still has no
--     automatic verification mechanism, and per the standing rule, a
--     task is never rewarded merely because CLAIM was tapped.
--   - referral_count: now loads the caller's public.mining_state row
--     and requires mining_state.referral_count >=
--     task_catalog.requirement_value (read via v_task, the already-
--     locked row from step 3 — never re-read from the request). If
--     satisfied, falls through to the existing step 9 exactly as
--     before; if not, raises PXN33 with a message naming the actual
--     vs. required value (no reward, no task_claims row).
--   - miner_level: identical shape, comparing mining_state.level >=
--     requirement_value.
--   - claim_count: identical shape, comparing mining_state.claim_count
--     >= requirement_value.
--   - If no mining_state row exists at all for the caller, that is
--     the same PXN25 condition adjust_claimed_total() itself already
--     uses for "no mining_state row for this user_id" — surfaced here
--     up front (before ever reaching adjust_claimed_total) with the
--     identical errcode and equivalent message, so the Edge Function's
--     existing PXN25 -> 404 mapping keeps working unchanged.
--   - requirement_value is read exclusively from v_task
--     (task_catalog, locked FOR UPDATE in step 3) — never from
--     p_user_id/p_task_id/p_request_id or any other client input.
--     mining_state is read by user_id = p_user_id, i.e. the
--     Supabase-auth-verified caller obtained by the claim-task Edge
--     Function's auth.getUser() — never a client-supplied user_id.
--
-- This migration does NOT:
--   - alter task_catalog, task_claims, mpxn_ledger, mining_state,
--     miner_catalog, mining_config, mining_inventory, marketplace_*,
--     or users in any way (schema, RLS, or data) — it only replaces
--     one function body;
--   - touch mined_balance_total or pxn_balance — claim_task still
--     never reads or writes either column, exactly as before;
--   - change adjust_claimed_total(), level_up_mining(),
--     is_current_user_admin(), set_updated_at(), or any other
--     existing function;
--   - change index.html, admin.html, any js/*.js file, or any Edge
--     Function other than claim-task/index.ts being updated in this
--     same step to match (no behavior change there beyond
--     documentation — the RPC's response shape and error codes are
--     unchanged, so the Edge Function's existing mapping already
--     covers this).
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
  -- 1. Validate input. Defense in depth even though the claim-task
  --    Edge Function always supplies all three (p_user_id from
  --    auth.getUser(), p_task_id validated as a UUID from the
  --    request body, p_request_id either client-supplied and
  --    UUID-validated or generated server-side) before calling this
  --    RPC.
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
  -- 2. Idempotency fast path. If this exact request_id already
  --    produced a task_claim ledger row for this user, this call is
  --    a retry of an already-committed claim — replay that result
  --    without re-verifying or re-crediting anything. Same pattern,
  --    same reasoning as level_up_mining's step 2
  --    (0031_level_up_mining.sql). Unchanged from 0037.
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
      -- Data integrity anomaly: a ledger row exists for this
      -- request_id but no matching task_claims row does. Both are
      -- always inserted together in the same transaction (step 9
      -- below), so this should be unreachable; surfaced as a clear
      -- 500 rather than silently fabricating a response.
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
  -- 3. Lock and load the task row. Locking it means a concurrent
  --    admin edit (deactivating the task, changing its reward or
  --    requirement_value via admin-task-catalog) cannot race this
  --    claim — either this transaction sees the pre-edit row and
  --    completes against it, or it waits for the admin's transaction
  --    to commit first and then sees the up-to-date row. Unchanged
  --    from 0037.
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
  -- 4. Task must be active. Unchanged from 0037.
  -- ---------------------------------------------------------------
  if not v_task.is_active then
    raise exception 'claim_task: task_id % is not active', p_task_id
      using errcode = 'PXN31';
  end if;

  -- ---------------------------------------------------------------
  -- 5. Sanity check on the catalog row's own reward value. Belt and
  --    suspenders alongside task_catalog's own
  --    `check (reward_mpxn >= 0 and reward_mpxn <= 100000000)`
  --    constraint (0035_task_catalog.sql) — this can only trigger if
  --    that constraint is ever loosened without updating this
  --    function. Unchanged from 0037.
  -- ---------------------------------------------------------------
  if v_task.reward_mpxn < 0 then
    raise exception 'claim_task: task_id % has an invalid reward_mpxn (%)', p_task_id, v_task.reward_mpxn
      using errcode = 'PXN34';
  end if;

  -- ---------------------------------------------------------------
  -- 6. Confirm the authenticated caller actually has a users row.
  --    Should always be true (p_user_id comes from a verified
  --    Supabase session — auth.uid()), so this is a data-integrity
  --    check, not a normal user-facing error path. Unchanged from
  --    0037.
  -- ---------------------------------------------------------------
  perform 1
    from public.users as u
   where u.id = p_user_id;

  if not found then
    raise exception 'claim_task: no users row for user_id %', p_user_id
      using errcode = 'PXN34';
  end if;

  -- ---------------------------------------------------------------
  -- 7. Reject if this exact (user, task) was already claimed. The
  --    UNIQUE(user_id, task_id) constraint on task_claims is the
  --    real, race-free guarantee (see step 9's insert below); this
  --    check exists to return a clean, specific error instead of a
  --    generic unique-violation for the common non-racing case.
  --    Unchanged from 0037.
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
  -- 8. Verification. THIS IS THE STEP THIS MIGRATION CHANGES.
  --
  --      - manual_claim: unchanged — no automatic verification
  --        mechanism exists (and none may be faked — tapping CLAIM is
  --        not completion), so this branch still always rejects.
  --      - referral_count / miner_level / claim_count: now load the
  --        caller's mining_state row and compare its live counter
  --        against v_task.requirement_value (task_catalog, locked in
  --        step 3 above — never client input). Falls through to step
  --        9 on success; raises PXN33 (naming the actual vs. required
  --        value) on failure. No mining_state row at all is reported
  --        as PXN25, the same code adjust_claimed_total() already
  --        uses for that condition.
  -- ---------------------------------------------------------------
  if v_task.verification_type = 'manual_claim' then
    raise exception 'claim_task: task_id % (manual_claim) has no automatic verification mechanism configured', p_task_id
      using errcode = 'PXN33';
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
    -- Unreachable given task_catalog's own check constraint on
    -- verification_type (0035_task_catalog.sql), kept as an explicit
    -- guard rather than falling through silently. Unchanged from
    -- 0037.
    raise exception 'claim_task: task_id % has an unsupported verification_type (%)', p_task_id, v_task.verification_type
      using errcode = 'PXN33';
  end if;

  -- ---------------------------------------------------------------
  -- 9. Atomic insert + credit. Reachable now for referral_count /
  --    miner_level / claim_count tasks whose requirement is met (and
  --    still never reachable for manual_claim). Unchanged from 0037:
  --    the insert happens BEFORE the credit so that a concurrent
  --    duplicate claim (two requests for the same user_id/task_id
  --    racing past step 7's check simultaneously) fails here, on
  --    task_claims' own UNIQUE(user_id, task_id) constraint, before
  --    any m.PXN is credited — never the reverse order. reward_mpxn
  --    still comes only from v_task (task_catalog) — never from the
  --    request.
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
  'Service-role-only, atomic Task Claim. Locks the target task_catalog row, rejects TASK_NOT_FOUND (PXN30) / TASK_INACTIVE (PXN31) / TASK_ALREADY_CLAIMED (PXN32), then verifies completion: manual_claim always rejects with TASK_VERIFICATION_REQUIRED (PXN33, no automatic verification mechanism exists); referral_count/miner_level/claim_count compare the caller''s mining_state counter (referral_count/level/claim_count) against task_catalog.requirement_value, rejecting with PXN33 if not met, or PXN25 if the caller has no mining_state row (0039_claim_task_requirement_verification.sql). Only if verification passes does it insert into task_claims and credit m.PXN via adjust_claimed_total() (0030_mpxn_ledger_primitive.sql), both in this same transaction — either both happen or neither does. Idempotent on (user_id, p_request_id) for a genuine network-level retry, backstopped by task_claims'' own UNIQUE(user_id, task_id) and mpxn_ledger''s unique index for the race case. Never reads or writes pxn_balance, pending_claim, or mined_balance_total. Not callable by anon/authenticated.';

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
--   - change index.html, admin.html, or any js/*.js file, or any
--     existing Edge Function other than claim-task (claim-mining,
--     purchase-miner, upgrade-miner, level-up-mining, accrue-mining,
--     set-miner-applied, marketplace, marketplace-read, auth-telegram,
--     me, admin-*, get-miner-upgrade-costs, get-mining-inventory,
--     health — all untouched);
--   - grant anon/authenticated any INSERT/UPDATE/DELETE on
--     task_claims, or any access at all to mpxn_ledger or
--     mining_state.
-- ---------------------------------------------------------------
