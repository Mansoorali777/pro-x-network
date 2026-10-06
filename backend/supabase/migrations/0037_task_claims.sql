-- Pro-X Network — Server-Authoritative Task Claim.
--
-- Table:    public.task_claims
-- Function: public.claim_task(p_user_id uuid, p_task_id uuid, p_request_id uuid)
--
-- Context: index.html's Tasks screen already reads the live task
-- catalog from public.task_catalog (0035_task_catalog.sql — the
-- player-side task READ migration), but the CLAIM button still just
-- sets state.tasksDone[id] = true and adds t.reward to the player's
-- LOCAL balance — nothing server-side ever verifies the task was
-- actually completed, or prevents claiming it twice. This migration
-- closes that gap: a one-row-per-(user,task) ledger
-- (public.task_claims) plus a single atomic SECURITY DEFINER RPC
-- (public.claim_task) that is the ONLY way a task can ever be
-- rewarded — mirroring exactly how public.level_up_mining
-- (0031_level_up_mining.sql) is the only way mining_state.level can
-- be incremented, and reusing public.adjust_claimed_total
-- (0030_mpxn_ledger_primitive.sql) as the ONLY way this credits
-- m.PXN, for the same reason: one audited, atomic code path per
-- balance change, never a bespoke UPDATE.
--
-- ⚠️ IMPORTANT — READ BEFORE ASSUMING THIS UNBLOCKS CLAIMING ⚠️
-- This migration adds the full atomic claim machinery (lock, load
-- task, reject not-found/inactive/already-claimed, verify, insert
-- task_claims + credit m.PXN in one transaction), but for EVERY
-- verification_type that exists in task_catalog today, the
-- verification step itself deliberately ALWAYS rejects the claim
-- with TASK_VERIFICATION_REQUIRED (SQLSTATE PXN33). No task can
-- currently be successfully claimed through this function. This is
-- intentional, not a bug — seeing STEP 3/STEP 4 of the request this
-- migration implements:
--
--   - manual_claim: by definition has no automatic verification (the
--     player just taps a button/opens a link) and per explicit
--     instructions must NEVER be treated as "verified because the
--     frontend clicked CLAIM". No external verification integration
--     (e.g. checking real Telegram channel membership via the Bot
--     API, or an admin-approval queue) exists anywhere in this
--     codebase yet, so this function correctly has nothing to check
--     and rejects every manual_claim attempt.
--
--   - referral_count / miner_level / claim_count: mining_state DOES
--     have the live counters this function would need to check
--     (referral_count, level, claim_count — see 0013_mining_state.sql)
--     — but task_catalog (0035_task_catalog.sql) has NO column
--     recording what threshold each individual task requires (e.g.
--     "Invite your first friend" needs referral_count >= 1, "Reach
--     Miner Level 3" needs level >= 3 — today those numbers exist
--     ONLY as English text in task_catalog.title/subtitle, not as
--     structured, machine-readable data). Hardcoding "1" / "3" / "5"
--     here to match today's seed data would silently break the
--     moment an admin edits a task's title/reward via
--     admin-task-catalog without also (impossibly) editing a
--     database column that doesn't exist — exactly the "invented
--     threshold" the request explicitly says not to create. This
--     function therefore also rejects every referral_count /
--     miner_level / claim_count claim with TASK_VERIFICATION_REQUIRED
--     rather than guessing.
--
-- To make claiming actually work, a LATER migration needs to add
-- (at minimum) a structured requirement column to task_catalog —
-- e.g. `requirement_value integer` for referral_count/miner_level/
-- claim_count — and/or a real external verification mechanism for
-- manual_claim. Once that exists, only the verification step inside
-- this function needs to change (replace the unconditional "raise
-- TASK_VERIFICATION_REQUIRED" branches below with real comparisons
-- against mining_state); the surrounding lock / not-found / inactive
-- / already-claimed / atomic-insert-and-credit logic is written now
-- so that future step doesn't have to touch any of it. See this
-- repo's README for the full explanation.
--
-- Trust model: p_user_id is the claim-task Edge Function's job to
-- obtain from the caller's verified Supabase access token
-- (auth.getUser()) and pass through — never read from the request
-- body. p_task_id is client-supplied (which task to claim) but is
-- ONLY ever used to look up the task row; every field that actually
-- matters (reward_mpxn, verification_type, is_active) is read from
-- that row, never from the request. p_request_id is an opaque
-- idempotency key — see the idempotency note below — and carries no
-- reward/verification information of its own.
--
-- Idempotency: a genuine duplicate/retried claim attempt for a task
-- that was ALREADY successfully claimed (by this same user) is always
-- rejected — UNIQUE(user_id, task_id) below is the hard, permanent
-- guarantee that a task can never be rewarded twice, no matter what
-- p_request_id is or isn't supplied. p_request_id exists for a
-- narrower, different purpose: a NETWORK-LEVEL retry of the exact
-- same in-flight request (double-click, dropped response, Telegram
-- WebView retry) should not surface as an error — it should return
-- the same success payload the original call would have. This
-- function implements that the same way level_up_mining
-- (0031_level_up_mining.sql) does: it checks mpxn_ledger for a row
-- already keyed to (user_id, 'task_claim', 'task_claim_request',
-- p_request_id) before doing any work, and if found, replays the
-- already-committed result instead of re-verifying/re-crediting.
-- Since every verification path currently rejects before reaching
-- the insert/credit step (see above), this fast path is presently
-- unreachable in practice — it is written now so it is already
-- correct once verification is unblocked, exactly like the
-- insert/credit code it guards.
--
-- Concurrency: this function locks the target task_catalog row
-- (SELECT ... FOR UPDATE) so a concurrent admin edit (deactivating
-- the task, changing its reward) cannot race a claim of it, and
-- relies on adjust_claimed_total's own mining_state row lock for the
-- balance side — same layered-locking pattern as level_up_mining.
--
-- Custom SQLSTATEs used by this function (continuing the existing
-- PXN01-PXN28 sequence; PXN24-26 are adjust_claimed_total's, reused
-- here unchanged, PXN27-28 belong to level_up_mining and are not
-- used by this function):
--   PXN29 — invalid input (null p_user_id/p_task_id/p_request_id) -> 500
--           (defense in depth only — the claim-task Edge Function
--           always supplies all three; this should never actually
--           trigger from a real request)
--   PXN30 — task_id does not exist in task_catalog               -> 404
--   PXN31 — task exists but is_active = false                     -> 400
--   PXN32 — task already claimed by this user (UNIQUE(user_id,
--           task_id) backstop / fast-path check)                  -> 409
--   PXN33 — verification currently required/not possible for this
--           task's verification_type (see the explanation above —
--           this is the ONLY verification outcome this function can
--           currently produce, for every verification_type)        -> 400
--   PXN34 — auth.uid() has no matching public.users row (data
--           integrity anomaly, not a normal user error)            -> 500
--   PXN25 — no mining_state row for this user_id (reused from
--           adjust_claimed_total; currently unreachable, see above) -> 404
--   PXN24 — insufficient m.PXN (reused from adjust_claimed_total;
--           cannot actually trigger for a positive reward credit —
--           kept mapped for completeness/consistency only)         -> 400
--   PXN26 — duplicate transaction (reused from adjust_claimed_total;
--           the race-condition backstop behind PXN32/the mpxn_ledger
--           fast-path check above — currently unreachable, see
--           above)                                                 -> 409

