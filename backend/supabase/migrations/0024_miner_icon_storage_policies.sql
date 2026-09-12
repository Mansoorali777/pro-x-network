-- Pro-X Network — admin-only write policies for the miner-icons
-- Storage bucket.
--
-- Context: 0023_miner_icon_storage.sql already created the
-- `miner-icons` bucket (public=true, PNG/JPEG/WebP, 2 MB limit) and a
-- public SELECT policy on storage.objects for it. admin.html's new
-- icon-upload control authenticates as the signed-in admin's own
-- Supabase session and calls supabase.storage.from('miner-icons')
-- .upload(...) directly — but storage.objects has RLS enabled with
-- no INSERT/UPDATE/DELETE policy for this bucket yet, so every one of
-- those calls is currently rejected. This migration adds exactly the
-- three write policies needed to unblock that upload for admins only.
--
-- This migration does NOT:
--   - create or alter the miner-icons bucket itself (0023 already did)
--   - touch public.miner_catalog, mining_config, mining_inventory,
--     purchase_miner, admin_users, is_current_user_admin(), or any
--     other authentication object
--   - touch any Edge Function, admin.html, or index.html
--   - grant anon, or authenticated-in-general, any write access
--   - add or change the public READ policy (0023's SELECT policy for
--     `anon, authenticated` on this bucket is untouched and still the
--     only reason the public Storage URL works)
--
-- Admin check — why this uses public.is_current_user_admin() instead
-- of an inline "exists (select 1 from public.admin_users ...)":
-- they are logically the same predicate (auth.uid() present in
-- admin_users) — is_current_user_admin() is defined in
-- 0019_admin_auth_foundation.sql as exactly that EXISTS query — but
-- admin_users itself has RLS enabled with ZERO policies for
-- `authenticated`, by design (see 0019: "no RLS policy grants
-- anon/authenticated any access"). A raw EXISTS written directly
-- inside a storage.objects policy runs as the connecting
-- `authenticated` role, so it would hit that same default-deny RLS on
-- admin_users and always see zero rows — silently locking every
-- admin out, including real ones. is_current_user_admin() is the
-- SECURITY DEFINER function 0019 built for precisely this situation:
-- it runs the identical EXISTS check with elevated rights so it can
-- actually see admin_users, while still only ever answering "is
-- auth.uid() an admin?" as a boolean for the caller's own id — it
-- can't be used to read admin_users' contents or check anyone else.
-- Using it here satisfies requirement 12/20's EXISTS-based admin
-- check while keeping admin_users' own access model completely
-- unmodified, per requirement 6.
--
-- Idempotency / safe to run only once as 0024: each policy is dropped
-- (IF EXISTS) immediately before being recreated, so re-running this
-- file is a no-op rather than an error.

-- ---- INSERT: admins may upload new objects into miner-icons ----
drop policy if exists "Admins can upload miner icons" on storage.objects;
create policy "Admins can upload miner icons"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'miner-icons'
    and public.is_current_user_admin()
  );

-- ---- UPDATE: admins may replace/overwrite objects in miner-icons ----
-- (e.g. re-uploading to the same path, or editing an object's
-- metadata). Both USING (which existing rows may be targeted) and
-- WITH CHECK (what the resulting row must look like) are scoped to
-- this bucket and admin-only, so an admin can't use an update to move
-- an object into a different bucket or touch a row outside it.
drop policy if exists "Admins can update miner icons" on storage.objects;
create policy "Admins can update miner icons"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'miner-icons'
    and public.is_current_user_admin()
  )
  with check (
    bucket_id = 'miner-icons'
    and public.is_current_user_admin()
  );

-- ---- DELETE: admins may remove objects from miner-icons ----
drop policy if exists "Admins can delete miner icons" on storage.objects;
create policy "Admins can delete miner icons"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'miner-icons'
    and public.is_current_user_admin()
  );

-- No policy is created here for `anon`, and none of the three
-- policies above apply to any bucket other than miner-icons. Public
-- READ access for this bucket continues to come solely from 0023's
-- existing SELECT policy (and the bucket's own public=true flag for
-- the direct object URL) — neither is touched by this file.
