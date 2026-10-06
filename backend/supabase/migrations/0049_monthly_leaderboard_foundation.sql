-- Pro-X Network — Monthly Leaderboard Foundation (0049)
--
-- Adds a server-authoritative monthly leaderboard with:
--   * scheduled one-month periods
--   * rank-based prizes
--   * miner prizes backed by miner_catalog snapshots
--   * m.PXN prizes
--   * server-side activity score ledger
--   * automatic score awards for successful task claims and completed marketplace sales
--   * a safe authenticated read RPC returning prizes, top 100, and the caller's own rank
--
-- This migration intentionally does NOT modify 0048/referrals and does NOT
-- award points for ad/boost activity because this project currently has no
-- secure server-side ad-watch / daily-boost activation write path to verify.

-- =====================================================================
-- 1. LEADERBOARD PERIODS
-- =====================================================================

create table public.leaderboard_periods (
  id                  uuid        primary key default gen_random_uuid(),
  start_at            timestamptz not null,
  end_at              timestamptz not null,
  status              text        not null default 'scheduled'
                        check (status in ('scheduled','live','ended','cancelled')),
  created_by_admin_id  uuid        references auth.users(id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  check (end_at > start_at),
  check (end_at = start_at + interval '1 month')
);

comment on table public.leaderboard_periods is
  'One scheduled monthly leaderboard period. The period is exactly one calendar month from start_at; end_at is computed as start_at + interval 1 month. Players read the nearest live period or next scheduled period through get_current_leaderboard().';

create index leaderboard_periods_status_start_idx
  on public.leaderboard_periods (status, start_at);

create unique index leaderboard_periods_start_at_key
  on public.leaderboard_periods (start_at);

create trigger leaderboard_periods_set_updated_at
  before update on public.leaderboard_periods
  for each row execute function public.set_updated_at();

alter table public.leaderboard_periods enable row level security;
-- No direct client policies. Admin writes and player reads go through
-- SECURITY DEFINER RPCs / Edge Functions.

-- =====================================================================
-- 2. LEADERBOARD PRIZES
-- =====================================================================

create table public.leaderboard_prizes (
  id                    uuid        primary key default gen_random_uuid(),
  period_id             uuid        not null references public.leaderboard_periods(id) on delete cascade,
  rank                  integer     not null check (rank >= 1 and rank <= 100),
  reward_type           text        not null
                          check (reward_type in ('miner','mpxn','equipment')),

  -- m.PXN prize amount. Required only for reward_type = mpxn.
  reward_amount_mpxn    numeric(20,8),

  -- Existing/new miner catalog reference. The catalog row may later be
  -- deactivated, so the display/grant snapshot below is also stored.
  miner_catalog_id      uuid references public.miner_catalog(id) on delete set null,
  miner_tier             integer,
  reward_name            text        not null,
  reward_icon            text,
  reward_mining_speed    numeric(20,8),

  -- Equipment is reserved for the future equipment catalog. We store a
  -- stable external id/name now without pretending an equipment system
  -- already exists.
  equipment_id           text,

  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  constraint leaderboard_prizes_period_rank_key unique (period_id, rank),
  constraint leaderboard_prizes_reward_shape check (
    (reward_type = 'mpxn'
      and reward_amount_mpxn is not null
      and reward_amount_mpxn > 0
      and miner_catalog_id is null
      and equipment_id is null)
    or
    (reward_type = 'miner'
      and reward_amount_mpxn is null
      and equipment_id is null
      and miner_tier is not null
      and miner_tier >= 1)
    or
    (reward_type = 'equipment'
      and reward_amount_mpxn is null
      and miner_catalog_id is null
      and equipment_id is not null
      and char_length(equipment_id) between 1 and 200)
  )
);

comment on table public.leaderboard_prizes is
  'Rank-based prize configuration for a specific monthly leaderboard period. Miner prizes snapshot catalog name/icon/speed so a later catalog edit does not rewrite the promised prize. equipment is reserved for a future equipment system and cannot be granted by this migration yet.';

create index leaderboard_prizes_period_idx
  on public.leaderboard_prizes (period_id, rank);

create trigger leaderboard_prizes_set_updated_at
  before update on public.leaderboard_prizes
  for each row execute function public.set_updated_at();

alter table public.leaderboard_prizes enable row level security;
-- No direct client policies.

-- =====================================================================
-- 3. SERVER-AUTHORITATIVE SCORE ROWS
-- =====================================================================

create table public.leaderboard_scores (
  period_id    uuid          not null references public.leaderboard_periods(id) on delete cascade,
  user_id      uuid          not null references public.users(id) on delete cascade,
  points       numeric(20,2) not null default 0 check (points >= 0),
  created_at   timestamptz   not null default now(),
  updated_at   timestamptz   not null default now(),
  primary key (period_id, user_id)
);

comment on table public.leaderboard_scores is
  'Server-authoritative accumulated activity score for one player in one leaderboard period. Players cannot write these rows directly.';

create index leaderboard_scores_period_points_idx
  on public.leaderboard_scores (period_id, points desc, user_id);

create trigger leaderboard_scores_set_updated_at
  before update on public.leaderboard_scores
  for each row execute function public.set_updated_at();

alter table public.leaderboard_scores enable row level security;
-- No direct client policies.

-- =====================================================================
-- 4. IDEMPOTENT SCORE EVENT LEDGER
-- =====================================================================

create table public.leaderboard_point_events (
  id             uuid          primary key default gen_random_uuid(),
  period_id      uuid          not null references public.leaderboard_periods(id) on delete cascade,
  user_id        uuid          not null references public.users(id) on delete cascade,
  activity_type  text          not null check (char_length(activity_type) between 1 and 80),
  source_id      uuid          not null,
  points         numeric(20,2) not null check (points > 0),
  created_at     timestamptz   not null default now(),
  constraint leaderboard_point_events_unique_source
    unique (period_id, user_id, activity_type, source_id)
);

comment on table public.leaderboard_point_events is
  'Append-only idempotency ledger for leaderboard score awards. A successful source action can contribute points only once per player/period/activity/source combination.';

create index leaderboard_point_events_period_user_idx
  on public.leaderboard_point_events (period_id, user_id, created_at desc);

alter table public.leaderboard_point_events enable row level security;
-- No direct client policies.

-- =====================================================================
-- 5. ADMIN PERIOD CREATION / UPDATE RPC
-- =====================================================================

create or replace function public.admin_create_leaderboard_period(
  p_admin_user_id uuid,
  p_start_at      timestamptz
)
returns table (
  period_id uuid,
  start_at  timestamptz,
  end_at    timestamptz,
  status    text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_end timestamptz;
begin
  if p_admin_user_id is null or p_start_at is null then
    raise exception 'admin_create_leaderboard_period: admin_user_id and start_at are required'
      using errcode = 'PXN60';
  end if;

  if not exists (select 1 from public.admin_users where user_id = p_admin_user_id) then
    raise exception 'admin_create_leaderboard_period: caller is not an admin'
      using errcode = 'PXN61';
  end if;

  if p_start_at <= now() then
    raise exception 'admin_create_leaderboard_period: start_at must be in the future'
      using errcode = 'PXN62';
  end if;

  v_end := p_start_at + interval '1 month';

  -- Do not allow overlapping scheduled/live periods. The database remains
  -- the final guard even if two admin requests arrive concurrently.
  if exists (
    select 1
      from public.leaderboard_periods lp
     where lp.status in ('scheduled','live')
       and tstzrange(lp.start_at, lp.end_at, '[)') && tstzrange(p_start_at, v_end, '[)')
  ) then
    raise exception 'admin_create_leaderboard_period: requested period overlaps an existing scheduled/live period'
      using errcode = 'PXN63';
  end if;

  insert into public.leaderboard_periods (start_at, end_at, status, created_by_admin_id)
  values (p_start_at, v_end, 'scheduled', p_admin_user_id)
  returning id into v_id;

  return query
    select v_id, p_start_at, v_end, 'scheduled'::text;
end;
$$;

revoke all on function public.admin_create_leaderboard_period(uuid, timestamptz) from public;
revoke all on function public.admin_create_leaderboard_period(uuid, timestamptz) from anon;
revoke all on function public.admin_create_leaderboard_period(uuid, timestamptz) from authenticated;
grant execute on function public.admin_create_leaderboard_period(uuid, timestamptz) to service_role;

-- =====================================================================
-- 6. ADMIN PERIOD UPDATE / CANCEL RPCS
-- =====================================================================

create or replace function public.admin_update_leaderboard_period(
  p_admin_user_id uuid,
  p_period_id     uuid,
  p_start_at      timestamptz
)
returns table (
  period_id uuid,
  start_at  timestamptz,
  end_at    timestamptz,
  status    text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_end timestamptz;
begin
  if p_admin_user_id is null or p_period_id is null or p_start_at is null then
    raise exception 'admin_update_leaderboard_period: required parameter missing'
      using errcode = 'PXN64';
  end if;

  if not exists (select 1 from public.admin_users where user_id = p_admin_user_id) then
    raise exception 'admin_update_leaderboard_period: caller is not an admin'
      using errcode = 'PXN61';
  end if;

  v_end := p_start_at + interval '1 month';

  if p_start_at <= now() then
    raise exception 'admin_update_leaderboard_period: start_at must be in the future'
      using errcode = 'PXN62';
  end if;

  if exists (
    select 1
      from public.leaderboard_periods lp
     where lp.id = p_period_id
       and (lp.status in ('live','ended') or now() >= lp.start_at)
  ) then
    raise exception 'admin_update_leaderboard_period: a live or completed period cannot be rescheduled'
      using errcode = 'PXN72';
  end if;

  if not exists (select 1 from public.leaderboard_periods where id = p_period_id) then
    raise exception 'admin_update_leaderboard_period: leaderboard period not found'
      using errcode = 'PXN66';
  end if;

  if exists (
    select 1
      from public.leaderboard_periods lp
     where lp.id <> p_period_id
       and lp.status in ('scheduled','live')
       and tstzrange(lp.start_at, lp.end_at, '[)') && tstzrange(p_start_at, v_end, '[)')
  ) then
    raise exception 'admin_update_leaderboard_period: requested period overlaps an existing scheduled/live period'
      using errcode = 'PXN63';
  end if;

  update public.leaderboard_periods as lp
     set start_at = p_start_at,
         end_at   = v_end,
         status   = 'scheduled'
   where lp.id = p_period_id
   returning lp.id, lp.start_at, lp.end_at, lp.status
   into period_id, start_at, end_at, status;

  return next;
end;
$$;

revoke all on function public.admin_update_leaderboard_period(uuid, uuid, timestamptz) from public;
revoke all on function public.admin_update_leaderboard_period(uuid, uuid, timestamptz) from anon;
revoke all on function public.admin_update_leaderboard_period(uuid, uuid, timestamptz) from authenticated;
grant execute on function public.admin_update_leaderboard_period(uuid, uuid, timestamptz) to service_role;

create or replace function public.admin_cancel_leaderboard_period(
  p_admin_user_id uuid,
  p_period_id     uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_admin_user_id is null or p_period_id is null then
    raise exception 'admin_cancel_leaderboard_period: required parameter missing'
      using errcode = 'PXN64';
  end if;

  if not exists (select 1 from public.admin_users where user_id = p_admin_user_id) then
    raise exception 'admin_cancel_leaderboard_period: caller is not an admin'
      using errcode = 'PXN61';
  end if;

  update public.leaderboard_periods
     set status = 'cancelled'
   where id = p_period_id
     and status = 'scheduled'
     and start_at > now();

  return found;
end;
$$;

revoke all on function public.admin_cancel_leaderboard_period(uuid, uuid) from public;
revoke all on function public.admin_cancel_leaderboard_period(uuid, uuid) from anon;
revoke all on function public.admin_cancel_leaderboard_period(uuid, uuid) from authenticated;
grant execute on function public.admin_cancel_leaderboard_period(uuid, uuid) to service_role;

-- =====================================================================
-- 7. ADMIN PRIZE UPSERT RPC
-- =====================================================================

create or replace function public.admin_upsert_leaderboard_prize(
  p_admin_user_id       uuid,
  p_period_id           uuid,
  p_rank                 integer,
  p_reward_type          text,
  p_reward_amount_mpxn   numeric default null,
  p_miner_catalog_id     uuid default null,
  p_equipment_id         text default null
)
returns table (
  prize_id              uuid,
  period_id             uuid,
  rank                  integer,
  reward_type           text,
  reward_amount_mpxn    numeric(20,8),
  miner_catalog_id      uuid,
  miner_tier            integer,
  reward_name           text,
  reward_icon           text,
  reward_mining_speed  numeric(20,8),
  equipment_id          text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prize public.leaderboard_prizes%rowtype;
  v_catalog public.miner_catalog%rowtype;
begin
  if p_admin_user_id is null or p_period_id is null or p_rank is null or p_reward_type is null then
    raise exception 'admin_upsert_leaderboard_prize: required parameter missing'
      using errcode = 'PXN64';
  end if;

  if not exists (select 1 from public.admin_users where user_id = p_admin_user_id) then
    raise exception 'admin_upsert_leaderboard_prize: caller is not an admin'
      using errcode = 'PXN61';
  end if;

  if p_rank < 1 or p_rank > 100 then
    raise exception 'admin_upsert_leaderboard_prize: rank must be between 1 and 100'
      using errcode = 'PXN65';
  end if;

  if not exists (select 1 from public.leaderboard_periods where id = p_period_id) then
    raise exception 'admin_upsert_leaderboard_prize: leaderboard period not found'
      using errcode = 'PXN66';
  end if;

  if p_reward_type not in ('miner','mpxn','equipment') then
    raise exception 'admin_upsert_leaderboard_prize: unsupported reward type'
      using errcode = 'PXN67';
  end if;

  if p_reward_type = 'mpxn' then
    if p_reward_amount_mpxn is null or p_reward_amount_mpxn <= 0 then
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

    select * into v_catalog
      from public.miner_catalog
     where id = p_miner_catalog_id;

    if not found then
      raise exception 'admin_upsert_leaderboard_prize: miner catalog entry not found'
        using errcode = 'PXN70';
    end if;

    p_reward_amount_mpxn := null;
    p_equipment_id := null;
  else
    if p_equipment_id is null or char_length(trim(p_equipment_id)) = 0 then
      raise exception 'admin_upsert_leaderboard_prize: equipment reward requires an equipment id'
        using errcode = 'PXN71';
    end if;
    p_reward_amount_mpxn := null;
    p_miner_catalog_id := null;
  end if;

  if exists (
    select 1 from public.leaderboard_periods
     where id = p_period_id and (status in ('live','ended') or now() >= start_at)
  ) then
    raise exception 'admin_upsert_leaderboard_prize: prizes can only be changed before the leaderboard goes live'
      using errcode = 'PXN72';
  end if;

  if p_reward_type = 'miner' then
    insert into public.leaderboard_prizes (
      period_id, rank, reward_type, reward_amount_mpxn,
      miner_catalog_id, miner_tier, reward_name, reward_icon, reward_mining_speed, equipment_id
    ) values (
      p_period_id, p_rank, 'miner', null,
      v_catalog.id, v_catalog.miner_tier, v_catalog.miner_name, v_catalog.miner_icon, v_catalog.mining_speed, null
    )
    on conflict (period_id, rank) do update set
      reward_type = excluded.reward_type,
      reward_amount_mpxn = excluded.reward_amount_mpxn,
      miner_catalog_id = excluded.miner_catalog_id,
      miner_tier = excluded.miner_tier,
      reward_name = excluded.reward_name,
      reward_icon = excluded.reward_icon,
      reward_mining_speed = excluded.reward_mining_speed,
      equipment_id = excluded.equipment_id
    returning * into v_prize;
  elsif p_reward_type = 'mpxn' then
    insert into public.leaderboard_prizes (
      period_id, rank, reward_type, reward_amount_mpxn,
      miner_catalog_id, miner_tier, reward_name, reward_icon, reward_mining_speed, equipment_id
    ) values (
      p_period_id, p_rank, 'mpxn', p_reward_amount_mpxn,
      null, null, p_reward_amount_mpxn::text || ' m.PXN', null, null, null
    )
    on conflict (period_id, rank) do update set
      reward_type = excluded.reward_type,
      reward_amount_mpxn = excluded.reward_amount_mpxn,
      miner_catalog_id = null,
      miner_tier = null,
      reward_name = excluded.reward_name,
      reward_icon = null,
      reward_mining_speed = null,
      equipment_id = null
    returning * into v_prize;
  else
    insert into public.leaderboard_prizes (
      period_id, rank, reward_type, reward_amount_mpxn,
      miner_catalog_id, miner_tier, reward_name, reward_icon, reward_mining_speed, equipment_id
    ) values (
      p_period_id, p_rank, 'equipment', null,
      null, null, p_equipment_id, null, null, p_equipment_id
    )
    on conflict (period_id, rank) do update set
      reward_type = excluded.reward_type,
      reward_amount_mpxn = null,
      miner_catalog_id = null,
      miner_tier = null,
      reward_name = excluded.reward_name,
      reward_icon = null,
      reward_mining_speed = null,
      equipment_id = excluded.equipment_id
    returning * into v_prize;
  end if;

  return query select
    v_prize.id, v_prize.period_id, v_prize.rank, v_prize.reward_type,
    v_prize.reward_amount_mpxn, v_prize.miner_catalog_id, v_prize.miner_tier,
    v_prize.reward_name, v_prize.reward_icon, v_prize.reward_mining_speed,
    v_prize.equipment_id;
end;
$$;

revoke all on function public.admin_upsert_leaderboard_prize(uuid, uuid, integer, text, numeric, uuid, text) from public;
revoke all on function public.admin_upsert_leaderboard_prize(uuid, uuid, integer, text, numeric, uuid, text) from anon;
revoke all on function public.admin_upsert_leaderboard_prize(uuid, uuid, integer, text, numeric, uuid, text) from authenticated;
grant execute on function public.admin_upsert_leaderboard_prize(uuid, uuid, integer, text, numeric, uuid, text) to service_role;

-- =====================================================================
-- 7. SERVER SCORE AWARD FUNCTION
-- =====================================================================

create or replace function public.award_leaderboard_points(
  p_period_id      uuid,
  p_user_id        uuid,
  p_activity_type  text,
  p_source_id      uuid,
  p_points         numeric
)
returns numeric(20,2)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_new_points numeric(20,2);
  v_start timestamptz;
  v_end timestamptz;
begin
  if p_period_id is null or p_user_id is null or p_activity_type is null or p_source_id is null then
    raise exception 'award_leaderboard_points: required parameter missing'
      using errcode = 'PXN73';
  end if;

  if p_points <= 0 or p_points > 1000000 then
    raise exception 'award_leaderboard_points: points out of range'
      using errcode = 'PXN74';
  end if;

  select start_at, end_at into v_start, v_end
    from public.leaderboard_periods
   where id = p_period_id
     and status in ('scheduled','live')
     and now() >= start_at
     and now() < end_at;

  if not found then
    return 0;
  end if;

  -- Make the period state self-healing when the first activity arrives.
  update public.leaderboard_periods
     set status = 'live'
   where id = p_period_id
     and status = 'scheduled';

  -- Insert the idempotency event first. If the same source event is retried,
  -- the unique constraint makes it a no-op.
  insert into public.leaderboard_point_events (
    period_id, user_id, activity_type, source_id, points
  ) values (
    p_period_id, p_user_id, p_activity_type, p_source_id, p_points
  )
  on conflict (period_id, user_id, activity_type, source_id) do nothing;

  if not found then
    return coalesce((select points from public.leaderboard_scores where period_id = p_period_id and user_id = p_user_id), 0)::numeric(20,2);
  end if;

  insert into public.leaderboard_scores (period_id, user_id, points)
  values (p_period_id, p_user_id, p_points)
  on conflict (period_id, user_id) do update
    set points = public.leaderboard_scores.points + excluded.points;

  select points into v_new_points
    from public.leaderboard_scores
   where period_id = p_period_id and user_id = p_user_id;

  return v_new_points;
end;
$$;

revoke all on function public.award_leaderboard_points(uuid, uuid, text, uuid, numeric) from public;
revoke all on function public.award_leaderboard_points(uuid, uuid, text, uuid, numeric) from anon;
revoke all on function public.award_leaderboard_points(uuid, uuid, text, uuid, numeric) from authenticated;
grant execute on function public.award_leaderboard_points(uuid, uuid, text, uuid, numeric) to service_role;

-- =====================================================================
-- 8. AUTOMATIC PERIOD STATUS + POINT AWARD TRIGGERS
-- =====================================================================

create or replace function public.refresh_leaderboard_period_status()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.leaderboard_periods
     set status = 'ended'
   where status in ('scheduled','live')
     and end_at <= now();

  update public.leaderboard_periods
     set status = 'live'
   where status = 'scheduled'
     and start_at <= now()
     and end_at > now();
end;
$$;

revoke all on function public.refresh_leaderboard_period_status() from public;
revoke all on function public.refresh_leaderboard_period_status() from anon;
revoke all on function public.refresh_leaderboard_period_status() from authenticated;
grant execute on function public.refresh_leaderboard_period_status() to service_role;

create or replace function public.get_live_or_next_leaderboard_period()
returns public.leaderboard_periods
language plpgsql
security definer
volatile
set search_path = public, pg_temp
as $$
declare
  v_period public.leaderboard_periods%rowtype;
begin
  perform public.refresh_leaderboard_period_status();

  select * into v_period
    from public.leaderboard_periods
   where status = 'live'
   order by start_at desc
   limit 1;

  if found then return v_period; end if;

  select * into v_period
    from public.leaderboard_periods
   where status = 'scheduled'
     and start_at > now()
   order by start_at asc
   limit 1;

  return v_period;
end;
$$;

revoke all on function public.get_live_or_next_leaderboard_period() from public;
revoke all on function public.get_live_or_next_leaderboard_period() from anon;
grant execute on function public.get_live_or_next_leaderboard_period() to authenticated;

-- Task claim => +1 point, exactly once.
create or replace function public.leaderboard_on_task_claim()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_period public.leaderboard_periods%rowtype;
begin
  select * into v_period
    from public.leaderboard_periods
   where status in ('scheduled','live')
     and now() >= start_at
     and now() < end_at
   order by start_at desc
   limit 1;

  if found then
    perform public.award_leaderboard_points(v_period.id, new.user_id, 'task_claim', new.id, 1);
  end if;

  return new;
end;
$$;

create trigger task_claims_award_leaderboard_points
  after insert on public.task_claims
  for each row execute function public.leaderboard_on_task_claim();

-- Completed marketplace sale => +50 to buyer and +50 to seller, exactly once.
create or replace function public.leaderboard_on_marketplace_sale()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_period public.leaderboard_periods%rowtype;
begin
  if old.status is distinct from 'sold' and new.status = 'sold' and new.buyer_user_id is not null then
    select * into v_period
      from public.leaderboard_periods
     where status in ('scheduled','live')
       and now() >= start_at
       and now() < end_at
     order by start_at desc
     limit 1;

    if found then
      perform public.award_leaderboard_points(v_period.id, new.buyer_user_id, 'marketplace_trade_buyer', new.id, 50);
      perform public.award_leaderboard_points(v_period.id, new.seller_user_id, 'marketplace_trade_seller', new.id, 50);
    end if;
  end if;

  return new;
end;
$$;

create trigger marketplace_listings_award_leaderboard_points
  after update of status on public.marketplace_listings
  for each row execute function public.leaderboard_on_marketplace_sale();

-- =====================================================================
-- 9. PLAYER READ RPC — TOP 100 + OWN RANK + PRIZES
-- =====================================================================

create or replace function public.get_current_leaderboard()
returns jsonb
language plpgsql
security definer
volatile
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_period public.leaderboard_periods%rowtype;
  v_top100 jsonb;
  v_self jsonb;
  v_prizes jsonb;
begin
  if v_user_id is null then
    raise exception 'get_current_leaderboard: authentication required'
      using errcode = 'PXN75';
  end if;

  v_period := public.get_live_or_next_leaderboard_period();

  if v_period.id is null then
    return jsonb_build_object(
      'period', null,
      'status', 'none',
      'prizes', '[]'::jsonb,
      'top100', '[]'::jsonb,
      'self', jsonb_build_object('rank', null, 'points', 0)
    );
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.rank), '[]'::jsonb)
    into v_top100
    from (
      select
        row_number() over (order by ls.points desc, ls.updated_at asc, ls.user_id asc) as rank,
        ls.user_id,
        coalesce(nullif(u.telegram_username, ''), nullif(u.telegram_first_name, ''), 'Player') as username,
        ls.points
      from public.leaderboard_scores ls
      join public.users u on u.id = ls.user_id
      where ls.period_id = v_period.id
        and ls.points > 0
    ) x
   where x.rank <= 100;

  select coalesce(
    jsonb_build_object('rank', x.rank, 'points', x.points),
    jsonb_build_object('rank', null, 'points', 0)
  )
    into v_self
    from (
      select
        row_number() over (order by ls.points desc, ls.updated_at asc, ls.user_id asc) as rank,
        ls.user_id,
        ls.points
      from public.leaderboard_scores ls
      where ls.period_id = v_period.id
        and ls.points > 0
    ) x
   where x.user_id = v_user_id;

  select coalesce(jsonb_agg(to_jsonb(lp) order by lp.rank), '[]'::jsonb)
    into v_prizes
    from (
      select
        rank,
        reward_type,
        reward_amount_mpxn,
        miner_catalog_id,
        miner_tier,
        reward_name,
        reward_icon,
        reward_mining_speed,
        equipment_id
      from public.leaderboard_prizes
      where period_id = v_period.id
    ) lp;

  return jsonb_build_object(
    'period', jsonb_build_object(
      'id', v_period.id,
      'start_at', v_period.start_at,
      'end_at', v_period.end_at,
      'status', v_period.status
    ),
    'status', v_period.status,
    'prizes', v_prizes,
    'top100', v_top100,
    'self', coalesce(v_self, jsonb_build_object('rank', null, 'points', 0))
  );
end;
$$;

revoke all on function public.get_current_leaderboard() from public;
revoke all on function public.get_current_leaderboard() from anon;
grant execute on function public.get_current_leaderboard() to authenticated;

comment on function public.get_current_leaderboard() is
  'Authenticated player read surface for the scheduled/live monthly leaderboard. Returns the period countdown timestamps, configured rank prizes, global top 100, and the caller''s own deterministic rank/score even when outside the top 100. No direct table read policy is needed.';

-- =====================================================================
-- 10. OPTIONAL ADMIN READ RPC
-- =====================================================================

create or replace function public.admin_get_leaderboard_periods(
  p_admin_user_id uuid
)
returns table (
  id         uuid,
  start_at   timestamptz,
  end_at     timestamptz,
  status     text,
  created_at timestamptz
)
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
  if p_admin_user_id is null or not exists (select 1 from public.admin_users where user_id = p_admin_user_id) then
    raise exception 'admin_get_leaderboard_periods: caller is not an admin'
      using errcode = 'PXN61';
  end if;

  return query
    select lp.id, lp.start_at, lp.end_at, lp.status, lp.created_at
      from public.leaderboard_periods lp
     order by lp.start_at desc;
end;
$$;

revoke all on function public.admin_get_leaderboard_periods(uuid) from public;
revoke all on function public.admin_get_leaderboard_periods(uuid) from anon;
revoke all on function public.admin_get_leaderboard_periods(uuid) from authenticated;
grant execute on function public.admin_get_leaderboard_periods(uuid) to service_role;

-- =====================================================================
-- 11. GRANTS / SAFETY
-- =====================================================================

revoke all on table public.leaderboard_periods from anon, authenticated;
revoke all on table public.leaderboard_prizes from anon, authenticated;
revoke all on table public.leaderboard_scores from anon, authenticated;
revoke all on table public.leaderboard_point_events from anon, authenticated;

-- No existing migration/function/table is replaced here. 0048 remains intact.
