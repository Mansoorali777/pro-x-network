-- Pro-X Network — fix "column reference ... is ambiguous" in
-- public.admin_set_mining_config (0041_admin_mining_config_control.sql),
-- observed in production when admin-set-mining-config/index.ts calls the
-- RPC:
--
--   admin-set-mining-config RPC failed: column reference "is_active" is
--   ambiguous
--
-- ROOT CAUSE:
--   admin_set_mining_config is declared `returns table (id uuid, ...,
--   is_active boolean, ...)`. In PL/pgSQL, every column named in a
--   RETURNS TABLE clause becomes an implicit variable in the function
--   body (the same mechanism as an OUT parameter) — it is not merely a
--   description of the result shape. plpgsql's default
--   variable_conflict setting is 'error', so any BARE (unqualified)
--   column reference that shares a name with one of those implicit
--   variables is rejected at runtime with exactly this error, because
--   Postgres cannot tell whether the bare name means the table column
--   or the OUT-parameter variable.
--
--   The exact line that raised the reported error is in 0041's version
--   of the function, step 2:
--
--     select * into v_current from public.mining_config where is_active for update;
--
--   "is_active" there is unqualified, and "is_active" is also a
--   RETURNS TABLE column — hence the ambiguity.
--
--   Two more bare references in that same function have the identical
--   latent bug (both "id", also a RETURNS TABLE column) and would have
--   raised the same class of error the moment the first one was fixed,
--   so this migration fixes all three in one pass:
--     - `where id = v_current.id` in the UPDATE that deactivates the
--       old row
--     - `returning id into v_new_id` in the INSERT that creates the
--       new active row
--
-- FIX:
--   Purely a qualification fix — every previously-bare reference to a
--   column that collides with a RETURNS TABLE name is now qualified
--   with an explicit table alias (`mc`), which tells PL/pgSQL
--   unambiguously "this is the table column, not the variable". No
--   validation logic, ranges, error codes, grants, table schema, RLS,
--   or the function's signature/return shape are changed in any way —
--   this is a drop-in CREATE OR REPLACE of the exact same function
--   admin-set-mining-config/index.ts already calls, with the same
--   parameters in the same order and the same return columns in the
--   same order/types, so the Edge Function needs zero changes.
--
-- PRESERVED FROM 0041 (byte-for-byte identical except for the
-- qualification fix described above):
--   - Same function signature: admin_set_mining_config(uuid, numeric,
--     numeric, numeric, numeric, numeric, numeric, integer)
--   - Same admin-only authorization model: this function still trusts
--     only that it is being called by service_role — the actual "is
--     this caller an admin?" check still happens in
--     admin-set-mining-config/index.ts BEFORE this RPC is ever invoked,
--     using the caller's own bearer token. Nothing about that
--     architecture changes here.
--   - Still SECURITY DEFINER, still REVOKEd from public/anon/
--     authenticated, still GRANTed to service_role only.
--   - Same seven editable fields (base_speed, referral_speed_bonus,
--     boost_multiplier, ad_boost_multiplier, level_boost_percent,
--     level_up_cost_pxn, max_offline_accrual_sec) and same defense-in-
--     depth validation ranges as 0041 — not one bound changed.
--   - Same append-only design: the old active row is only ever
--     UPDATEd to flip is_active to false, never deleted; a brand-new
--     row is INSERTed and becomes the new active row. Full history
--     preserved exactly as before.
--   - updated_by_admin is still recorded on the new row from
--     p_admin_user_id; created_by is still left null on admin-driven
--     rows, exactly as 0041 designed it.
--   - Every mining_config column NOT in the editable set is still
--     carried forward verbatim from the row being replaced.
--   - No SUPABASE_JWT_SECRET, no custom JWT/JWKS — this migration adds
--     no new auth mechanism of any kind.
--
-- This migration does NOT modify 0000-0041 in any way (0041 is already
-- applied in production and is left untouched, per not editing an
-- already-applied migration). It does NOT touch mining_state,
-- mining_inventory, miner_catalog, task_catalog, task_claims,
-- mpxn_ledger, marketplace_*, users, or admin_users. It does not add,
-- drop, or alter any column — mining_config.updated_by_admin (added in
-- 0041) is untouched. It creates no new Edge Function and requires no
-- change to admin-set-mining-config/index.ts or admin.html.

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
  -- 1. Validate input. Unchanged from 0041 — same fields, same
  --    ranges, same error codes.
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
  -- 2. Lock the current active row. FIX: "mc" alias + "mc.is_active"
  --    (was the bare, ambiguous "is_active") — is_active is also a
  --    RETURNS TABLE column/implicit PL/pgSQL variable, so the
  --    unqualified name was ambiguous. Locking (not just reading)
  --    still means a second concurrent admin_set_mining_config call
  --    cannot read the same "current" row this call is about to
  --    deactivate — unchanged behavior from 0041, see that migration's
  --    own comment for the full concurrency rationale.
  -- ---------------------------------------------------------------
  select * into v_current from public.mining_config as mc where mc.is_active for update;

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
  -- 3. Deactivate the old row, insert the new one. FIX: "mc" alias
  --    added to both statements and used to qualify the two other
  --    bare references that shared this same latent ambiguity —
  --    "id" is also a RETURNS TABLE column, so `where id = ...` and
  --    `returning id into ...` were exactly as ambiguous as
  --    "is_active" was, just not yet hit in production. The OLD row
  --    is still never updated beyond this one is_active flip, never
  --    deleted — full history preserved exactly as 0041/0003 intend.
  --    Every column NOT accepted as a parameter above is still copied
  --    verbatim from v_current — unchanged from 0041.
  -- ---------------------------------------------------------------
  update public.mining_config as mc set is_active = false where mc.id = v_current.id;

  insert into public.mining_config as mc (
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
  returning mc.id into v_new_id;

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
  'service_role-only. Deactivates the current active mining_config row and inserts a new active row, applying only the provided (non-NULL) values among base_speed / referral_speed_bonus / boost_multiplier / ad_boost_multiplier / level_boost_percent / level_up_cost_pxn / max_offline_accrual_sec (validated against explicit ranges) and carrying every other column forward unchanged from the row it replaces. Never touches mining_state, mining_inventory, miner_catalog, pxn_balance, or any player balance. Never deletes or edits a prior row in place — full config history is preserved via is_active. p_admin_user_id (auth.users.id) is stored as updated_by_admin for audit purposes only; caller authorization (is the acting admin actually an admin?) is verified by the admin-set-mining-config Edge Function BEFORE calling this, using the admin''s own bearer token — this function only trusts that it is being called by service_role, exactly like admin_set_mining_speed. Fixed in 0042_fix_admin_set_mining_config_is_active_ambiguity.sql: all previously-bare column references that collided with this function''s own RETURNS TABLE column names (is_active, id) are now qualified with a table alias to remove the "column reference ... is ambiguous" PL/pgSQL error — no behavior change.';

-- Re-issued for idempotency/clarity — identical to 0041, unchanged.
revoke all on function public.admin_set_mining_config(uuid, numeric, numeric, numeric, numeric, numeric, numeric, integer) from public;
revoke all on function public.admin_set_mining_config(uuid, numeric, numeric, numeric, numeric, numeric, numeric, integer) from anon;
revoke all on function public.admin_set_mining_config(uuid, numeric, numeric, numeric, numeric, numeric, numeric, integer) from authenticated;
grant execute on function public.admin_set_mining_config(uuid, numeric, numeric, numeric, numeric, numeric, numeric, integer) to service_role;

-- No table schema is altered by this migration (no ALTER TABLE
-- statement appears anywhere above). No existing migration (0000-0041)
-- is modified. No RLS policy changes. No mining_state,
-- mining_inventory, miner_catalog, task_catalog, marketplace, or
-- admin_users row is ever read or written by admin_set_mining_config —
-- unchanged from 0041.