-- ---------------------------------------------------------------
-- 1. public.task_claims — one row per successfully-claimed
--    (user, task) pair. Append-only in practice: no UPDATE/DELETE
--    policy or code path exists anywhere in this migration.
-- ---------------------------------------------------------------

create table public.task_claims (
  id                uuid          primary key default gen_random_uuid(),

  user_id           uuid          not null references public.users(id) on delete cascade,
  task_id           uuid          not null references public.task_catalog(id) on delete cascade,

  -- Reward actually credited for THIS claim, copied from
  -- task_catalog.reward_mpxn at claim time (same reasoning as
  -- mpxn_ledger.balance_after being a point-in-time snapshot, not a
  -- value recomputed later) — so a later admin edit to a task's
  -- reward_mpxn never rewrites the historical amount a player was
  -- actually paid.
  reward_mpxn       numeric(20,8) not null
                      check (reward_mpxn >= 0),

  -- Verification type in effect at claim time, copied from
  -- task_catalog.verification_type for the same historical-snapshot
  -- reason as reward_mpxn above. Uses the identical check constraint
  -- as task_catalog.verification_type (0035_task_catalog.sql) so the
  -- two can never drift out of sync on allowed values.
  verification_type text          not null
                      check (verification_type in (
                        'manual_claim',
                        'referral_count',
                        'miner_level',
                        'claim_count'
                      )),

  claimed_at        timestamptz   not null default now(),

  -- A task can be claimed by a given user AT MOST ONCE, ever. This is
  -- the single most important guarantee in this migration — see the
  -- header note above. Every other anti-double-claim mechanism
  -- (the fast-path check inside claim_task, the mpxn_ledger
  -- idempotency key) is defense-in-depth around this constraint, not
  -- a substitute for it.
  unique (user_id, task_id)
);

