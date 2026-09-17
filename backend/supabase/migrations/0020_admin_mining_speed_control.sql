-- Pro-X Network — Admin mining speed control (backend foundation).
--
-- Adds: public.mining_state.admin_speed_override (nullable).
-- Adds: public.admin_set_mining_speed(uuid, numeric)
-- Adds: public.admin_clear_mining_speed_override(uuid)
--
-- Context: this is ONLY the database foundation for an admin panel
-- feature that lets an authorized admin force a specific player's
-- mining rate. It does NOT touch mining_config.base_speed (that
-- remains the shared, global default for every player who has no
-- override), does NOT touch pxn_balance, mining_inventory,
-- referrals, level, or any existing table/function/policy from
-- 0000-0019, and creates no new Edge Function by itself (that's
-- backend/supabase/functions/admin-set-mining-speed/index.ts,
-- generated alongside this migration but deployed separately).
--
-- Design: admin_speed_override is a per-player NULLABLE override
-- column on mining_state, not a direct overwrite of
-- mining_config.base_speed:
--   - NULL (the default for every existing and new row) = no
--     override; accrue-mining computes the rate exactly as it does
--     today (base_speed + applied miner speed + referral bonus, level
--     multiplier, normal/ad boosts) — see accrue-mining/index.ts,
--     updated alongside this migration to read this column.
--   - non-NULL = accrue-mining uses this value AS the player's final
--     mining rate in PXN/sec, bypassing base_speed, applied miner
--     speed, referral bonus, the level multiplier, and the normal/ad
--     boost multipliers entirely (tap boost was already excluded from
--     server-side accrual before this migration and remains so). This
--     is the "safest/simple interpretation" requested: the override
--     is fully predictable — what the admin sets is exactly what
--     accrues, every second, with nothing else compounding on top of
--     it, until cleared.
--
-- Authorization model (every requirement below is enforced by
-- Postgres/RLS/grants, never by application code):
--   - mining_state already has RLS enabled with only a SELECT-own
--     policy for `authenticated` (0013_mining_state.sql) and zero
--     INSERT/UPDATE/DELETE policies for anon/authenticated. Adding
--     this column does not add any new policy, so it inherits that
--     same protection automatically: no authenticated player — admin
--     or not — can write admin_speed_override (or any other column
--     on this table) directly via PostgREST/RLS. A player's own
--     SELECT-own policy DOES let them read their own
--     admin_speed_override value once set (needed if/when the
--     frontend ever surfaces it to the player), which is harmless —
--     it's not a secret, just their own effective rate.
--   - admin_set_mining_speed and admin_clear_mining_speed_override are
--     SECURITY DEFINER, REVOKEd from public/anon/authenticated, and
--     GRANTed to service_role only — identical grant pattern to
--     set_miner_applied (0018) and purchase_miner (0016/0017). Only
--     the admin-set-mining-speed Edge Function holds the service_role
--     key, and that function only calls these RPCs AFTER
--     independently verifying, from the caller's own bearer token via
--     auth.getUser() + public.is_current_user_admin(), that the
--     caller is an authorized admin (see that function for the
--     actual authorization check — these RPCs have no meaningful
--     auth.uid() to check against a service_role-issued call, so the
--     check necessarily happens in the Edge Function, exactly as it
--     does for every other admin-authorization decision in this
--     project since 0019_admin_auth_foundation.sql).
--   - Neither RPC touches pxn_balance, mining_inventory, referral
--     data, or miner purchase data — each does exactly one column
--     write, atomically, in a single UPDATE statement.

alter table public.mining_state
  add column admin_speed_override numeric(20,8) null;

comment on column public.mining_state.admin_speed_override is
  'Admin-set override for this player''s final mining rate (PXN/sec). NULL = no override, use the normal calculated rate (default for every row). Non-NULL = accrue-mining uses this value directly as the final rate, bypassing base_speed/applied-miner-speed/referral-bonus/level-multiplier/normal-and-ad-boosts entirely (tap boost was already excluded from server-side accrual). Written ONLY by public.admin_set_mining_speed / public.admin_clear_mining_speed_override (service_role only, see 0020_admin_mining_speed_control.sql) — never client-writable, same RLS as every other column on this table.';

-- Defense-in-depth range check, enforced independently of the RPCs'
-- own application-level validation below. 0 to 1,000,000 PXN/sec per
-- the requested "reasonable maximum ... to prevent accidental extreme
-- values". This also rejects the special Postgres numeric value NaN:
-- Postgres orders NaN as greater than every other numeric value, so
-- `admin_speed_override <= 1000000` is false for NaN, and the whole
-- OR'd condition (NULL branch aside) fails, causing a constraint
-- violation exactly as for any other out-of-range value. There is no
-- numeric "Infinity" in Postgres (unlike IEEE float) to separately
-- guard against.
alter table public.mining_state
  add constraint mining_state_admin_speed_override_range
  check (
    admin_speed_override is null
    or (admin_speed_override >= 0 and admin_speed_override <= 1000000)
  );

