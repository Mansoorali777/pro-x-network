-- Pro-X Network — timed mining sessions.
--
-- Adds mining_session_started_at / mining_session_ends_at to
-- mining_state and public.start_mining_session(p_user_id), an
-- 8-hour session starter. This migration only adds columns/a
-- function; it does not alter accrue-mining's SQL (there is none —
-- accrue-mining computes and writes via plain .update() calls from
-- the Edge Function itself, updated separately in
-- supabase/functions/accrue-mining/index.ts to require an active
-- session — see that file's comments) and does not touch any other
-- RPC, table, or RLS policy.
--
-- Session semantics (enforced in accrue-mining/index.ts, not here):
-- accrual only counts time that falls within
-- [mining_session_started_at, mining_session_ends_at]. Once
-- mining_session_ends_at has passed, accrual is 0 until the player
-- calls start_mining_session again (which moves both timestamps
-- forward and resets last_accrued_at to the new session's start).

alter table public.mining_state
  add column if not exists mining_session_started_at timestamptz,
  add column if not exists mining_session_ends_at timestamptz;

comment on column public.mining_state.mining_session_started_at is
  'When the player''s current (or most recent) 8-hour mining session began. Null until they call start_mining_session() for the first time. Read (never written) by accrue-mining to gate accrual to the session window.';
comment on column public.mining_state.mining_session_ends_at is
  'mining_session_started_at + 8 hours, set by start_mining_session(). Once now() passes this, accrue-mining accrues 0 until a new session is started. Null until the first session.';

create or replace function public.start_mining_session(p_user_id uuid)
returns table (
  session_started_at timestamptz,
  session_ends_at    timestamptz,
  level              integer,
  claimed_total      numeric(20,8),
  pending_claim      numeric(20,8)
)
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_now      timestamptz := now();
  v_duration constant interval := interval '8 hours';
  v_state    public.mining_state%rowtype;
begin
  if p_user_id is null then
    raise exception 'start_mining_session: p_user_id is required' using errcode = 'PXN90';
  end if;
  select * into v_state from public.mining_state where user_id = p_user_id for update;
  if not found then
    raise exception 'start_mining_session: no mining_state row for user_id %', p_user_id using errcode = 'PXN91';
  end if;
  update public.mining_state
     set mining_session_started_at = v_now,
         mining_session_ends_at     = v_now + v_duration,
         last_accrued_at            = v_now,
         updated_at                 = v_now
   where user_id = p_user_id;
  return query
    select v_now, v_now + v_duration,
           v_state.level, v_state.claimed_total, v_state.pending_claim;
end;
$$;

revoke all on function public.start_mining_session(uuid) from public;
revoke all on function public.start_mining_session(uuid) from anon;
revoke all on function public.start_mining_session(uuid) from authenticated;
grant execute on function public.start_mining_session(uuid) to service_role;

comment on function public.start_mining_session(uuid) is
  'service_role-only (called from supabase/functions/start-mining-session/index.ts using the caller''s own auth.uid()). Starts (or restarts) an 8-hour mining session for p_user_id: sets mining_session_started_at = now(), mining_session_ends_at = now() + 8h, and resets last_accrued_at = now() so accrue-mining''s next call has a clean session-start anchor rather than crediting any pre-session backlog. Requires an existing mining_state row (PXN91 if none — the caller creates one via accrue-mining first, same as every other player-owned-row flow in this project). Does not touch claimed_total, pending_claim, level, or any balance/inventory table — those are returned read-only, unchanged, purely so the caller can render an updated Wallet/Mine screen from this one response without a second round trip.';
