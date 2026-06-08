import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import ws from "ws";

/**
 * Supabase client used by the API for server-side operations.
 * Uses the SERVICE ROLE key, which bypasses RLS — never expose this to
 * clients. Env vars:
 *
 *   SUPABASE_URL                 — e.g. https://pojhfkamzteleogxxfqj.supabase.co
 *   SUPABASE_SERVICE_ROLE_KEY    — service-role JWT from the Supabase dashboard
 *
 * If either is missing, `supabase` is null and the API falls back to the
 * in-memory seed snapshot.
 */

let _client: SupabaseClient | null = null;
let _checked = false;

export function getSupabase(): SupabaseClient | null {
  if (_checked) return _client;
  _checked = true;
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    console.log("[supabase] env not set — running in in-memory seed mode");
    return null;
  }
  _client = createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
    // Node 20 lacks native WebSocket — pass the ws package as the transport.
    realtime: { transport: ws } as any,
  });
  console.log("[supabase] connected to", url);
  return _client;
}

export function isSupabaseEnabled(): boolean {
  return getSupabase() !== null;
}
