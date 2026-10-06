-- Pro-X Network — Task icon Storage bucket + admin-only write policies.
--
-- Purpose: create the Supabase Storage bucket that will hold
-- admin-uploaded task icon images (PNG/JPG/WebP) for the Telegram
-- Mini App's EARN TASKS screen, plus the RLS policies that let
-- players read those icons and let only admins write them. This
-- mirrors the miner-icons bucket's two-migration architecture
-- (0023_miner_icon_storage.sql for the bucket + public read policy,
-- 0024_miner_icon_storage_policies.sql for the admin-only write
-- policies) combined into one file, per this step's instructions.
-- Neither 0023 nor 0024 is modified by this migration — this file
-- only ever creates a NEW bucket (`task-icons`) and NEW policies
-- scoped to it; the existing `miner-icons` bucket, its policies, and
-- every other existing bucket (e.g. avatars, if any) are left
-- completely untouched.
--
-- This migration deliberately does NOT touch:
--   - public.miner_catalog, public.task_catalog, public.mining_config,
--     public.mining_inventory, public.mining_state, mpxn_ledger,
--     adjust_claimed_total(), or any other existing table/function
--   - public.admin_users or public.is_current_user_admin() themselves
--     (only reused, exactly as-is, inside the policies below)
--   - any existing Storage bucket or its policies (miner-icons,
--     avatars, or any other)
--   - any Edge Function, admin.html, index.html, or any js/*.js file
--   - task_claims, any claim-task logic, or any task_catalog row
--
-- Bucket visibility: `public = true` is what makes GET requests
-- against the bucket's public object URL
-- (".../storage/v1/object/public/task-icons/<path>") work without an
-- Authorization header, matching the requirement that player clients
-- can display task icons without a session. This does NOT grant
-- public list/insert/update/delete access — those are governed
-- entirely by the storage.objects RLS policies below.
--
-- File size limit: 2097152 bytes (2 MB), copied verbatim from the
-- existing miner-icons bucket (0023_miner_icon_storage.sql) per this
-- step's instruction to reuse that limit unless there's a strong
-- project-specific reason not to — there isn't one here, task icons
-- are the same kind of small UI glyph/logo as miner icons.
--
-- Admin check — why this uses public.is_current_user_admin() instead
-- of an inline `exists (select 1 from public.admin_users ...)`: same
-- reasoning as 0024_miner_icon_storage_policies.sql. admin_users has
-- RLS enabled with ZERO policies for `authenticated`
-- (0019_admin_auth_foundation.sql), so a raw EXISTS written directly
-- inside a storage.objects policy would run as the connecting
-- `authenticated` role and always see zero rows — silently locking
-- out even real admins. is_current_user_admin() is the SECURITY
-- DEFINER function 0019 built for exactly this situation: it runs the
-- identical EXISTS check with elevated rights but only ever answers
-- "is auth.uid() an admin?" as a boolean for the caller's own id.
--
-- Idempotency / safe to run only once as 0036: the bucket insert uses
-- ON CONFLICT DO NOTHING, and each policy is dropped (IF EXISTS)
-- immediately before being recreated, so re-running this file is a
-- no-op rather than an error — same conventions as 0023/0024.

insert into storage.buckets
  (id, name, public, file_size_limit, allowed_mime_types)
values
  (
    'task-icons',
    'task-icons',
    true,
    2097152, -- 2 MB, in bytes (2 * 1024 * 1024) — matches miner-icons (0023_miner_icon_storage.sql)
    array['image/png', 'image/jpeg', 'image/webp']
  )
on conflict (id) do nothing;

-- storage.objects already has RLS enabled by default in every
-- Supabase project (Supabase-managed, not created by this migration).
-- Every policy below is scoped to this bucket only via
-- `bucket_id = 'task-icons'` and never touches objects in any other
-- bucket.

-- ---- SELECT: anyone may read objects in task-icons ----
-- Mirrors the bucket's own public-read intent and the existing
-- miner-icons public SELECT policy: anon and authenticated (i.e. the
-- Mini App, whether or not the player has a session yet) may read
-- task icon objects.
drop policy if exists "Public can view task icons" on storage.objects;
create policy "Public can view task icons"
  on storage.objects
  for select
  to anon, authenticated
  using (
    bucket_id = 'task-icons'
  );

-- ---- INSERT: admins may upload new objects into task-icons ----
drop policy if exists "Admins can upload task icons" on storage.objects;
create policy "Admins can upload task icons"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'task-icons'
    and public.is_current_user_admin()
  );

-- ---- UPDATE: admins may replace/overwrite objects in task-icons ----
-- (e.g. re-uploading to the same path, or editing an object's
-- metadata). Both USING (which existing rows may be targeted) and
-- WITH CHECK (what the resulting row must look like) are scoped to
-- this bucket and admin-only, so an admin can't use an update to move
-- an object into a different bucket or touch a row outside it.
drop policy if exists "Admins can update task icons" on storage.objects;
create policy "Admins can update task icons"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'task-icons'
    and public.is_current_user_admin()
  )
  with check (
    bucket_id = 'task-icons'
    and public.is_current_user_admin()
  );

-- ---- DELETE: admins may remove objects from task-icons ----
drop policy if exists "Admins can delete task icons" on storage.objects;
create policy "Admins can delete task icons"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'task-icons'
    and public.is_current_user_admin()
  );

-- No INSERT/UPDATE/DELETE policy is created here for `anon`, or for
-- `authenticated` in general (i.e. ordinary non-admin players) — only
-- the three admin-gated policies above ever allow a write, and only
-- when public.is_current_user_admin() is true for the caller. None of
-- the policies above apply to any bucket other than task-icons, and
-- the existing miner-icons bucket/policies (0023/0024) are completely
-- untouched by this file.