comment on table public.task_claims is
  'One row per successfully-claimed (user, task) pair — the permanent record that prevents a task from ever being rewarded twice (UNIQUE(user_id, task_id)). reward_mpxn/verification_type are snapshots of task_catalog at claim time, not live references. Populated ONLY by public.claim_task (SECURITY DEFINER, service_role-only) — no client INSERT/UPDATE/DELETE policy exists on this table.';
comment on column public.task_claims.reward_mpxn is
  'm.PXN actually credited for this claim, snapshotted from task_catalog.reward_mpxn at claim time — does not change if the task''s catalog reward is edited afterward.';
comment on column public.task_claims.verification_type is
  'task_catalog.verification_type as it was at claim time, snapshotted for the same reason as reward_mpxn.';

create index task_claims_user_id_idx on public.task_claims (user_id);
create index task_claims_task_id_idx on public.task_claims (task_id);

alter table public.task_claims enable row level security;

-- Authenticated players may read only their own claims (so a future
-- frontend step can show "already claimed" state from the server
-- instead of trusting local state.tasksDone). No INSERT, UPDATE, or
-- DELETE policy is created for authenticated or anon — with RLS
-- enabled and no matching policy, Postgres denies those operations to
-- those roles by default. The ONLY way a row is ever written here is
-- through public.claim_task below (SECURITY DEFINER, service_role
-- execute only), never a direct client insert.
create policy "task_claims_select_own"
  on public.task_claims
  for select
  to authenticated
  using (auth.uid() = user_id);

