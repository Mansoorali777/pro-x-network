-- Pro-X Network — Secure miner apply/remove.
--
-- Function: public.set_miner_applied(p_user_id uuid, p_inventory_id uuid, p_is_applied boolean).
--
-- Context: 0014_mining_inventory.sql created mining_inventory with an
-- is_applied column but deferred the write path ("Whatever 'only N
-- slots applied at once' rule ... is enforced by the server-side
-- write path, not by a constraint in this migration"). This
-- migration is that write path. It does NOT modify mining_config,
-- mining_state, or mining_inventory (no ALTER TABLE of any kind),
-- does NOT touch purchase_miner, adjust_pxn_balance, accrue-mining,
-- auth-telegram, me, get-mining-inventory, or PLAYER_ID, does NOT
-- delete any inventory row, does NOT change pxn_balance or any
-- mining balance, and does NOT create a custom JWT/JWKS/private-JWK
-- system or reference SUPABASE_JWT_SECRET / PXN_JWT_SECRET.
--
-- Trust model: p_user_id, p_inventory_id, and p_is_applied are the
-- ONLY inputs. p_user_id is never trusted as a client-authenticated
-- identity by this function in isolation — it is the (future)
-- Edge Function's job to obtain it from the caller's verified
-- Supabase access token (auth.uid() at the PostgREST layer /
-- decoded JWT `sub` at the Edge Function layer) and pass it through,
-- never to read it from the request body. This RPC additionally
-- enforces ownership itself (every read/lock/update below is scoped
-- to `user_id = p_user_id`), so even a caller who somehow supplied a
-- mismatched p_user_id can never touch another player's row — belt
-- and suspenders, matching the pattern already used by
-- purchase_miner (0016/0017).
--
-- Slot rule (per this step's spec, driven by mining_state.level —
-- the player's Mining Level — NOT mining_inventory.miner_level,
-- which is the unrelated per-unit level of an individual owned
-- miner):
--   level 1  .. 4  => max 1 applied miner
--   level 5  .. 14 => max 2 applied miners
--   level 15 +     => max 3 applied miners
-- Enforced entirely server-side in this function; never trusts a
-- client-supplied slot count or applied flag beyond the boolean
-- p_is_applied intent itself.
--
-- Concurrency: the player's mining_state row is locked (SELECT ...
-- FOR UPDATE) before the applied-count is read, for the entire
-- remainder of the transaction. Every concurrent set_miner_applied
-- call for the same p_user_id therefore serializes behind that lock
-- — two simultaneous "apply" calls can never both read the same
-- "count = max_slots - 1" snapshot and both succeed, oversubscribing
-- the slot limit. The target mining_inventory row is separately
-- locked (SELECT ... FOR UPDATE) to serialize concurrent
-- apply/remove calls against that specific unit.
--
-- Custom SQLSTATEs (5-char, distinguishable by the calling Edge
-- Function so it can return the right HTTP status without parsing
-- error text):
--   PXN06 — invalid input (null p_user_id / p_inventory_id /
--           p_is_applied)                                 -> 400
--   PXN07 — no mining_state row exists for this user yet   -> 404
--   PXN08 — inventory item not found, or does not belong to
--           p_user_id                                      -> 404
--   PXN09 — miner is already applied                        -> 409
--   PXN10 — miner is already removed (not applied)           -> 409
--   PXN11 — applied slots full for the player's current
--           Mining Level                                    -> 400

