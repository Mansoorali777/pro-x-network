-- Pro-X Network — two small, independent fixes:
--
-- 1. Admin withdrawal workflow bug: admin_list_pending_withdrawals()
--    (0052, display_name added in 0054) only ever returns status =
--    'pending' rows, so the instant an admin approves a withdrawal it
--    vanishes from the only list the admin UI can fetch — there is no
--    practical way to reach the COMPLETE action. This adds a NEW,
--    additive function, admin_list_active_withdrawals(), that returns
--    BOTH 'pending' and 'approved' rows (rejected/completed withdrawals
--    are terminal and intentionally drop off — nothing left to action).
--    admin_list_pending_withdrawals() itself is left completely
--    unchanged: nothing that already calls it (if anything does)
--    breaks, and this migration does not touch 0052/0053/0054.
--
-- 2. Leaderboard self-row display name: get_current_leaderboard()'s
--    `self` object (0049, extended in 0053) only ever returned
--    {rank, points} — no name. The frontend was falling back to the
--    LOCAL PLAYER_NAME for the caller's own row when it's outside
--    top100, which is not backend-authoritative. This adds
--    display_name (and username, same fallback chain as top100) to
--    `self`, computed with the exact same
--    user_profiles.display_name -> telegram_username ->
--    telegram_first_name -> 'Player' chain top100 already uses.
--    Ranking/ordering (row_number() over (...)) is NOT touched — same
--    window, same ORDER BY, same top100 cutoff, same prizes.
--
-- Neither part changes withdrawals_paused, mpxn_to_pxn_rate, any
-- balance/refund/ledger logic, the withdrawal state machine, or
-- admin authorization (both new/changed functions independently
-- re-verify admin_users / auth.uid() exactly like the functions they
-- sit beside).

-- =====================================================================
-- 1. admin_list_active_withdrawals — pending + approved, for the admin
--    UI's single active-queue fetch. Same admin check, same shape
--    (with display_name) as admin_list_pending_withdrawals (0054).
-- =====================================================================

create or replace function public.admin_list_active_withdrawals(
  p_admin_user_id uuid
)
returns table (
  id             uuid,
  user_id        uuid,
  display_name   text,
  wallet_address text,
  wallet_network  text,
  amount_mpxn    numeric(20,8),
  amount_pxn     numeric(20,8),
  status         text,
  created_at      timestamptz
)
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
  if p_admin_user_id is null or not exists (select 1 from public.admin_users where user_id = p_admin_user_id) then
    raise exception 'admin_list_active_withdrawals: caller is not an admin'
      using errcode = 'PXN61';
  end if;

  return query
    select
      w.id, w.user_id,
      coalesce(
        nullif(up.display_name, ''),
        nullif(u.telegram_username, ''),
        nullif(u.telegram_first_name, ''),
        'Player'
      ) as display_name,
      w.wallet_address, w.wallet_network,
      w.amount_mpxn, w.amount_pxn, w.status, w.created_at
      from public.withdrawals w
      join public.users u on u.id = w.user_id
      left join public.user_profiles up on up.user_id = w.user_id
     where w.status in ('pending', 'approved')
     order by w.status asc, w.created_at asc;
end;
$$;

revoke all on function public.admin_list_active_withdrawals(uuid) from public;
revoke all on function public.admin_list_active_withdrawals(uuid) from anon;
revoke all on function public.admin_list_active_withdrawals(uuid) from authenticated;
grant execute on function public.admin_list_active_withdrawals(uuid) to service_role;

comment on function public.admin_list_active_withdrawals(uuid) is
  'service_role-only, admin-gated (identical check to admin_list_pending_withdrawals). Returns withdrawals with status pending OR approved, ordered status asc (pending before approved) then created_at asc, so an admin has one queue that covers the full pending -> approved -> complete workflow. Rejected/completed rows are terminal and are not returned. Does not alter admin_list_pending_withdrawals, which is left in place unchanged.';

-- =====================================================================
-- 2. get_current_leaderboard — add display_name/username to `self`.
--    Ranking, top100, prizes, and period/status are byte-for-byte the
--    same as 0053; only the `self` jsonb_build_object gains two keys.
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
        coalesce(
          nullif(up.display_name, ''),
          nullif(u.telegram_username, ''),
          nullif(u.telegram_first_name, ''),
          'Player'
        ) as display_name,
        ls.points
      from public.leaderboard_scores ls
      join public.users u on u.id = ls.user_id
      left join public.user_profiles up on up.user_id = ls.user_id
      where ls.period_id = v_period.id
        and ls.points > 0
    ) x
   where x.rank <= 100;

  -- Same ranking subquery/window as 0053 (unchanged: order by points
  -- desc, updated_at asc, user_id asc) — this only adds
  -- username/display_name columns onto the same rank/points already
  -- computed, exactly as top100 already does above.
  select coalesce(
    jsonb_build_object(
      'rank', x.rank,
      'points', x.points,
      'username', x.username,
      'display_name', x.display_name
    ),
    jsonb_build_object('rank', null, 'points', 0)
  )
    into v_self
    from (
      select
        row_number() over (order by ls.points desc, ls.updated_at asc, ls.user_id asc) as rank,
        ls.user_id,
        ls.points,
        coalesce(nullif(u.telegram_username, ''), nullif(u.telegram_first_name, ''), 'Player') as username,
        coalesce(
          nullif(up.display_name, ''),
          nullif(u.telegram_username, ''),
          nullif(u.telegram_first_name, ''),
          'Player'
        ) as display_name
      from public.leaderboard_scores ls
      join public.users u on u.id = ls.user_id
      left join public.user_profiles up on up.user_id = ls.user_id
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
  'Authenticated player read surface for the scheduled/live monthly leaderboard. Returns the period countdown timestamps, configured rank prizes, global top 100 (each row includes both `username` and `display_name`), and the caller''s own deterministic rank/score/display_name/username even when outside the top 100. No direct table read policy is needed.';

-- No other function/table from 0043-0054 is modified by this migration.
