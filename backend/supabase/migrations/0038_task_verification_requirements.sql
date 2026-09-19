-- Pro-X Network — Task Verification Requirements.
--
-- Table: public.task_catalog — ADD COLUMN requirement_value.
--
-- Context: public.claim_task (0037_task_claims.sql) currently rejects
-- EVERY claim with TASK_VERIFICATION_REQUIRED, because
-- referral_count / miner_level / claim_count tasks had no
-- structured, machine-readable threshold to compare the player's
-- live mining_state counters (referral_count, level, claim_count —
-- 0013_mining_state.sql) against — only free-form English text in
-- task_catalog.title/subtitle (e.g. "Invite your first friend",
-- "Reach Miner Level 3"). This migration adds exactly that missing
-- column, so a LATER migration/step can replace claim_task's
-- unconditional "raise TASK_VERIFICATION_REQUIRED" branches for
-- referral_count/miner_level/claim_count with a real comparison —
-- see 0037_task_claims.sql's header comment for the full context.
--
-- This migration is SCHEMA + BACKFILL ONLY. It does NOT:
--   - touch public.claim_task, public.task_claims, or any other
--     function/table created by 0037_task_claims.sql — that
--     function's verification step is completely unchanged by this
--     migration and will keep rejecting every claim with
--     TASK_VERIFICATION_REQUIRED until it is explicitly updated in a
--     separate, later step to actually read this new column;
--   - create any Edge Function;
--   - modify reward_mpxn, sort_order, is_active, icon, or action_url
--     on any existing row;
--   - delete or replace any existing task_catalog row — every
--     existing row keeps its id, title, subtitle, icon, action_url,
--     verification_type, reward_mpxn, sort_order, is_active,
--     created_at exactly as-is; only requirement_value (a brand new
--     column) is populated, and updated_at advances as a normal side
--     effect of that (via the existing
--     task_catalog_set_updated_at trigger from 0035_task_catalog.sql
--     — not a new trigger);
--   - touch mining_state, mpxn_ledger, miner_catalog, mining_config,
--     mining_inventory, marketplace_*, users, or any existing
--     migration file;
--   - change index.html or admin.html.
--
-- ---------------------------------------------------------------
-- 1. Add the column.
--
-- NOT NULL DEFAULT 0 means this is safe to run against the existing
-- production database with rows already in task_catalog: Postgres
-- back-fills every existing row to 0 as part of adding the column
-- (a fast metadata-only operation for a constant default, no full
-- table rewrite/lock beyond what ALTER TABLE ADD COLUMN already
-- takes), so no existing row is ever left with a NULL
-- requirement_value, and no existing row is deleted, reordered, or
-- otherwise altered by this step.
-- ---------------------------------------------------------------

alter table public.task_catalog
  add column requirement_value integer not null default 0;

comment on column public.task_catalog.requirement_value is
  'Server-side completion threshold for referral_count / miner_level / claim_count tasks, compared against the matching public.mining_state counter (referral_count / level / claim_count) by public.claim_task once that function is updated to read it (see 0037_task_claims.sql). For referral_count: minimum mining_state.referral_count. For miner_level: minimum mining_state.level. For claim_count: minimum mining_state.claim_count. For manual_claim, this normally stays 0 and is not used for verification — manual_claim has no automatic verification mechanism and this column does not add one (see 0037_task_claims.sql''s header comment); a task is never rewarded merely because CLAIM was clicked.';

-- ---------------------------------------------------------------
-- 2. CHECK constraint: requirement_value can never be negative.
--    Added as a separate statement (rather than inline on the
--    ADD COLUMN above) purely for readability — functionally
--    identical either way, and the DEFAULT 0 above already
--    trivially satisfies it for every backfilled row.
-- ---------------------------------------------------------------

alter table public.task_catalog
  add constraint task_catalog_requirement_value_check
  check (requirement_value >= 0);

-- ---------------------------------------------------------------
-- 3. Backfill the real thresholds for the 5 tasks seeded by
--    0035_task_catalog.sql, so requirement_value actually reflects
--    what each task's own title/subtitle already describes in
--    English, instead of sitting at the generic 0 default. Matched
--    by (title, verification_type) rather than id, since id is a
--    server-generated gen_random_uuid() with no fixed value to
--    reference from this later migration.
--
--    These three values are not invented by this migration — they
--    are read directly off the existing seed data's own English
--    text (0035_task_catalog.sql: "Invite your FIRST friend",
--    "Reach Miner Level 3", "Claim rewards 5 times") and are exactly
--    the values already used, informally, by index.html's PRE-
--    task_catalog DEFAULT_TASKS auto-complete logic (referrals >= 1,
--    level >= 3, claimCount >= 5) that this whole task-catalog
--    migration series is formalizing into real, server-side data.
--    manual_claim rows (join-channel / follow-on-X) are correctly
--    left at the column default of 0 — see the column comment above.
--
--    Each UPDATE is scoped to BOTH title and verification_type, so
--    it only ever touches the specific seeded row it targets and can
--    never silently match some unrelated future task an admin later
--    creates with a similar title. If a given title/verification_type
--    combination doesn't exist (e.g. an admin already renamed or
--    deleted that seeded task via admin-task-catalog before this
--    migration ran), that UPDATE simply matches zero rows and is a
--    harmless no-op — it does not fail, and does not recreate the
--    row.
-- ---------------------------------------------------------------

update public.task_catalog
   set requirement_value = 1
 where title = 'Invite your first friend'
   and verification_type = 'referral_count';

update public.task_catalog
   set requirement_value = 3
 where title = 'Reach Miner Level 3'
   and verification_type = 'miner_level';

update public.task_catalog
   set requirement_value = 5
 where title = 'Claim rewards 5 times'
   and verification_type = 'claim_count';

-- Nothing else is touched. In particular, this migration does NOT:
--   - alter task_catalog.title, .subtitle, .icon, .action_url,
--     .verification_type, .reward_mpxn, .sort_order, .is_active,
--     .id, or .created_at on any row;
--   - delete or insert any task_catalog row;
--   - modify public.claim_task, public.task_claims,
--     public.adjust_claimed_total, public.mpxn_ledger,
--     public.mining_state, public.miner_catalog,
--     public.mining_config, public.mining_inventory, any
--     marketplace_* table/function, public.users, or any RLS policy
--     on any table;
--   - create any Edge Function, or change any existing one
--     (claim-task included — it still rejects every claim with
--     TASK_VERIFICATION_REQUIRED until a later, separate step
--     updates it to read this new column);
--   - change index.html, admin.html, or any js/*.js file.
-- ---------------------------------------------------------------
