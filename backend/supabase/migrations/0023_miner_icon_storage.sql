-- Pro-X Network — Miner icon Storage bucket.
--
-- Purpose: create ONLY the Supabase Storage bucket that will hold
-- admin-uploaded miner icon images (PNG/JPG/WebP) for the Telegram
-- Mini App. This is schema/config only — no admin upload UI, no
-- Edge Function, and no change to how icons are currently rendered
-- (public.miner_catalog.miner_icon still holds today's data-URI/emoji
-- values, see 0021_miner_catalog.sql). A later step will add a
-- secure, admin-only Edge Function to upload/replace/delete objects
-- in this bucket and to point miner_catalog.miner_icon rows at the
-- resulting public Storage URLs.
--
-- This migration deliberately does NOT touch:
--   - public.miner_catalog, public.mining_config, public.mining_inventory
--   - purchase-miner, or any other Edge Function
--   - authentication or admin authentication
--   - admin.html or index.html
--   - any anonymous/public WRITE permission
--
-- Bucket visibility: `public = true` is what makes GET requests
-- against the bucket's public object URL
-- (".../storage/v1/object/public/miner-icons/<path>") work without an
-- Authorization header, which is required for the Mini App's <img>
-- tags to load icons directly. This does NOT grant public list/insert/
-- update/delete access — those are governed entirely by the
-- storage.objects RLS policies below (or their absence).
--
-- Idempotency / "safe to run only once as 0023": every statement here
-- is written so re-running this file is a no-op rather than an error
-- (ON CONFLICT DO NOTHING for the bucket row, DROP POLICY IF EXISTS
-- before each CREATE POLICY).

insert into storage.buckets
  (id, name, public, file_size_limit, allowed_mime_types)
values
  (
    'miner-icons',
    'miner-icons',
    true,
    2097152, -- 2 MB, in bytes (2 * 1024 * 1024)
    array['image/png', 'image/jpeg', 'image/webp']
  )
on conflict (id) do nothing;

-- storage.objects already has RLS enabled by default in every
-- Supabase project (it is Supabase-managed, not created by this
-- migration). The policies below are scoped to this bucket only via
-- `bucket_id = 'miner-icons'` and never touch objects in any other
-- bucket.
--
-- Read: anyone (anon and authenticated — i.e. the Mini App, whether
-- or not the player has a session yet) may SELECT objects in this
-- bucket, matching the bucket's public-read intent in requirement 13.
-- This mirrors the public object URL's own behavior, so the API and
-- the public URL stay consistent with each other.
--
-- Write: intentionally NO insert/update/delete policy is created for
-- anon or authenticated. With RLS enabled and no matching policy,
-- Postgres denies those operations to those roles by default — per
-- requirement 12 (no broad anonymous/public upload permissions) and
-- requirement 13 (uploads/deletes are a future admin-only Edge
-- Function's job). service_role bypasses RLS entirely, same as every
-- other server-authoritative table in this schema, and is the only
-- way objects can be written until that Edge Function exists.
drop policy if exists "miner_icons_public_read" on storage.objects;
create policy "miner_icons_public_read"
  on storage.objects
  for select
  to anon, authenticated
  using (bucket_id = 'miner-icons');
