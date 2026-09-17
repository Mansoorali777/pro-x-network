-- Pro-X Network — Users system.
--
-- Tables: users, user_profiles.
--
-- Identity rule (per spec): the permanent identity of a player is
-- `telegram_user_id` (Telegram's numeric user id), which never
-- changes for a given Telegram account. `telegram_username` is
-- stored for display only — Telegram usernames are mutable and can
-- even be removed by the user — so it is NEVER unique-indexed and
-- NEVER used to look up a player.

create table public.users (
  id                 uuid        primary key default gen_random_uuid(),

  -- Permanent identity. Telegram user ids fit in a 64-bit signed int,
  -- hence bigint (not int).
  telegram_user_id   bigint      not null,

  -- Display-only metadata from Telegram. Never used as a lookup key.
  telegram_username    text,
  telegram_first_name  text,
  telegram_last_name   text,
  language_code        text,
  is_premium           boolean   not null default false,

  -- Moderation / access control.
  is_banned          boolean     not null default false,
  banned_reason      text,

  last_login_at      timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table public.users is
  'One row per Telegram account. telegram_user_id is the permanent identity; telegram_username is display-only and mutable.';
comment on column public.users.telegram_user_id is
  'Telegram''s numeric user id. Permanent. This — not the username — is the account identity.';

-- Requirement: Telegram user id must be uniquely indexed.
create unique index users_telegram_user_id_key on public.users (telegram_user_id);

create trigger users_set_updated_at
  before update on public.users
  for each row execute function public.set_updated_at();

alter table public.users enable row level security;

-- A user may read their own account row (needed by the frontend to
-- show profile/status info). No policy allows INSERT/UPDATE/DELETE
-- for anon/authenticated: account creation happens once, during
-- Telegram auth, and mutations (bans, login timestamps, etc.) are
-- all administrative or system actions. Both go through the
-- service_role key inside an Edge Function, which bypasses RLS by
-- design — never through a client-supplied key.
create policy "users_select_own"
  on public.users
  for select
  to authenticated
  using (auth.uid() = id);


create table public.user_profiles (
  user_id       uuid        primary key references public.users(id) on delete cascade,
  display_name  text,
  avatar_url    text,
  bio           text,
  country_code  text,
  timezone      text,
  settings      jsonb       not null default '{}'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.user_profiles is
  'Cosmetic / non-financial profile data, 1:1 with users. Safe for the client to read and update directly.';

create trigger user_profiles_set_updated_at
  before update on public.user_profiles
  for each row execute function public.set_updated_at();

alter table public.user_profiles enable row level security;

-- Profile data carries no financial risk, so (unlike most tables in
-- this schema) the owning user is allowed to read and edit it
-- directly from the client.
create policy "user_profiles_select_own"
  on public.user_profiles
  for select
  to authenticated
  using (auth.uid() = user_id);

create policy "user_profiles_insert_own"
  on public.user_profiles
  for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy "user_profiles_update_own"
  on public.user_profiles
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