-- ---------------------------------------------------------------
-- public.admin_set_mining_speed(p_user_id, p_speed)
-- ---------------------------------------------------------------
create or replace function public.admin_set_mining_speed(
  p_user_id uuid,
  p_speed   numeric
)
returns table (
  user_id               uuid,
  admin_speed_override  numeric(20,8)
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id  uuid;
  v_override numeric(20,8);
begin
  if p_user_id is null then
    raise exception 'admin_set_mining_speed: p_user_id is required' using errcode = 'PXN12';
  end if;
  if p_speed is null then
    raise exception 'admin_set_mining_speed: p_speed is required' using errcode = 'PXN12';
  end if;

  -- Explicit, self-documenting validation ahead of the table CHECK
  -- constraint (which would also catch these, but a dedicated
  -- application-level errcode here lets the Edge Function map
  -- "bad speed value" to a clean 400, versus a generic constraint
  -- violation). p_speed = 'NaN'::numeric is Postgres numeric's own
  -- NaN representation — there is no numeric "Infinity" to check.
  if p_speed = 'NaN'::numeric or p_speed < 0 or p_speed > 1000000 then
    raise exception 'admin_set_mining_speed: p_speed % is out of range (0 to 1000000)', p_speed
      using errcode = 'PXN13';
  end if;

  -- Lock and confirm the target mining_state row exists before
  -- writing. Locking here (not just checking) prevents a concurrent
  -- admin_clear_mining_speed_override / accrue-mining write on the
  -- same row from interleaving unpredictably with this update.
  perform 1 from public.mining_state as ms where ms.user_id = p_user_id for update;
  if not found then
    raise exception 'admin_set_mining_speed: no mining_state row for user_id %', p_user_id
      using errcode = 'PXN14';
  end if;

  update public.mining_state as ms
     set admin_speed_override = p_speed
   where ms.user_id = p_user_id
  returning ms.user_id, ms.admin_speed_override
    into v_user_id, v_override;

  return query select v_user_id, v_override;
end;
$$;

comment on function public.admin_set_mining_speed(uuid, numeric) is
  'service_role-only. Sets mining_state.admin_speed_override for p_user_id to p_speed (validated: finite, 0 to 1000000 PXN/sec). Does not touch pxn_balance, mining_inventory, referrals, level, or purchase data. Caller authorization (is the acting admin actually an admin?) is verified by the admin-set-mining-speed Edge Function BEFORE calling this, using the admin''s own bearer token — this function only trusts that it is being called by service_role, exactly like set_miner_applied / purchase_miner.';

revoke all on function public.admin_set_mining_speed(uuid, numeric) from public;
revoke all on function public.admin_set_mining_speed(uuid, numeric) from anon;
revoke all on function public.admin_set_mining_speed(uuid, numeric) from authenticated;
grant execute on function public.admin_set_mining_speed(uuid, numeric) to service_role;

-- ---------------------------------------------------------------
-- public.admin_clear_mining_speed_override(p_user_id)
-- ---------------------------------------------------------------
create or replace function public.admin_clear_mining_speed_override(
  p_user_id uuid
)
returns table (
  user_id               uuid,
  admin_speed_override  numeric(20,8)
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id  uuid;
  v_override numeric(20,8);
begin
  if p_user_id is null then
    raise exception 'admin_clear_mining_speed_override: p_user_id is required' using errcode = 'PXN12';
  end if;

  perform 1 from public.mining_state as ms where ms.user_id = p_user_id for update;
  if not found then
    raise exception 'admin_clear_mining_speed_override: no mining_state row for user_id %', p_user_id
      using errcode = 'PXN14';
  end if;

  update public.mining_state as ms
     set admin_speed_override = null
   where ms.user_id = p_user_id
  returning ms.user_id, ms.admin_speed_override
    into v_user_id, v_override;

  return query select v_user_id, v_override;
end;
$$;

comment on function public.admin_clear_mining_speed_override(uuid) is
  'service_role-only. Clears mining_state.admin_speed_override for p_user_id back to NULL (resume normal calculated mining rate). Same authorization model as admin_set_mining_speed.';

revoke all on function public.admin_clear_mining_speed_override(uuid) from public;
revoke all on function public.admin_clear_mining_speed_override(uuid) from anon;
revoke all on function public.admin_clear_mining_speed_override(uuid) from authenticated;
grant execute on function public.admin_clear_mining_speed_override(uuid) to service_role;

-- No RLS policy is added or changed on mining_state or any other
-- table by this migration (see comment above column definition). No
-- existing migration (0000-0019) is modified.
