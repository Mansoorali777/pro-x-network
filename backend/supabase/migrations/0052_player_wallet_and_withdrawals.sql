-- Pro-X Network — TON wallet onboarding + PXN withdrawal system.
--
-- Tables: public.player_wallets, public.withdrawal_config, public.withdrawals.
-- Functions: public.is_valid_ton_address(text),
--            public.connect_wallet(uuid, text, text),
--            public.create_withdrawal_request(uuid, numeric),
--            public.admin_list_pending_withdrawals(uuid),
--            public.admin_approve_withdrawal(uuid, uuid),
--            public.admin_reject_withdrawal(uuid, uuid, text),
--            public.admin_complete_withdrawal(uuid, uuid, text),
--            public.admin_set_withdrawal_config(uuid, numeric, numeric, boolean).
--
-- Context: per the audit of 0000-0051, this project already has:
--   - public.users (identity, telegram_user_id, is_banned) — 0002.
--   - public.user_profiles (cosmetic display_name/avatar/bio, ALREADY
--     client-writable via user_profiles_update_own) — 0002. Wallet data
--     is NOT added to user_profiles: that table's existing RLS lets an
--     authenticated player UPDATE any column on their own row directly,
--     which is correct for cosmetic fields but would be a security
--     regression for wallet_address (client-authoritative wallet writes
--     are explicitly forbidden by this task). Wallet data therefore gets
--     its own table, following the SAME zero-client-write-policy +
--     SECURITY DEFINER RPC pattern already used throughout this schema
--     for every other authoritative table (mining_state, referrals,
--     admin_users, mpxn_ledger) — not a new pattern, the existing one.
--   - public.mining_state.claimed_total — the authoritative, spendable
--     m.PXN balance (0013), moved exclusively through
--     public.adjust_claimed_total() (0030_mpxn_ledger_primitive.sql),
--     which is atomic (row-locked), idempotent (unique ledger key), and
--     already used by every other m.PXN-spending feature in this
--     project (level-up, marketplace). Withdrawal creation reuses this
--     SAME primitive rather than hand-rolling a second balance-mutation
--     code path — this is the "existing authoritative ledger mechanism"
--     Phase 6/8 instructs this migration to reuse, not duplicate.
--   - public.admin_users + public.is_current_user_admin() (0019) — the
--     existing admin authorization mechanism, reused as-is below via
--     the same `exists (select 1 from public.admin_users where user_id
--     = p_admin_user_id)` check every other admin RPC in this schema
--     (e.g. 0049's admin_create_leaderboard_period) already uses.
--   - No existing withdrawal/payment/transaction table, and no
--     existing m.PXN -> PXN conversion formula/config anywhere in this
--     codebase (the frontend's own SWAP card is explicitly
--     "COMING SOON" with no backend behind it). A conversion rate is
--     therefore introduced here as its own explicit,
--     backend-controlled, admin-adjustable singleton config table
--     (public.withdrawal_config) — never a hardcoded constant — seeded
--     at a documented 1:1 placeholder with withdrawals PAUSED by
--     default (see section 2), consistent with the existing frontend
--     copy ("withdrawals will become available after the official
--     launch and eligibility rules are announced").
--
-- Continues this schema's existing PXNnn error-code convention. Highest
-- code in use as of 0049 is PXN75; this migration uses PXN80-PXN92 to
-- leave room for anything unseen between the two.
--
-- Does not modify 0000-0051, index.html, admin.html, js/auth-client.js,
-- js/api-client.js, or any existing function/table beyond what is
-- listed above. Does not touch marketplace, mining, referral, or
-- leaderboard tables/functions (leaderboard display-name is a
-- separate, later migration — 0053).

-- =====================================================================
-- 1. public.player_wallets
-- =====================================================================

create table public.player_wallets (
  user_id             uuid        primary key references public.users(id) on delete cascade,
  wallet_address       text        not null,
  wallet_network        text        not null default 'ton' check (wallet_network in ('ton')),
  wallet_connected_at   timestamptz not null default now(),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

comment on table public.player_wallets is
  'One row per player once a wallet is connected. Backend-authoritative: written ONLY by public.connect_wallet() (SECURITY DEFINER, service_role-only). No RLS policy grants authenticated INSERT/UPDATE/DELETE — a player may only SELECT their own row (player_wallets_select_own). wallet_address is never accepted from the client for authorization purposes and never trusted as proof of ownership (see is_valid_ton_address — format validation only, not signature/ownership verification).';
comment on column public.player_wallets.wallet_address is
  'TON wallet address as submitted, in canonical form (see is_valid_ton_address). Format-validated server-side only. This is NOT a proof of ownership — no signature verification exists yet (see connect_wallet comment).';

create trigger player_wallets_set_updated_at
  before update on public.player_wallets
  for each row execute function public.set_updated_at();

alter table public.player_wallets enable row level security;

create policy "player_wallets_select_own"
  on public.player_wallets
  for select
  to authenticated
  using (auth.uid() = user_id);

-- No INSERT/UPDATE/DELETE policy for authenticated/anon: RLS + zero
-- matching policy denies those operations by default, exactly like
-- mining_state/referrals/admin_users. All writes go through
-- connect_wallet() below, called from the connect-wallet Edge Function
-- using the service_role key.

-- =====================================================================
-- 2. public.withdrawal_config (singleton, same pattern as
--    referral_config/marketplace_config: id boolean primary key
--    default true check (id = true) physically prevents a second row).
-- =====================================================================

create table public.withdrawal_config (
  id                          boolean       primary key default true check (id = true),

  -- Backend-controlled m.PXN -> PXN conversion rate. Seeded at 1 as an
  -- explicit PLACEHOLDER — no real tokenomics conversion rate exists
  -- anywhere else in this codebase as of this migration (the
  -- frontend's SWAP card is "COMING SOON" with no backend). Whoever
  -- owns this project must review/update this value via
  -- admin_set_withdrawal_config() before real withdrawals are used for
  -- real value.
  mpxn_to_pxn_rate            numeric(20,8) not null default 1
                                check (mpxn_to_pxn_rate > 0),

  min_withdrawal_mpxn         numeric(20,8) not null default 0
                                check (min_withdrawal_mpxn >= 0),

  -- Global kill switch. Defaults to TRUE (paused) so that applying
  -- this migration does not silently turn on real withdrawals — an
  -- admin must explicitly flip this via admin_set_withdrawal_config()
  -- once wallet validation, the conversion rate, and settlement
  -- process have all been reviewed for production use. Matches the
  -- existing frontend copy: "PXN withdrawals will become available
  -- after the official launch and eligibility rules are announced."
  withdrawals_paused          boolean       not null default true,

  updated_at                   timestamptz   not null default now(),
  updated_by_admin_user_id     uuid          references auth.users(id)
);

comment on table public.withdrawal_config is
  'Singleton (id always = true). Backend-controlled withdrawal settings: the m.PXN->PXN conversion rate (mpxn_to_pxn_rate, seeded at a documented 1:1 PLACEHOLDER — no other conversion rate exists in this project), the minimum withdrawal amount, and a global pause switch (withdrawals_paused, defaults TRUE). Never read/written directly by the client — read fresh by create_withdrawal_request() on every call, written only by admin_set_withdrawal_config().';

create trigger withdrawal_config_set_updated_at
  before update on public.withdrawal_config
  for each row execute function public.set_updated_at();

insert into public.withdrawal_config (id) values (true);

alter table public.withdrawal_config enable row level security;
-- No policies for anon/authenticated: same admin/service-role-only
-- access model as mining_config/marketplace_config/referral_config.

-- =====================================================================
-- 3. public.withdrawals
-- =====================================================================

create table public.withdrawals (
  id                 uuid          primary key default gen_random_uuid(),
  user_id            uuid          not null references public.users(id) on delete cascade,

  -- Snapshot of the wallet this request pays out to, copied from
  -- player_wallets by create_withdrawal_request() at creation time —
  -- never accepted from the client request body. Kept as a snapshot
  -- (not a live join) so a later wallet change never silently retargets
  -- an already-submitted request.
  wallet_address      text          not null,
  wallet_network        text          not null default 'ton',

  amount_mpxn         numeric(20,8) not null check (amount_mpxn > 0),
  amount_pxn          numeric(20,8) not null check (amount_pxn > 0),

  status              text          not null default 'pending'
                        check (status in ('pending', 'approved', 'rejected', 'completed')),

  rejection_reason     text,
  reviewed_by          uuid          references auth.users(id),
  reviewed_at           timestamptz,
  tx_hash              text,

  created_at            timestamptz   not null default now(),
  updated_at             timestamptz   not null default now()
);

comment on table public.withdrawals is
  'Backend-authoritative PXN withdrawal request. amount_mpxn is debited from mining_state.claimed_total (via adjust_claimed_total, reason=withdrawal_request) atomically at creation time — this row existing with status=pending IS the balance reservation; there is no separate "reserved" column. Written ONLY by create_withdrawal_request() / admin_approve_withdrawal() / admin_reject_withdrawal() / admin_complete_withdrawal() (all SECURITY DEFINER, service_role-only). A player may SELECT only their own rows (withdrawals_select_own). No client INSERT/UPDATE/DELETE policy exists.';
comment on column public.withdrawals.amount_mpxn is
  'm.PXN debited from the player at request time via adjust_claimed_total (reason=withdrawal_request, ref_type=withdrawal, ref_id=this row''s id). Rejection credits this exact amount back (reason=withdrawal_reject_refund).';
comment on column public.withdrawals.amount_pxn is
  'PXN amount computed server-side at request time as amount_mpxn * withdrawal_config.mpxn_to_pxn_rate (rate frozen at that moment) — never accepted from the client.';

create index withdrawals_user_id_created_at_idx
  on public.withdrawals (user_id, created_at desc);

create index withdrawals_status_created_at_idx
  on public.withdrawals (status, created_at)
  where status = 'pending';

create trigger withdrawals_set_updated_at
  before update on public.withdrawals
  for each row execute function public.set_updated_at();

alter table public.withdrawals enable row level security;

create policy "withdrawals_select_own"
  on public.withdrawals
  for select
  to authenticated
  using (auth.uid() = user_id);

-- No INSERT/UPDATE/DELETE policy for authenticated/anon — every write
-- happens inside the SECURITY DEFINER functions below, service_role-only.

-- =====================================================================
-- 4. TON address format validation (NOT ownership/signature
--    verification — see function comment and Phase 16 instructions).
-- =====================================================================

create or replace function public.is_valid_ton_address(p_address text)
returns boolean
language sql
immutable
as $$
  -- Two TON address encodings are accepted, format-only:
  --   raw:           <workchain>:<64 hex chars>, workchain is -1 or 0
  --                   e.g. 0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a
  --   user-friendly:  48 base64url characters (with or without -/_ safe
  --                   alphabet), e.g. EQD...48 chars total. This is a
  --                   plain charset+length check, NOT a base64 CRC/
  --                   checksum validation and NOT bounceable-flag
  --                   parsing — sufficient to reject obviously-wrong
  --                   input (wrong chain's address, random text,
  --                   empty string) without claiming more than that.
  select
    p_address is not null
    and (
      p_address ~ '^-?[0-9]:[0-9a-fA-F]{64}$'
      or p_address ~ '^[A-Za-z0-9_-]{48}$'
    );
$$;

comment on function public.is_valid_ton_address(text) is
  'Format-only validation of a TON wallet address (raw <workchain>:<64 hex> or 48-char user-friendly base64url). Does NOT verify checksum/CRC and does NOT prove wallet ownership — no signature verification exists in this project yet (see connect_wallet). Rejects anything that is not shaped like a TON address; does not guarantee the address is live/fundable.';

-- =====================================================================
-- 5. public.connect_wallet — the ONLY way player_wallets is written.
-- =====================================================================
--
-- Error codes:
--   PXN80 — p_user_id is null / does not reference an existing
--           public.users row                                -> 400/404
--   PXN81 — p_wallet_address fails is_valid_ton_address / p_wallet_network
--           is not a supported value                          -> 400
--   PXN82 — wallet_already_connected: a DIFFERENT address is already
--           saved for this player                            -> 409

create or replace function public.connect_wallet(
  p_user_id         uuid,
  p_wallet_address   text,
  p_wallet_network    text default 'ton'
)
returns public.player_wallets
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_address  text;
  v_existing public.player_wallets%rowtype;
  v_result   public.player_wallets%rowtype;
begin
  if p_user_id is null or not exists (select 1 from public.users where id = p_user_id) then
    raise exception 'connect_wallet: p_user_id is required and must reference an existing player'
      using errcode = 'PXN80';
  end if;

  v_address := btrim(coalesce(p_wallet_address, ''));

  if p_wallet_network is distinct from 'ton' or not public.is_valid_ton_address(v_address) then
    raise exception 'connect_wallet: invalid wallet address/network'
      using errcode = 'PXN81';
  end if;

  -- Lock any existing row for this player for the duration of this
  -- transaction, same idiom as every other mining_state/referrals
  -- writer in this schema.
  select * into v_existing
    from public.player_wallets
   where user_id = p_user_id
     for update;

  if found then
    if v_existing.wallet_address = v_address and v_existing.wallet_network = p_wallet_network then
      -- Idempotent replay of the exact same address: not an error.
      return v_existing;
    end if;

    -- A different address is already connected. Per this project's
    -- non-negotiable rules, wallet data is backend-authoritative and
    -- must never be silently overwritten by a client-supplied value —
    -- changing an already-connected wallet is out of scope for this
    -- migration (no "change wallet" flow was specified) and is
    -- reported as a distinct error rather than silently accepted or
    -- silently ignored.
    raise exception 'connect_wallet: a wallet is already connected for this player'
      using errcode = 'PXN82';
  end if;

  insert into public.player_wallets (user_id, wallet_address, wallet_network, wallet_connected_at)
  values (p_user_id, v_address, p_wallet_network, now())
  returning * into v_result;

  return v_result;
end;
$$;

comment on function public.connect_wallet(uuid, text, text) is
  'service_role-only. Validates p_wallet_address format (is_valid_ton_address) and p_wallet_network, then inserts the player''s player_wallets row. Idempotent for a repeated identical address; raises PXN82 (wallet_already_connected) if a DIFFERENT address is already saved — this function never overwrites an existing wallet. p_user_id is always the caller''s own auth.uid(), supplied by the connect-wallet Edge Function, never trusted from elsewhere. Not callable by anon/authenticated.';

revoke all on function public.connect_wallet(uuid, text, text) from public;
revoke all on function public.connect_wallet(uuid, text, text) from anon;
revoke all on function public.connect_wallet(uuid, text, text) from authenticated;
grant execute on function public.connect_wallet(uuid, text, text) to service_role;

-- =====================================================================
-- 6. public.create_withdrawal_request
-- =====================================================================
--
-- Error codes:
--   PXN83 — p_user_id null/unknown, or p_amount_mpxn not a positive
--           finite number                                     -> 400
--   PXN84 — wallet_required: no player_wallets row for this player
--                                                               -> 400
--   PXN85 — withdrawal_paused: withdrawal_config.withdrawals_paused
--                                                               -> 403
--   PXN86 — below withdrawal_config.min_withdrawal_mpxn         -> 400
--   PXN87 — duplicate_withdrawal: player already has a pending
--           withdrawal request                                 -> 409
--   (PXN24/PXN25/PXN26 propagate unchanged from adjust_claimed_total()
--   for insufficient balance / missing mining_state / a genuine
--   ledger-level duplicate — this function does not catch or reinterpret
--   those, exactly like every other adjust_claimed_total() caller in
--   this schema.)

create or replace function public.create_withdrawal_request(
  p_user_id      uuid,
  p_amount_mpxn  numeric
)
returns public.withdrawals
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_wallet       public.player_wallets%rowtype;
  v_config       public.withdrawal_config%rowtype;
  v_withdrawal_id uuid;
  v_amount_pxn   numeric(20,8);
  v_result       public.withdrawals%rowtype;
begin
  if p_user_id is null or not exists (select 1 from public.users where id = p_user_id) then
    raise exception 'create_withdrawal_request: p_user_id is required and must reference an existing player'
      using errcode = 'PXN83';
  end if;

  if p_amount_mpxn is null or p_amount_mpxn <= 0 then
    raise exception 'create_withdrawal_request: p_amount_mpxn must be a positive number'
      using errcode = 'PXN83';
  end if;

  select * into v_wallet
    from public.player_wallets
   where user_id = p_user_id;

  if not found then
    raise exception 'create_withdrawal_request: no wallet connected for this player'
      using errcode = 'PXN84';
  end if;

  select * into v_config from public.withdrawal_config where id = true;

  if not found then
    -- Should be unreachable: this table is seeded with exactly one row
    -- by this migration and is never deletable via any policy.
    raise exception 'create_withdrawal_request: no withdrawal_config row exists (server misconfiguration)'
      using errcode = 'PXN89';
  end if;

  if v_config.withdrawals_paused then
    raise exception 'create_withdrawal_request: withdrawals are currently paused'
      using errcode = 'PXN85';
  end if;

  if p_amount_mpxn < v_config.min_withdrawal_mpxn then
    raise exception 'create_withdrawal_request: amount is below the minimum withdrawal (%)', v_config.min_withdrawal_mpxn
      using errcode = 'PXN86';
  end if;

  -- One pending request at a time per player. Checked under the same
  -- transaction as the balance debit below (no separate advisory lock
  -- needed: adjust_claimed_total already locks this player's
  -- mining_state row for the remainder of this transaction, which
  -- serializes concurrent calls to this function for the same player).
  if exists (
    select 1 from public.withdrawals
     where user_id = p_user_id and status = 'pending'
  ) then
    raise exception 'create_withdrawal_request: a pending withdrawal request already exists'
      using errcode = 'PXN87';
  end if;

  v_withdrawal_id := gen_random_uuid();
  v_amount_pxn := p_amount_mpxn * v_config.mpxn_to_pxn_rate;

  -- Atomic, row-locked, idempotent debit of the EXISTING authoritative
  -- m.PXN ledger primitive (0030) — reused as-is, not duplicated. This
  -- single call is what makes two concurrent withdrawal requests for
  -- the same player unable to both reserve the same balance: the
  -- second call's UPDATE inside adjust_claimed_total blocks on the
  -- first call's row lock, then re-evaluates claimed_total against the
  -- (now-updated) current value.
  perform public.adjust_claimed_total(
    p_user_id,
    -p_amount_mpxn,
    'withdrawal_request',
    'withdrawal',
    v_withdrawal_id
  );

  insert into public.withdrawals (
    id, user_id, wallet_address, wallet_network, amount_mpxn, amount_pxn, status
  ) values (
    v_withdrawal_id, p_user_id, v_wallet.wallet_address, v_wallet.wallet_network,
    p_amount_mpxn, v_amount_pxn, 'pending'
  )
  returning * into v_result;

  return v_result;
end;
$$;

comment on function public.create_withdrawal_request(uuid, numeric) is
  'service_role-only. Validates the player has a connected wallet, withdrawals are not paused, the amount meets the configured minimum, and the player has no other pending request. Debits amount_mpxn from claimed_total atomically via the EXISTING adjust_claimed_total() primitive (reason=withdrawal_request) — this IS the balance reservation, and is what prevents double-spend on concurrent requests. Computes amount_pxn from the current withdrawal_config.mpxn_to_pxn_rate, frozen onto the row at creation. wallet_address/wallet_network are copied from the player''s own player_wallets row, never accepted from the caller. Not callable by anon/authenticated.';

revoke all on function public.create_withdrawal_request(uuid, numeric) from public;
revoke all on function public.create_withdrawal_request(uuid, numeric) from anon;
revoke all on function public.create_withdrawal_request(uuid, numeric) from authenticated;
grant execute on function public.create_withdrawal_request(uuid, numeric) to service_role;

-- =====================================================================
-- 7. Admin withdrawal actions. Every one independently re-verifies
--    admin authorization server-side via public.admin_users, exactly
--    like 0049's admin_create_leaderboard_period/etc — never trusts a
--    caller-supplied "is admin" flag.
-- =====================================================================
--
-- Error codes:
--   PXN61 — caller is not an admin (reused from 0049, same meaning)
--   PXN90 — withdrawal_not_found                                -> 404
--   PXN91 — withdrawal_not_pending (approve/reject only act on a
--           currently-'pending' row)                            -> 409
--   PXN92 — rejection_reason_required (empty/blank p_reason)     -> 400
--   PXN93 — withdrawal_not_approved (complete only acts on a
--           currently-'approved' row)                           -> 409

create or replace function public.admin_list_pending_withdrawals(
  p_admin_user_id uuid
)
returns table (
  id             uuid,
  user_id        uuid,
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
    raise exception 'admin_list_pending_withdrawals: caller is not an admin'
      using errcode = 'PXN61';
  end if;

  return query
    select w.id, w.user_id, w.wallet_address, w.wallet_network,
           w.amount_mpxn, w.amount_pxn, w.status, w.created_at
      from public.withdrawals w
     where w.status = 'pending'
     order by w.created_at asc;
end;
$$;

revoke all on function public.admin_list_pending_withdrawals(uuid) from public;
revoke all on function public.admin_list_pending_withdrawals(uuid) from anon;
revoke all on function public.admin_list_pending_withdrawals(uuid) from authenticated;
grant execute on function public.admin_list_pending_withdrawals(uuid) to service_role;


create or replace function public.admin_approve_withdrawal(
  p_admin_user_id  uuid,
  p_withdrawal_id  uuid
)
returns public.withdrawals
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
  v_result public.withdrawals%rowtype;
begin
  if p_admin_user_id is null or not exists (select 1 from public.admin_users where user_id = p_admin_user_id) then
    raise exception 'admin_approve_withdrawal: caller is not an admin'
      using errcode = 'PXN61';
  end if;

  select status into v_status
    from public.withdrawals
   where id = p_withdrawal_id
     for update;

  if not found then
    raise exception 'admin_approve_withdrawal: withdrawal % not found', p_withdrawal_id
      using errcode = 'PXN90';
  end if;

  if v_status <> 'pending' then
    raise exception 'admin_approve_withdrawal: withdrawal % is not pending (current status %)', p_withdrawal_id, v_status
      using errcode = 'PXN91';
  end if;

  update public.withdrawals
     set status      = 'approved',
         reviewed_by  = p_admin_user_id,
         reviewed_at  = now()
   where id = p_withdrawal_id
     and status = 'pending'
  returning * into v_result;

  return v_result;
end;
$$;

comment on function public.admin_approve_withdrawal(uuid, uuid) is
  'service_role-only, admin-gated (re-verifies public.admin_users independently). Transitions a withdrawal from pending -> approved only; any other current status raises PXN91 (no replay possible). Records reviewed_by/reviewed_at. Does NOT move any balance (the debit already happened at request time) and does NOT create or claim a blockchain transaction — approved means approved for settlement, not completed. See admin_complete_withdrawal for marking actual settlement.';

revoke all on function public.admin_approve_withdrawal(uuid, uuid) from public;
revoke all on function public.admin_approve_withdrawal(uuid, uuid) from anon;
revoke all on function public.admin_approve_withdrawal(uuid, uuid) from authenticated;
grant execute on function public.admin_approve_withdrawal(uuid, uuid) to service_role;


create or replace function public.admin_reject_withdrawal(
  p_admin_user_id  uuid,
  p_withdrawal_id  uuid,
  p_reason          text
)
returns public.withdrawals
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row     public.withdrawals%rowtype;
  v_reason  text;
  v_result  public.withdrawals%rowtype;
begin
  if p_admin_user_id is null or not exists (select 1 from public.admin_users where user_id = p_admin_user_id) then
    raise exception 'admin_reject_withdrawal: caller is not an admin'
      using errcode = 'PXN61';
  end if;

  v_reason := btrim(coalesce(p_reason, ''));
  if v_reason = '' then
    raise exception 'admin_reject_withdrawal: a non-empty rejection reason is required'
      using errcode = 'PXN92';
  end if;
  v_reason := left(v_reason, 500);

  select * into v_row
    from public.withdrawals
   where id = p_withdrawal_id
     for update;

  if not found then
    raise exception 'admin_reject_withdrawal: withdrawal % not found', p_withdrawal_id
      using errcode = 'PXN90';
  end if;

  if v_row.status <> 'pending' then
    raise exception 'admin_reject_withdrawal: withdrawal % is not pending (current status %)', p_withdrawal_id, v_row.status
      using errcode = 'PXN91';
  end if;

  update public.withdrawals
     set status           = 'rejected',
         rejection_reason = v_reason,
         reviewed_by       = p_admin_user_id,
         reviewed_at        = now()
   where id = p_withdrawal_id
     and status = 'pending'
  returning * into v_result;

  -- Release the reservation: credit the exact debited amount back via
  -- the SAME existing ledger primitive used at request time — never a
  -- hand-rolled UPDATE on claimed_total. Distinct reason
  -- ('withdrawal_reject_refund' vs 'withdrawal_request') means this
  -- insert never collides with the original debit's idempotency key,
  -- while still being itself idempotent against a retried call to
  -- THIS function (blocked by the status <> 'pending' check above
  -- once the first call has committed).
  perform public.adjust_claimed_total(
    v_row.user_id,
    v_row.amount_mpxn,
    'withdrawal_reject_refund',
    'withdrawal',
    p_withdrawal_id
  );

  return v_result;
end;
$$;

comment on function public.admin_reject_withdrawal(uuid, uuid, text) is
  'service_role-only, admin-gated. Requires a non-empty p_reason (PXN92). Transitions pending -> rejected only (PXN91 otherwise), records rejection_reason/reviewed_by/reviewed_at, and credits amount_mpxn back to the player''s claimed_total via adjust_claimed_total (reason=withdrawal_reject_refund) — reversing exactly the reservation made by create_withdrawal_request. Not replayable: a second call finds status <> pending and raises PXN91 before ever reaching the refund.';

revoke all on function public.admin_reject_withdrawal(uuid, uuid, text) from public;
revoke all on function public.admin_reject_withdrawal(uuid, uuid, text) from anon;
revoke all on function public.admin_reject_withdrawal(uuid, uuid, text) from authenticated;
grant execute on function public.admin_reject_withdrawal(uuid, uuid, text) to service_role;


create or replace function public.admin_complete_withdrawal(
  p_admin_user_id  uuid,
  p_withdrawal_id  uuid,
  p_tx_hash         text
)
returns public.withdrawals
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status  text;
  v_hash    text;
  v_result  public.withdrawals%rowtype;
begin
  if p_admin_user_id is null or not exists (select 1 from public.admin_users where user_id = p_admin_user_id) then
    raise exception 'admin_complete_withdrawal: caller is not an admin'
      using errcode = 'PXN61';
  end if;

  v_hash := btrim(coalesce(p_tx_hash, ''));
  if v_hash = '' then
    -- Per Phase 10: never fake/claim a transaction hash. A genuinely
    -- completed settlement must supply the real on-chain tx hash; this
    -- function refuses to mark completion without one rather than
    -- inventing or defaulting it.
    raise exception 'admin_complete_withdrawal: a non-empty tx_hash is required to mark a withdrawal completed'
      using errcode = 'PXN92';
  end if;

  select status into v_status
    from public.withdrawals
   where id = p_withdrawal_id
     for update;

  if not found then
    raise exception 'admin_complete_withdrawal: withdrawal % not found', p_withdrawal_id
      using errcode = 'PXN90';
  end if;

  if v_status <> 'approved' then
    raise exception 'admin_complete_withdrawal: withdrawal % is not approved (current status %)', p_withdrawal_id, v_status
      using errcode = 'PXN93';
  end if;

  update public.withdrawals
     set status  = 'completed',
         tx_hash = v_hash
   where id = p_withdrawal_id
     and status = 'approved'
  returning * into v_result;

  return v_result;
end;
$$;

comment on function public.admin_complete_withdrawal(uuid, uuid, text) is
  'service_role-only, admin-gated. Transitions approved -> completed only (PXN93 otherwise), and requires a real, non-empty p_tx_hash (PXN92) — this project has no automated on-chain settlement, so this function never fabricates a hash; the caller (an admin, after manually sending the transfer) must supply the actual on-chain hash. No balance movement here (already debited at request time).';

revoke all on function public.admin_complete_withdrawal(uuid, uuid, text) from public;
revoke all on function public.admin_complete_withdrawal(uuid, uuid, text) from anon;
revoke all on function public.admin_complete_withdrawal(uuid, uuid, text) from authenticated;
grant execute on function public.admin_complete_withdrawal(uuid, uuid, text) to service_role;


create or replace function public.admin_set_withdrawal_config(
  p_admin_user_id        uuid,
  p_mpxn_to_pxn_rate      numeric,
  p_min_withdrawal_mpxn   numeric,
  p_withdrawals_paused    boolean
)
returns public.withdrawal_config
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.withdrawal_config%rowtype;
begin
  if p_admin_user_id is null or not exists (select 1 from public.admin_users where user_id = p_admin_user_id) then
    raise exception 'admin_set_withdrawal_config: caller is not an admin'
      using errcode = 'PXN61';
  end if;

  if p_mpxn_to_pxn_rate is null or p_mpxn_to_pxn_rate <= 0 then
    raise exception 'admin_set_withdrawal_config: mpxn_to_pxn_rate must be a positive number'
      using errcode = 'PXN89';
  end if;

  if p_min_withdrawal_mpxn is null or p_min_withdrawal_mpxn < 0 then
    raise exception 'admin_set_withdrawal_config: min_withdrawal_mpxn must be zero or greater'
      using errcode = 'PXN89';
  end if;

  update public.withdrawal_config
     set mpxn_to_pxn_rate     = p_mpxn_to_pxn_rate,
         min_withdrawal_mpxn  = p_min_withdrawal_mpxn,
         withdrawals_paused   = coalesce(p_withdrawals_paused, true),
         updated_by_admin_user_id = p_admin_user_id
   where id = true
  returning * into v_result;

  return v_result;
end;
$$;

comment on function public.admin_set_withdrawal_config(uuid, numeric, numeric, boolean) is
  'service_role-only, admin-gated. Updates the singleton withdrawal_config row (conversion rate, minimum withdrawal, pause switch). This is the ONLY sanctioned way to change the m.PXN->PXN conversion rate this project uses — never hardcode a rate anywhere else.';

revoke all on function public.admin_set_withdrawal_config(uuid, numeric, numeric, boolean) from public;
revoke all on function public.admin_set_withdrawal_config(uuid, numeric, numeric, boolean) from anon;
revoke all on function public.admin_set_withdrawal_config(uuid, numeric, numeric, boolean) from authenticated;
grant execute on function public.admin_set_withdrawal_config(uuid, numeric, numeric, boolean) to service_role;

-- =====================================================================
-- 8. Safety net: explicitly revoke default table grants from
--    anon/authenticated for every new table (belt-and-suspenders on
--    top of RLS, same pattern 0049 section 11 uses).
-- =====================================================================

revoke all on table public.player_wallets from anon, authenticated;
revoke all on table public.withdrawal_config from anon, authenticated;
revoke all on table public.withdrawals from anon, authenticated;
-- Re-grant SELECT only, so the RLS policies above (select_own) can
-- actually take effect for the authenticated role (a blanket REVOKE
-- ALL would otherwise block even the rows RLS would allow).
grant select on table public.player_wallets to authenticated;
grant select on table public.withdrawals to authenticated;

-- No existing table, function, policy, or grant (0000-0051) is
-- modified by this migration.
