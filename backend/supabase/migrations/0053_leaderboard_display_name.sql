-- Pro-X Network — Leaderboard player display name.
--
-- Extends the EXISTING public.get_current_leaderboard()
-- (0049_monthly_leaderboard_foundation.sql, last replaced by
-- 0050_fix_leaderboard_prize_rpc.sql) to include a canonical
-- display_name for every top100 row, per this task's Phase 5.
--
-- Preserves every existing field and behavior of the RPC (period,
-- status, prizes, top100 rank/points, self) exactly. The only change
-- is the top100 subquery: it already computed a `username` column
-- (coalesce(telegram_username, telegram_first_name, 'Player')) — this
-- migration adds `display_name`, preferring the player's own
-- public.user_profiles.display_name (an existing, already-editable
-- profile field from 0002_users.sql) when set, falling back to the
-- exact same telegram_username -> telegram_first_name -> 'Player'
-- chain as before. `username` is left in the response unchanged (not
-- removed) so nothing that may already read it breaks; `display_name`
-- is the new, preferred field for any caller to render.
--
-- Does not change ranking (still ORDER BY points desc / updated_at
-- asc / user_id asc), does not change the top-100 cutoff, does not
-- change `self` or `prizes`, does not touch leaderboard_periods/
-- leaderboard_prizes/leaderboard_scores/leaderboard_point_events, and
-- does not modify any other function from 0049/0050.

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
  'Authenticated player read surface for the scheduled/live monthly leaderboard. Returns the period countdown timestamps, configured rank prizes, global top 100 (each row now includes both the original `username` field and the new `display_name`, which prefers public.user_profiles.display_name over the telegram_username/telegram_first_name/"Player" fallback chain), and the caller''s own deterministic rank/score even when outside the top 100. No direct table read policy is needed.';

-- No other function/table from 0043-0051 is modified by this migration.
