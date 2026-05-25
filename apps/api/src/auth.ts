import { getSupabase } from "./supabase";
import type { AuthContext } from "./store";

/**
 * Resolve an AuthContext from an incoming request.
 *
 * Order of preference:
 *  1. `Authorization: Bearer <jwt>` — verified via Supabase Auth.
 *     Resolves to the user_id from the JWT subject + the corresponding
 *     public.users.external_id (so the rest of the codebase keeps using
 *     friendly string IDs).
 *  2. `x-user-id: <external_id>` — dev/test fallback used by recipient
 *     surfaces (e.g. /shared/:token routes) that don't require auth.
 *
 * Returns AuthContext with userID set to the external_id of the resolved
 * user, defaulting to "usr-theo" when nothing matches (offline-friendly).
 */
export async function authFromHeaders(
  headers: Record<string, string | string[] | undefined>
): Promise<AuthContext> {
  const authHeader = pickHeader(headers, "authorization");
  if (authHeader && /^bearer /i.test(authHeader)) {
    const token = authHeader.slice(7).trim();
    const supabase = getSupabase();
    if (supabase) {
      try {
        const { data, error } = await supabase.auth.getUser(token);
        if (!error && data.user) {
          const authUid = data.user.id;
          const userRes = await supabase
            .from("users")
            .select("external_id, user_id")
            .eq("user_id", authUid)
            .maybeSingle();
          const external = (userRes.data as { external_id?: string } | null)?.external_id;
          if (external) return { userID: external };
          // No matching public.users row yet — fall back to the auth uid so the
          // request doesn't fail. The handle_new_auth_user trigger should
          // normally have written this row.
          return { userID: authUid };
        }
      } catch (err) {
        console.warn("[auth] JWT verify failed:", err);
      }
    }
  }

  const headerUid = pickHeader(headers, "x-user-id");
  return { userID: headerUid ?? "usr-theo" };
}

function pickHeader(
  headers: Record<string, string | string[] | undefined>,
  name: string
): string | undefined {
  const v = headers[name];
  if (Array.isArray(v)) return v[0];
  return v ?? undefined;
}
