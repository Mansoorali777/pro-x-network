-- Pro-X Network — Admin mining economy config control (Phase 1 of the
-- Mining Economy Control migration; see the chat audit this follows).
--
-- Adds: public.mining_config.updated_by_admin (nullable).
-- Adds: public.admin_set_mining_config(uuid, numeric, numeric, numeric,
--       numeric, numeric, numeric, integer)
--
-- Context (re-audit performed before writing this file):
--   - public.mining_config (0003_mining_config.sql) is the table
--     accrue-mining/index.ts and level-up-mining (0031_level_up_mining.sql)
--     actually read from — NOT admin.html's REWARDS panel, which only
--     ever reads/writes localStorage["proxnetwork_admin_config_v1"]
--     (admin.html: loadAdminConfig()/saveConfig(), ~lines 815-848,
--     2644-2667). Confirmed by grep: zero Edge Functions or migrations
--     write to mining_config anywhere in this codebase except the
--     single seed INSERT in 0003_mining_config.sql itself. So today,
--     an admin editing "DAILY BOOST MULTIPLIER" etc. in admin.html
--     changes nothing a player's real mining rate depends on.
--   - accrue-mining/index.ts's computeMiningRate() (confirmed by
--     reading that file in full) reads exactly these seven
--     mining_config columns and no others: base_speed,
--     referral_speed_bonus, boost_multiplier, ad_boost_multiplier,
--     level_boost_percent, max_offline_accrual_sec. level-up-mining
--     additionally reads level_up_cost_pxn (0031_level_up_mining.sql,
--     step 5). This migration makes exactly those seven columns
--     admin-editable — the ones "accrue-mining actually reads," per
--     the request — and no others.
--   - mining_config.miner_tiers, referral_instant_pxn,
--     boost_duration_min, tap_boost_multiplier, tap_boost_duration_sec,
--     ads_required_for_boost, ad_boost_duration_hours, ad_sim_seconds,
--     and pxn_swap_rate are confirmed (by grep across every
--     functions/*/index.ts) to be read by NOTHING server-side today.
--     This migration deliberately does NOT make them admin-editable
--     yet and does NOT touch them beyond carrying their existing
--     values forward unchanged on every update (see below) — that is
--     out of scope for Phase 1 per the explicit instruction not to
--     implement Daily Boost/Ad Boost/referrals/Tap Boost activation
--     yet. miner_tiers in particular is confirmed superseded by the
--     separate public.miner_catalog table (purchase-miner/
--     upgrade-miner read miner_catalog, never mining_config.miner_tiers)
--     and is explicitly out of scope per the instruction not to touch
--     the miner/miner_catalog system.
--   - public.is_current_user_admin() (0019_admin_auth_foundation.sql)
--     is the existing, only sanctioned way to check admin status, and
--     public.admin_set_mining_speed / admin_clear_mining_speed_override
--     (0020_admin_mining_speed_control.sql) is the existing pattern for
--     an admin-only config-mutating RPC: SECURITY DEFINER, explicit
--     application-level range validation ahead of table CHECK
--     constraints, REVOKEd from public/anon/authenticated, GRANTed to
--     service_role only, with the actual "is this caller an admin?"
--     decision made by the Edge Function (using the caller's own
--     bearer token) BEFORE the RPC is ever invoked — never inside the
--     RPC itself, since a service_role-issued call has no meaningful
--     auth.uid() to check. This migration follows that exact pattern.
--
-- This migration does NOT modify 0000-0040 in any way. It does NOT
-- touch mining_state, mining_inventory, miner_catalog, task_catalog,
-- task_claims, mpxn_ledger, marketplace_*, users, or admin_users. It
-- does NOT implement Daily Boost / Ad Boost activation, referrals, or
-- Tap Boost — those remain later, separate phases (each would need
-- its own migration writing to mining_state.boost_until /
-- ad_boost_until / referral_count, none of which this migration
-- touches). It creates no new Edge Function by itself — that is
-- admin-set-mining-config/index.ts, generated alongside this
-- migration but deployed separately, exactly like 0020's relationship
-- to admin-set-mining-speed/index.ts.
--
-- Design: mining_config is append-only by explicit original design
-- (0003_mining_config.sql: "Config 'changes' are modeled as inserting
-- a new row and flipping is_active, so there is always an audit
-- trail... Rows are never expected to be UPDATEd after insert"). This
-- migration honors that completely — admin_set_mining_config NEVER
-- UPDATEs any column of an existing row's config values, and NEVER
-- deletes a row. The only UPDATE it ever issues is flipping the
-- previously-active row's is_active to false (the same "deactivate,
-- then insert the new active row" mechanic the table's own design
-- comment describes), which is exactly what preserves history rather
-- than rewriting it: the old row still exists, in full, forever,
-- exactly as it was, just no longer is_active.
--
-- Partial updates: an admin call may supply any subset of the seven
-- editable values (NULL = "leave this one exactly as the current
-- active row has it"). Every other mining_config column NOT in the
-- editable set (referral_instant_pxn, boost_duration_min,
-- tap_boost_multiplier, tap_boost_duration_sec, ads_required_for_boost,
-- ad_boost_duration_hours, ad_sim_seconds, pxn_swap_rate, miner_tiers)
-- is ALWAYS carried forward verbatim from the current active row —
-- this function has no way to change them at all, by construction
-- (there is no parameter for any of them).
--
-- Attribution: mining_config.created_by references public.users(id)
-- (a PLAYER row), not auth.users(id) — see 0003_mining_config.sql. Per
-- 0019_admin_auth_foundation.sql's own identity note, an admin account
-- is anchored to auth.users(id) and "may or may not also be a player"
-- — i.e. an admin-only account can exist with NO matching
-- public.users row. Reusing created_by for the acting admin would
-- therefore risk a foreign-key violation for exactly that case. Rather
-- than leave every admin-driven config change historically
-- unattributed (created_by = null, indistinguishable from the original
-- system seed row), this migration adds one new NULLABLE column,
-- updated_by_admin, referencing auth.users(id) directly — the correct
-- identity space for an admin, mirroring admin_users.user_id's own FK
-- target. created_by is left NULL on every row this function inserts
-- (consistent with 0003's original seed row, which also used
-- created_by = null) since these rows are not player-driven; the real
-- "who changed this" answer lives in updated_by_admin.

alter table public.mining_config
  add column updated_by_admin uuid null references auth.users(id) on delete set null;

comment on column public.mining_config.updated_by_admin is
  'Which admin (auth.users.id) activated this config row via public.admin_set_mining_config — see 0041_admin_mining_config_control.sql. NULL for the original system seed row (0003_mining_config.sql) and for any row not created through that RPC. Distinct from created_by (public.users(id), a PLAYER reference) because an admin account is not guaranteed to have a matching public.users row (0019_admin_auth_foundation.sql). ON DELETE SET NULL so deleting an admin auth.users row can never be blocked by, or corrupt, historical config rows.';

-- No RLS policy is added or changed here: mining_config already has
-- RLS enabled with zero policies for anon/authenticated
-- (0003_mining_config.sql), which denies all access to those roles by
-- default regardless of which columns exist — this new column
-- inherits that same protection automatically, exactly like
-- admin_speed_override did on mining_state in 0020.

-- ---------------------------------------------------------------
-- public.admin_set_mining_config(...)
-- ---------------------------------------------------------------
-- Every numeric parameter is OPTIONAL (defaults to NULL = "leave
-- unchanged"). At least one must be provided. Ranges below are a
-- defense-in-depth duplicate of the same bounds the Edge Function
-- validates first — exactly the two-layer validation style
-- admin_set_mining_speed already uses (its own explicit range check,
-- backed by mining_state's table CHECK constraint). mining_config has
-- no per-column CHECK upper bounds today beyond ">= 0"/"> 0" (see
-- 0003_mining_config.sql), so the upper bounds enforced here are this
-- migration's own first line of defense against a fat-fingered
-- extreme value, chosen generously above any value that could ever be
-- a deliberate, reasonable game-balance choice.
create or replace function public.admin_set_mining_config(
  p_admin_user_id           uuid,
  p_base_speed              numeric default null,
  p_referral_speed_bonus    numeric default null,
  p_boost_multiplier        numeric default null,
  p_ad_boost_multiplier     numeric default null,
  p_level_boost_percent     numeric default null,
  p_level_up_cost_pxn       numeric default null,
  p_max_offline_accrual_sec integer default null
)
returns table (
  id                        uuid,
  base_speed                numeric(10,4),
  referral_instant_pxn      numeric(12,2),
  referral_speed_bonus      numeric(10,4),
  boost_multiplier          numeric(6,2),
  boost_duration_min        integer,
  tap_boost_multiplier      numeric(6,2),
  tap_boost_duration_sec    integer,
  ads_required_for_boost    integer,
  ad_boost_multiplier       numeric(6,2),
  ad_boost_duration_hours   integer,
  ad_sim_seconds            integer,
  level_up_cost_pxn         numeric(12,2),
  level_boost_percent       numeric(6,4),
  max_offline_accrual_sec   integer,
  pxn_swap_rate             numeric(10,4),
  miner_tiers               jsonb,
  is_active                 boolean,
  created_by                uuid,
  updated_by_admin          uuid,
  created_at                timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_current                  public.mining_config%rowtype;
  v_new_id                   uuid;
  v_base_speed                numeric(10,4);
  v_referral_speed_bonus      numeric(10,4);
  v_boost_multiplier          numeric(6,2);
  v_ad_boost_multiplier       numeric(6,2);
  v_level_boost_percent       numeric(6,4);
  v_level_up_cost_pxn         numeric(12,2);
  v_max_offline_accrual_sec   integer;
begin
  -- ---------------------------------------------------------------
  -- 1. Validate input.
  -- ---------------------------------------------------------------
  if p_admin_user_id is null then
    raise exception 'admin_set_mining_config: p_admin_user_id is required'
      using errcode = 'PXN47';
  end if;

  if p_base_speed is null and p_referral_speed_bonus is null
     and p_boost_multiplier is null and p_ad_boost_multiplier is null
     and p_level_boost_percent is null and p_level_up_cost_pxn is null
     and p_max_offline_accrual_sec is null then
    raise exception 'admin_set_mining_config: at least one config value must be provided'
      using errcode = 'PXN47';
  end if;

  if p_base_speed is not null
     and (p_base_speed = 'NaN'::numeric or p_base_speed < 0 or p_base_speed > 1000000) then
    raise exception 'admin_set_mining_config: base_speed % is out of range (0 to 1000000)', p_base_speed
      using errcode = 'PXN48';
  end if;

  if p_referral_speed_bonus is not null
     and (p_referral_speed_bonus = 'NaN'::numeric or p_referral_speed_bonus < 0 or p_referral_speed_bonus > 1000000) then
    raise exception 'admin_set_mining_config: referral_speed_bonus % is out of range (0 to 1000000)', p_referral_speed_bonus
      using errcode = 'PXN48';
  end if;

  if p_boost_multiplier is not null
     and (p_boost_multiplier = 'NaN'::numeric or p_boost_multiplier <= 0 or p_boost_multiplier > 1000) then
    raise exception 'admin_set_mining_config: boost_multiplier % is out of range (greater than 0, up to 1000)', p_boost_multiplier
      using errcode = 'PXN48';
  end if;

  if p_ad_boost_multiplier is not null
     and (p_ad_boost_multiplier = 'NaN'::numeric or p_ad_boost_multiplier <= 0 or p_ad_boost_multiplier > 1000) then
    raise exception 'admin_set_mining_config: ad_boost_multiplier % is out of range (greater than 0, up to 1000)', p_ad_boost_multiplier
      using errcode = 'PXN48';
  end if;

  if p_level_boost_percent is not null
     and (p_level_boost_percent = 'NaN'::numeric or p_level_boost_percent < 0 or p_level_boost_percent > 10) then
    raise exception 'admin_set_mining_config: level_boost_percent % is out of range (0 to 10)', p_level_boost_percent
      using errcode = 'PXN48';
  end if;

  if p_level_up_cost_pxn is not null
     and (p_level_up_cost_pxn = 'NaN'::numeric or p_level_up_cost_pxn < 0 or p_level_up_cost_pxn > 100000000) then
    raise exception 'admin_set_mining_config: level_up_cost_pxn % is out of range (0 to 100000000)', p_level_up_cost_pxn
      using errcode = 'PXN48';
  end if;

  if p_max_offline_accrual_sec is not null
     and (p_max_offline_accrual_sec < 60 or p_max_offline_accrual_sec > 2592000) then
    raise exception 'admin_set_mining_config: max_offline_accrual_sec % is out of range (60 to 2592000)', p_max_offline_accrual_sec
      using errcode = 'PXN48';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Lock the current active row. Locking (not just reading) means
  --    a second concurrent admin_set_mining_config call cannot read
  --    the same "current" row this call is about to deactivate — it
  --    blocks until this transaction commits, then finds is_active
  --    already false and correctly raises PXN49 ("no active row")
  --    rather than silently racing to create two active rows (the
  --    partial unique index mining_config_one_active_idx from
  --    0003_mining_config.sql is the final backstop if this logic
  --    ever had a bug, but this lock is what makes that not the
  --    normal path). Also the source of every carried-forward value
  --    below, so it must reflect the latest committed config.
  -- ---------------------------------------------------------------
  select * into v_current from public.mining_config where is_active for update;

  if not found then
    raise exception 'admin_set_mining_config: no active mining_config row found'
      using errcode = 'PXN49';
  end if;

  v_base_speed              := coalesce(p_base_speed, v_current.base_speed);
  v_referral_speed_bonus    := coalesce(p_referral_speed_bonus, v_current.referral_speed_bonus);
  v_boost_multiplier        := coalesce(p_boost_multiplier, v_current.boost_multiplier);
  v_ad_boost_multiplier     := coalesce(p_ad_boost_multiplier, v_current.ad_boost_multiplier);
  v_level_boost_percent     := coalesce(p_level_boost_percent, v_current.level_boost_percent);
  v_level_up_cost_pxn       := coalesce(p_level_up_cost_pxn, v_current.level_up_cost_pxn);
  v_max_offline_accrual_sec := coalesce(p_max_offline_accrual_sec, v_current.max_offline_accrual_sec);

  -- ---------------------------------------------------------------
  -- 3. Deactivate the old row, insert the new one. The OLD row is
  --    never updated beyond this one is_active flip, never deleted —
  --    full history preserved exactly as 0003's design intends.
  --    Every column NOT accepted as a parameter above
  --    (referral_instant_pxn, boost_duration_min, tap_boost_multiplier,
  --    tap_boost_duration_sec, ads_required_for_boost,
  --    ad_boost_duration_hours, ad_sim_seconds, pxn_swap_rate,
  --    miner_tiers) is copied verbatim from v_current — this function
  --    has no way to change any of them.
  -- ---------------------------------------------------------------
  update public.mining_config set is_active = false where id = v_current.id;

  insert into public.mining_config (
    base_speed, referral_instant_pxn, referral_speed_bonus,
    boost_multiplier, boost_duration_min,
    tap_boost_multiplier, tap_boost_duration_sec,
    ads_required_for_boost, ad_boost_multiplier, ad_boost_duration_hours,
    ad_sim_seconds, level_up_cost_pxn, level_boost_percent,
    max_offline_accrual_sec, pxn_swap_rate, miner_tiers,
    is_active, created_by, updated_by_admin
  ) values (
    v_base_speed, v_current.referral_instant_pxn, v_referral_speed_bonus,
    v_boost_multiplier, v_current.boost_duration_min,
    v_current.tap_boost_multiplier, v_current.tap_boost_duration_sec,
    v_current.ads_required_for_boost, v_ad_boost_multiplier, v_current.ad_boost_duration_hours,
    v_current.ad_sim_seconds, v_level_up_cost_pxn, v_level_boost_percent,
    v_max_offline_accrual_sec, v_current.pxn_swap_rate, v_current.miner_tiers,
    true, null, p_admin_user_id
  )
  returning id into v_new_id;

  return query
    select mc.id, mc.base_speed, mc.referral_instant_pxn, mc.referral_speed_bonus,
           mc.boost_multiplier, mc.boost_duration_min,
           mc.tap_boost_multiplier, mc.tap_boost_duration_sec,
           mc.ads_required_for_boost, mc.ad_boost_multiplier, mc.ad_boost_duration_hours,
           mc.ad_sim_seconds, mc.level_up_cost_pxn, mc.level_boost_percent,
           mc.max_offline_accrual_sec, mc.pxn_swap_rate, mc.miner_tiers,
           mc.is_active, mc.created_by, mc.updated_by_admin, mc.created_at
      from public.mining_config as mc
     where mc.id = v_new_id;
end;
$$;

comment on function public.admin_set_mining_config(uuid, numeric, numeric, numeric, numeric, numeric, numeric, integer) is
  'service_role-only. Deactivates the current active mining_config row and inserts a new active row, applying only the provided (non-NULL) values among base_speed / referral_speed_bonus / boost_multiplier / ad_boost_multiplier / level_boost_percent / level_up_cost_pxn / max_offline_accrual_sec (validated against explicit ranges) and carrying every other column forward unchanged from the row it replaces. Never touches mining_state, mining_inventory, miner_catalog, pxn_balance, or any player balance. Never deletes or edits a prior row in place — full config history is preserved via is_active. p_admin_user_id (auth.users.id) is stored as updated_by_admin for audit purposes only; caller authorization (is the acting admin actually an admin?) is verified by the admin-set-mining-config Edge Function BEFORE calling this, using the admin''s own bearer token — this function only trusts that it is being called by service_role, exactly like admin_set_mining_speed.';

revoke all on function public.admin_set_mining_config(uuid, numeric, numeric, numeric, numeric, numeric, numeric, integer) from public;
revoke all on function public.admin_set_mining_config(uuid, numeric, numeric, numeric, numeric, numeric, numeric, integer) from anon;
revoke all on function public.admin_set_mining_config(uuid, numeric, numeric, numeric, numeric, numeric, numeric, integer) from authenticated;
grant execute on function public.admin_set_mining_config(uuid, numeric, numeric, numeric, numeric, numeric, numeric, integer) to service_role;

-- No table schema other than the single new nullable column above is
-- altered by this migration. No existing migration (0000-0040) is
-- modified. No existing RLS policy, function, or grant is changed. No
-- mining_state, mining_inventory, miner_catalog, task_catalog,
-- marketplace, or admin_users row is ever read or written by
-- admin_set_mining_config.