-- ---------------------------------------------------------------
-- 2. public.claim_task — the single atomic, service-role-only entry
--    point for claiming a task. See the extensive header comment
--    above for why every verification_type currently rejects with
--    PXN33 (TASK_VERIFICATION_REQUIRED) rather than crediting
--    anything.
-- ---------------------------------------------------------------

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
  --    (0031_level_up_mining.sql). Currently unreachable in practice
  --    (every claim rejects before ever reaching step 8 below where
  --    such a ledger row would first be created) — written now so it
  --    is already correct once verification is unblocked.
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
      -- always inserted together in the same transaction (step 8
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
  --    admin edit (deactivating the task, changing its reward via
  --    admin-task-catalog) cannot race this claim — either this
  --    transaction sees the pre-edit row and completes against it,
  --    or it waits for the admin's transaction to commit first and
  --    then sees the up-to-date row.
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
  -- 4. Task must be active.
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
  --    function.
  -- ---------------------------------------------------------------
  if v_task.reward_mpxn < 0 then
    raise exception 'claim_task: task_id % has an invalid reward_mpxn (%)', p_task_id, v_task.reward_mpxn
      using errcode = 'PXN34';
  end if;

  -- ---------------------------------------------------------------
  -- 6. Confirm the authenticated caller actually has a users row.
  --    Should always be true (p_user_id comes from a verified
  --    Supabase session — auth.uid()), so this is a data-integrity
  --    check, not a normal user-facing error path.
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
  -- 8. Verification. THIS IS THE STEP THAT CURRENTLY REJECTS EVERY
  --    CLAIM — see this migration's header comment for the full
  --    explanation of why, per verification_type:
  --
  --      - manual_claim: no automatic verification mechanism exists
  --        (and none may be faked — tapping CLAIM is not completion).
  --      - referral_count / miner_level / claim_count: mining_state
  --        has the live counters (referral_count, level, claim_count
  --        — 0013_mining_state.sql), but task_catalog has no column
  --        recording each task's required threshold, so there is
  --        nothing safe to compare those counters against.
  --
  --    Once a future migration adds what's missing (a requirement
  --    column on task_catalog, and/or a real manual_claim
  --    verification mechanism), replace the branches below with real
  --    checks against v_task and the caller's mining_state row —
  --    nothing else in this function needs to change.
  -- ---------------------------------------------------------------
  if v_task.verification_type = 'manual_claim' then
    raise exception 'claim_task: task_id % (manual_claim) has no automatic verification mechanism configured', p_task_id
      using errcode = 'PXN33';
  elsif v_task.verification_type in ('referral_count', 'miner_level', 'claim_count') then
    raise exception 'claim_task: task_id % (%) cannot be verified — task_catalog has no requirement/threshold column to compare the player''s current state against',
      p_task_id, v_task.verification_type
      using errcode = 'PXN33';
  else
    -- Unreachable given task_catalog's own check constraint on
    -- verification_type (0035_task_catalog.sql), kept as an explicit
    -- guard rather than falling through silently.
    raise exception 'claim_task: task_id % has an unsupported verification_type (%)', p_task_id, v_task.verification_type
      using errcode = 'PXN33';
  end if;

  -- ---------------------------------------------------------------
  -- 9. Atomic insert + credit. UNREACHABLE TODAY (every
  --    verification_type branch above raises first) — written now,
  --    correctly, so a future migration that unblocks verification
  --    only needs to change step 8, not this step.
  --
  --    The insert happens BEFORE the credit so that a concurrent
  --    duplicate claim (two requests for the same user_id/task_id
  --    racing past step 7's check simultaneously) fails here, on
  --    task_claims' own UNIQUE(user_id, task_id) constraint, before
  --    any m.PXN is credited — never the reverse order.
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
  'Service-role-only, atomic Task Claim. Locks the target task_catalog row, rejects TASK_NOT_FOUND (PXN30) / TASK_INACTIVE (PXN31) / TASK_ALREADY_CLAIMED (PXN32), then verifies completion — which, for every verification_type that exists today, always rejects with TASK_VERIFICATION_REQUIRED (PXN33): manual_claim has no automatic verification mechanism, and referral_count/miner_level/claim_count have no requirement/threshold column on task_catalog to check against (see this migration''s header comment). Only if verification were to pass does it insert into task_claims and credit m.PXN via adjust_claimed_total() (0030_mpxn_ledger_primitive.sql), both in this same transaction — either both happen or neither does. Idempotent on (user_id, p_request_id) for a genuine network-level retry, backstopped by task_claims'' own UNIQUE(user_id, task_id) and mpxn_ledger''s unique index for the race case. Never reads or writes pxn_balance, pending_claim, or mined_balance_total. Not callable by anon/authenticated.';

-- Postgres grants EXECUTE on newly created functions to PUBLIC by
-- default — revoke that immediately, then grant only to the role
-- Edge Functions actually run as. Same pattern as every other
-- service-role-only function in this schema.
revoke all on function public.claim_task(uuid, uuid, uuid) from public;
revoke all on function public.claim_task(uuid, uuid, uuid) from anon;
revoke all on function public.claim_task(uuid, uuid, uuid) from authenticated;
grant execute on function public.claim_task(uuid, uuid, uuid) to service_role;

-- ---------------------------------------------------------------
-- Nothing else is touched. In particular, this migration does NOT:
--   - alter task_catalog, mining_state, mpxn_ledger, miner_catalog,
--     mining_config, mining_inventory, marketplace_*, or users in
--     any way (schema, RLS, or data);
--   - modify or redefine adjust_claimed_total(), level_up_mining(),
--     is_current_user_admin(), set_updated_at(), or any other
--     existing function — claim_task calls adjust_claimed_total(),
--     it does not touch its definition;
--   - change index.html, admin.html, or any js/*.js file, or any
--     existing Edge Function (claim-mining, purchase-miner,
--     upgrade-miner, level-up-mining, accrue-mining,
--     set-miner-applied, marketplace, marketplace-read, auth-telegram,
--     me, admin-*, get-miner-upgrade-costs, get-mining-inventory,
--     health — all untouched);
--   - grant anon/authenticated any INSERT/UPDATE/DELETE on
--     task_claims, or any access at all to mpxn_ledger.
-- Nothing calls claim_task yet; the claim-task Edge Function (this
-- same step, see backend/supabase/functions/claim-task/index.ts) is
-- the first and only caller.
-- ---------------------------------------------------------------
