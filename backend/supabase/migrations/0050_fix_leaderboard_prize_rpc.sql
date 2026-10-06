-- 0050_fix_leaderboard_prize_rpc.sql
-- Fixes ambiguous ON CONFLICT references in admin_upsert_leaderboard_prize().
-- The corrected function was already applied manually in Supabase SQL Editor.

create or replace function public.admin_upsert_leaderboard_prize(
  p_admin_user_id uuid,
  p_period_id uuid,
  p_rank integer,
  p_reward_type text,
  p_reward_amount_mpxn numeric default null,
  p_miner_catalog_id uuid default null,
  p_equipment_id text default null
)
returns table(
  prize_id uuid,
  period_id uuid,
  rank integer,
  reward_type text,
  reward_amount_mpxn numeric,
  miner_catalog_id uuid,
  miner_tier integer,
  reward_name text,
  reward_icon text,
  reward_mining_speed numeric,
  equipment_id text
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_prize public.leaderboard_prizes%rowtype;
  v_catalog public.miner_catalog%rowtype;
begin
  if p_admin_user_id is null
     or p_period_id is null
     or p_rank is null
     or p_reward_type is null then
    raise exception 'admin_upsert_leaderboard_prize: required parameter missing'
      using errcode = 'PXN64';
  end if;

  if not exists (
    select 1
    from public.admin_users au
    where au.user_id = p_admin_user_id
  ) then
    raise exception 'admin_upsert_leaderboard_prize: caller is not an admin'
      using errcode = 'PXN61';
  end if;

  if p_rank < 1 or p_rank > 100 then
    raise exception 'admin_upsert_leaderboard_prize: rank must be between 1 and 100'
      using errcode = 'PXN65';
  end if;

  if not exists (
    select 1
    from public.leaderboard_periods lp
    where lp.id = p_period_id
  ) then
    raise exception 'admin_upsert_leaderboard_prize: leaderboard period not found'
      using errcode = 'PXN66';
  end if;

  if p_reward_type not in ('miner','mpxn','equipment') then
    raise exception 'admin_upsert_leaderboard_prize: unsupported reward type'
      using errcode = 'PXN67';
  end if;

  if p_reward_type = 'mpxn' then
    if p_reward_amount_mpxn is null
       or p_reward_amount_mpxn <= 0 then
      raise exception 'admin_upsert_leaderboard_prize: m.PXN reward amount must be greater than zero'
        using errcode = 'PXN68';
    end if;

    p_miner_catalog_id := null;
    p_equipment_id := null;

  elsif p_reward_type = 'miner' then
    if p_miner_catalog_id is null then
      raise exception 'admin_upsert_leaderboard_prize: miner reward requires a miner catalog entry'
        using errcode = 'PXN69';
    end if;

    select mc.*
      into v_catalog
      from public.miner_catalog mc
     where mc.id = p_miner_catalog_id;

    if not found then
      raise exception 'admin_upsert_leaderboard_prize: miner catalog entry not found'
        using errcode = 'PXN70';
    end if;

    p_reward_amount_mpxn := null;
    p_equipment_id := null;

  else
    if p_equipment_id is null
       or char_length(trim(p_equipment_id)) = 0 then
      raise exception 'admin_upsert_leaderboard_prize: equipment reward requires an equipment id'
        using errcode = 'PXN71';
    end if;

    p_reward_amount_mpxn := null;
    p_miner_catalog_id := null;
  end if;

  if exists (
    select 1
    from public.leaderboard_periods lp
    where lp.id = p_period_id
      and (
        lp.status in ('live','ended')
        or now() >= lp.start_at
      )
  ) then
    raise exception 'admin_upsert_leaderboard_prize: prizes can only be changed before the leaderboard goes live'
      using errcode = 'PXN72';
  end if;

  if p_reward_type = 'miner' then

    insert into public.leaderboard_prizes as lp (
      period_id,
      rank,
      reward_type,
      reward_amount_mpxn,
      miner_catalog_id,
      miner_tier,
      reward_name,
      reward_icon,
      reward_mining_speed,
      equipment_id
    )
    values (
      p_period_id,
      p_rank,
      'miner',
      null,
      v_catalog.id,
      v_catalog.miner_tier,
      v_catalog.miner_name,
      v_catalog.miner_icon,
      v_catalog.mining_speed,
      null
    )
    on conflict on constraint leaderboard_prizes_period_rank_key
    do update set
      reward_type = excluded.reward_type,
      reward_amount_mpxn = excluded.reward_amount_mpxn,
      miner_catalog_id = excluded.miner_catalog_id,
      miner_tier = excluded.miner_tier,
      reward_name = excluded.reward_name,
      reward_icon = excluded.reward_icon,
      reward_mining_speed = excluded.reward_mining_speed,
      equipment_id = excluded.equipment_id
    returning lp.*
    into v_prize;

  elsif p_reward_type = 'mpxn' then

    insert into public.leaderboard_prizes as lp (
      period_id,
      rank,
      reward_type,
      reward_amount_mpxn,
      miner_catalog_id,
      miner_tier,
      reward_name,
      reward_icon,
      reward_mining_speed,
      equipment_id
    )
    values (
      p_period_id,
      p_rank,
      'mpxn',
      p_reward_amount_mpxn,
      null,
      null,
      p_reward_amount_mpxn::text || ' m.PXN',
      null,
      null,
      null
    )
    on conflict on constraint leaderboard_prizes_period_rank_key
    do update set
      reward_type = excluded.reward_type,
      reward_amount_mpxn = excluded.reward_amount_mpxn,
      miner_catalog_id = null,
      miner_tier = null,
      reward_name = excluded.reward_name,
      reward_icon = null,
      reward_mining_speed = null,
      equipment_id = null
    returning lp.*
    into v_prize;

  else

    insert into public.leaderboard_prizes as lp (
      period_id,
      rank,
      reward_type,
      reward_amount_mpxn,
      miner_catalog_id,
      miner_tier,
      reward_name,
      reward_icon,
      reward_mining_speed,
      equipment_id
    )
    values (
      p_period_id,
      p_rank,
      'equipment',
      null,
      null,
      null,
      p_equipment_id,
      null,
      null,
      p_equipment_id
    )
    on conflict on constraint leaderboard_prizes_period_rank_key
    do update set
      reward_type = excluded.reward_type,
      reward_amount_mpxn = null,
      miner_catalog_id = null,
      miner_tier = null,
      reward_name = excluded.reward_name,
      reward_icon = null,
      reward_mining_speed = null,
      equipment_id = excluded.equipment_id
    returning lp.*
    into v_prize;

  end if;

  return query
  select
    v_prize.id,
    v_prize.period_id,
    v_prize.rank,
    v_prize.reward_type,
    v_prize.reward_amount_mpxn,
    v_prize.miner_catalog_id,
    v_prize.miner_tier,
    v_prize.reward_name,
    v_prize.reward_icon,
    v_prize.reward_mining_speed,
    v_prize.equipment_id;
end;
$function$;

revoke all on function public.admin_upsert_leaderboard_prize(
  uuid, uuid, integer, text, numeric, uuid, text
) from public;

revoke all on function public.admin_upsert_leaderboard_prize(
  uuid, uuid, integer, text, numeric, uuid, text
) from anon;

revoke all on function public.admin_upsert_leaderboard_prize(
  uuid, uuid, integer, text, numeric, uuid, text
) from authenticated;

grant execute on function public.admin_upsert_leaderboard_prize(
  uuid, uuid, integer, text, numeric, uuid, text
) to service_role;
