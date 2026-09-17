// Pro-X Network — Supabase admin client factory.
//
// Wraps supabase-js configured with the service_role key. This
// bypasses Row Level Security, so it must only ever be used inside
// Edge Functions (server-side), never sent to or usable by the
// frontend — SUPABASE_SERVICE_ROLE_KEY lives in Supabase secrets
// only (see backend/README.md).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getSupabaseAdminEnv } from "./env.ts";

let cached: SupabaseClient | null = null;

export function getSupabaseAdmin(): SupabaseClient {
  if (cached) return cached;
  const { url, serviceRoleKey } = getSupabaseAdminEnv();
  cached = createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return cached;
}
