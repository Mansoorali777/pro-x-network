-- Pro-X Network — Task Management backend foundation.
--
-- Table: public.task_catalog.
--
-- Context: this is the first step of a multi-step Task Management
-- feature (TASKS → EARN TASKS), following the exact same shape as
-- the earlier Miner Management foundation (see
-- 0021_miner_catalog.sql). This migration creates ONLY the
-- database-backed task catalog — schema, constraints, RLS, and a
-- seed of the 5 tasks already live in the game — so a later step can
-- build the admin CRUD Edge Function(s)/UI on top of it. This
-- migration does NOT wire anything up yet: index.html, admin.html,
-- any js/*.js file, auth-telegram, claim-mining, purchase-miner,
-- accrue-mining, adjust_claimed_total(), public.mining_state,
-- public.miner_catalog, and every other existing Edge Function are
-- all left completely untouched by this migration. In particular:
--   - index.html's DEFAULT_TASKS and adminConfig.rewards.tasksList
--     (localStorage-backed) remain exactly what the frontend actually
--     reads today. This new table does not replace them yet — that
--     is explicitly a later, separate step.
--   - No task-claim / reward-crediting logic of any kind is created
--     here. reward_mpxn is a catalog value only; nothing in this
--     migration reads or writes mining_state.claimed_total,
--     mpxn_ledger, or calls adjust_claimed_total().
--   - No public.task_claims ledger/anti-double-claim table is created
--     here — that is an explicitly later step per instructions.
--   - No Storage bucket or Storage policy is created here — task
--     icons remain out of scope for this migration; the icon column
--     below is nullable and unpopulated (NULL) for every seeded row.
--
-- Cardinality: one row per TASK (not per player-completion — a future
-- public.task_claims table, added in a later step, will hold the
-- one-row-per-(user,task) completion/idempotency record, mirroring
-- how mining_inventory is separate from miner_catalog).
--
-- Trust model: every column here will be admin/service-role-managed
-- once the write side exists. This migration deliberately creates NO
-- client write policy of any kind, per instructions — writes are
-- explicitly a later step that will use public.is_current_user_admin()
-- (see 0019_admin_auth_foundation.sql), exactly the same way
-- admin-miner-catalog already does for miner_catalog. For now:
--   - authenticated players may SELECT active (is_active = true)
--     rows only, so a future frontend can render "what tasks exist
--     right now" without exposing inactive/retired/wip catalog
--     entries.
--   - No INSERT/UPDATE/DELETE policy exists for anon or authenticated
--     — with RLS enabled and no matching policy, Postgres denies
--     those operations to those roles by default. service_role
--     bypasses RLS entirely (same pattern as every other
--     server-authoritative table in this schema) and is the only way
--     this table can be written, e.g. from the SQL editor for this
--     step, or from a future admin Edge Function (admin-task-catalog,
--     mirroring admin-miner-catalog).

create table public.task_catalog (
  id                uuid          primary key default gen_random_uuid(),

  title             text          not null
                      check (char_length(title) between 1 and 200),

  subtitle          text          not null
                      check (char_length(subtitle) between 1 and 500),

  -- Free-form icon value (Storage URL / data URI / emoji — no format
  -- is enforced at the schema level, mirroring miner_catalog.miner_icon).
  -- Nullable (unlike miner_catalog.miner_icon) because no Storage-backed
  -- task icon exists yet as of this migration — every seeded row below
  -- is NULL, and the frontend's own DEFAULT_TASKS fallback already
  -- handles a missing icon today.
  icon              text,

  -- Optional link/action the player is sent to for this task. Nullable
  -- because not every task has (or will have) an external link — e.g.
  -- referral_count / miner_level / claim_count tasks are satisfied by
  -- existing in-app state, not a URL.
  action_url        text,

  -- What kind of completion this task represents. 'manual_claim' is a
  -- player-initiated claim with no automatic verification (today's
  -- only behavior); the other three describe tasks that are actually
  -- satisfied by existing game state (referral count, miner level,
  -- claim count) rather than a link/click — mirrors the DEFAULT_TASKS
  -- ids t3/t4/t5 that index.html already auto-marks done today, made
  -- explicit and data-driven instead of hardcoded task ids.
  verification_type text          not null
                      check (verification_type in (
                        'manual_claim',
                        'referral_count',
                        'miner_level',
                        'claim_count'
                      )),

  -- m.PXN reward for completing this task. Upper bound is a sanity
  -- cap, matching miner_catalog.price_pxn's reasoning, well above any
  -- existing task reward (highest today is 150).
  reward_mpxn       numeric(20,8) not null default 0
                      check (reward_mpxn >= 0 and reward_mpxn <= 100000000),

  -- Display order on the EARN TASKS screen, ascending. A "normal
  -- integer" per instructions — bounded to a sane range as a
  -- sanity/fat-finger guard, not a real expected value (5 tasks exist
  -- today).
  sort_order        integer       not null default 0
                      check (sort_order >= 0 and sort_order <= 100000),

  -- Whether this task is currently offered/visible. Distinct from
  -- deleting the row, so a retired task's historical reward value is
  -- never lost — same reasoning as miner_catalog.is_active.
  is_active         boolean       not null default true,

  created_at        timestamptz   not null default now(),
  updated_at        timestamptz   not null default now()
);

comment on table public.task_catalog is
  'Database-backed EARN TASKS catalog: one row per task (title, subtitle, icon, action_url, verification_type, reward_mpxn, sort_order, is_active). Schema/RLS/seed only as of this migration — index.html/admin.html still read/write the localStorage-backed DEFAULT_TASKS / adminConfig.rewards.tasksList (see this file''s header). No client write policy exists yet; only service_role can write, pending a future admin-only write path (admin-task-catalog Edge Function) built on public.is_current_user_admin(). No task_claims/reward-crediting logic exists yet either — reward_mpxn is a catalog value only.';
comment on column public.task_catalog.icon is
  'Free-form icon value (Storage URL / data URI / emoji). Nullable — no Storage-backed task icon bucket exists yet (that is a later step, mirroring miner-icons for miner_catalog).';
comment on column public.task_catalog.verification_type is
  'How this task is completed: manual_claim (player taps Claim, no automatic verification), or referral_count / miner_level / claim_count (satisfied by existing game state — a later claim-task Edge Function will check the relevant player state server-side before crediting reward_mpxn).';
comment on column public.task_catalog.is_active is
  'Whether this task is currently offered. Set false to retire a task without deleting its historical row.';

-- Reuse the existing shared trigger function from 0001_helpers.sql
-- rather than redefining it here (same pattern as miner_catalog).
create trigger task_catalog_set_updated_at
  before update on public.task_catalog
  for each row execute function public.set_updated_at();

-- Lookup indexes. Expected query patterns: "give me every currently-
-- active task, in display order" (is_active, plus sort_order for
-- ordering) — the shape a future player-facing SELECT will use —
-- mirroring miner_catalog's is_active index.
create index if not exists task_catalog_is_active_idx
  on public.task_catalog (is_active);

create index if not exists task_catalog_sort_order_idx
  on public.task_catalog (sort_order);

alter table public.task_catalog enable row level security;

-- Authenticated players may read active catalog entries only. No
-- policy exists for anon (no policy = default-deny for that role
-- under RLS) and no INSERT/UPDATE/DELETE policy exists for anyone —
-- admin/service-role write access is explicitly a later step (see
-- header comment above and public.is_current_user_admin() in
-- 0019_admin_auth_foundation.sql).
drop policy if exists "task_catalog_select_active" on public.task_catalog;
create policy "task_catalog_select_active"
  on public.task_catalog
  for select
  to authenticated
  using (is_active = true);

-- ---- seed: the 5 tasks already live in the game today ----
--
-- Values copied verbatim from index.html's DEFAULT_TASKS (title,
-- subtitle/"sub", reward/reward_mpxn) so this table starts in
-- agreement with what players already see — this migration does not
-- change any reward value. icon is NULL for every row (no
-- Storage-backed task icon exists yet — see column comment above).
-- action_url is NULL for every row — DEFAULT_TASKS has no link field
-- today. verification_type is inferred from each task's existing
-- auto-complete behavior in index.html (t3 -> referrals >= 1, t4 ->
-- level >= 3, t5 -> claimCount >= 5; t1/t2 have no such behavior
-- today, so manual_claim). id is left to its default
-- (gen_random_uuid()) per instructions ("a stable UUID generated by
-- the database").
insert into public.task_catalog
  (title, subtitle, icon, action_url, verification_type, reward_mpxn, sort_order, is_active)
values
  ('Join Pro-X Network Telegram channel', 'Verify membership to claim', null, null, 'manual_claim',    80,  1, true),
  ('Follow Pro-X Network on X',           'Verify follow to claim',     null, null, 'manual_claim',    60,  2, true),
  ('Invite your first friend',            'Use your referral link',     null, null, 'referral_count', 100,  3, true),
  ('Reach Miner Level 3',                 'Upgrade your rig',           null, null, 'miner_level',     150,  4, true),
  ('Claim rewards 5 times',               'Come back and claim daily',  null, null, 'claim_count',     120,  5, true);

-- Nothing else is touched. In particular, this migration does NOT:
--   - alter miner_catalog, mining_config, mining_state, mining_inventory,
--     mpxn_ledger, or adjust_claimed_total() in any way;
--   - grant anon/authenticated any INSERT/UPDATE/DELETE on this table;
--   - create public.task_claims, any claim-task logic, or any Storage
--     bucket/policy;
--   - change index.html, admin.html, or any js/*.js file, or any
--     existing Edge Function.