create or replace function public.set_miner_applied(
  p_user_id       uuid,
  p_inventory_id  uuid,
  p_is_applied    boolean
)
returns table (
  id            uuid,
  user_id       uuid,
  miner_tier    integer,
  miner_name    text,
  miner_icon    text,
  miner_level   integer,
  miner_speed   numeric(20,8),
  is_applied    boolean,
  created_at    timestamptz,
  updated_at    timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_level          integer;
  v_max_slots      integer;
  v_applied_count  integer;
  v_current        boolean;
begin
  -- ---------------------------------------------------------------
  -- 1. Validate inputs. Never trust the shape of any parameter —
  --    this is a defense-in-depth check even though the (future)
  --    Edge Function also validates before calling this RPC.
  -- ---------------------------------------------------------------
  if p_user_id is null then
    raise exception 'set_miner_applied: p_user_id is required'
      using errcode = 'PXN06';
  end if;

  if p_inventory_id is null then
    raise exception 'set_miner_applied: p_inventory_id is required'
      using errcode = 'PXN06';
  end if;

  if p_is_applied is null then
    raise exception 'set_miner_applied: p_is_applied is required'
      using errcode = 'PXN06';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Lock the player's mining_state row and read their Mining
  --    Level. This lock is held for the rest of the transaction, so
  --    every concurrent set_miner_applied call for this same
  --    p_user_id queues behind this one rather than racing it —
  --    the same pattern purchase_miner (0016/0017) uses to guard
  --    pxn_balance.
  -- ---------------------------------------------------------------
  select ms.level
    into v_level
    from public.mining_state as ms
   where ms.user_id = p_user_id
     for update;

  if not found then
    raise exception 'set_miner_applied: no mining_state row for user_id %', p_user_id
      using errcode = 'PXN07';
  end if;

  -- ---------------------------------------------------------------
  -- 3. Lock the target inventory row, scoped to p_user_id so a
  --    mismatched/foreign inventory id can never be locked or
  --    touched, regardless of what p_user_id was passed.
  -- ---------------------------------------------------------------
  select mi.is_applied
    into v_current
    from public.mining_inventory as mi
   where mi.id = p_inventory_id
     and mi.user_id = p_user_id
     for update;

  if not found then
    raise exception 'set_miner_applied: inventory item % not found for user_id %', p_inventory_id, p_user_id
      using errcode = 'PXN08';
  end if;

  -- ---------------------------------------------------------------
  -- 4a. Applying a miner.
  -- ---------------------------------------------------------------
  if p_is_applied then

    if v_current then
      raise exception 'set_miner_applied: inventory item % is already applied', p_inventory_id
        using errcode = 'PXN09';
    end if;

    -- Player Mining Level -> max applied slots. Driven solely by
    -- mining_state.level (the player's Mining Level), never by
    -- mining_inventory.miner_level (the per-unit miner level) and
    -- never by any client-supplied slot count.
    v_max_slots := case
      when v_level >= 15 then 3
      when v_level >= 5  then 2
      else 1
    end;

    select count(*)
      into v_applied_count
      from public.mining_inventory as mi
     where mi.user_id = p_user_id
       and mi.is_applied;

    if v_applied_count >= v_max_slots then
      raise exception 'set_miner_applied: applied slots full for user_id % (level %, max %, applied %)',
        p_user_id, v_level, v_max_slots, v_applied_count
        using errcode = 'PXN11';
    end if;

    update public.mining_inventory as mi
       set is_applied = true
     where mi.id = p_inventory_id
       and mi.user_id = p_user_id;

  -- ---------------------------------------------------------------
  -- 4b. Removing a miner.
  -- ---------------------------------------------------------------
  else

    if not v_current then
      raise exception 'set_miner_applied: inventory item % is already removed', p_inventory_id
        using errcode = 'PXN10';
    end if;

    update public.mining_inventory as mi
       set is_applied = false
     where mi.id = p_inventory_id
       and mi.user_id = p_user_id;

  end if;

  -- ---------------------------------------------------------------
  -- 5. Return the updated row. No inventory row is ever deleted, no
  --    pxn_balance/mining balance column is read or written here.
  -- ---------------------------------------------------------------
  return query
    select
      mi.id,
      mi.user_id,
      mi.miner_tier,
      mi.miner_name,
      mi.miner_icon,
      mi.miner_level,
      mi.miner_speed,
      mi.is_applied,
      mi.created_at,
      mi.updated_at
      from public.mining_inventory as mi
     where mi.id = p_inventory_id
       and mi.user_id = p_user_id;
end;
$$;

comment on function public.set_miner_applied(uuid, uuid, boolean) is
  'Service-role-only apply/remove of an owned miner unit. Verifies the inventory row belongs to p_user_id, and when applying, enforces the player''s max-applied-slots limit derived from mining_state.level (1-4 => 1 slot, 5-14 => 2 slots, 15+ => 3 slots) entirely server-side. Locks the player''s mining_state row and the target mining_inventory row to prevent concurrent apply/remove races. Never deletes rows, never touches pxn_balance or any mining balance. Not callable by anon/authenticated.';

-- Postgres grants EXECUTE on newly created functions to PUBLIC by
-- default — revoke that immediately, then grant only to the role
-- Edge Functions actually run as. Same pattern as
-- 0015_pxn_balance_security.sql / 0016_secure_miner_purchase.sql.
revoke all on function public.set_miner_applied(uuid, uuid, boolean) from public;
revoke all on function public.set_miner_applied(uuid, uuid, boolean) from anon;
revoke all on function public.set_miner_applied(uuid, uuid, boolean) from authenticated;
grant execute on function public.set_miner_applied(uuid, uuid, boolean) to service_role;

-- No table schema (mining_config, mining_state, mining_inventory) is
-- altered by this migration. No RLS policy is added, removed, or
-- modified. No existing function (purchase_miner,
-- adjust_pxn_balance, set_updated_at) is touched. No new Edge
-- Function, frontend file, or grant to anon/authenticated is
-- introduced.
