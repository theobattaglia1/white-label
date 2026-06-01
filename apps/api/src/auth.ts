import { createHash, timingSafeEqual } from "node:crypto";
import { getSupabase } from "./supabase";
import type { AuthContext } from "./store";

// ---------------------------------------------------------------------------
// AuthError — thrown when a presented Bearer token cannot be verified.
// The route layer maps httpStatus to the HTTP response status code.
// ---------------------------------------------------------------------------

export class AuthError extends Error {
  readonly httpStatus: number;
  constructor(message: string, httpStatus: number) {
    super(message);
    this.name = "AuthError";
    this.httpStatus = httpStatus;
  }
}

// Timeout for the full JWT-verification round-trip (getUser + users lookup).
const AUTH_TIMEOUT_MS = 3000;

/**
 * Wrap a promise (or PromiseLike) with a hard timeout.
 * Rejects with AuthError(503) on expiry.
 */
function withTimeout<T>(promise: PromiseLike<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => reject(new AuthError("Auth service timed out", 503)),
      ms,
    );
  });
  // Always clear the timer so a fast-resolving promise doesn't leave a
  // dangling 3s handle on every auth call (resource leak + keeps the event
  // loop / test workers alive).
  return Promise.race([Promise.resolve(promise), timeout]).finally(() =>
    clearTimeout(timer),
  );
}

/**
 * Resolve an AuthContext from an incoming request.
 *
 * State machine:
 *
 * 1. NO Authorization: Bearer header present
 *    → fall back to x-user-id ?? "usr-theo" (dev/offline/iMessage).
 *
 * 2. Bearer present, Supabase DISABLED (getSupabase() === null)
 *    → fall back to x-user-id ?? "usr-theo"
 *    (We cannot verify; keep offline dev behaviour. An existing test asserts this.)
 *
 * 3. Bearer present + Supabase ENABLED + token VALID (getUser ok + user present)
 *    → resolve external_id from public.users, or raw auth UID as fallback.
 *
 * 4. Bearer present + Supabase ENABLED + token REJECTED
 *    (getUser returns { error } in-band, or no user in data)
 *    → throw AuthError(401).
 *
 * 5. Bearer present + Supabase ENABLED + getUser THROWS or TIMES OUT
 *    → throw AuthError(503). Do NOT silently downgrade to x-user-id.
 */
export async function authFromHeaders(
  headers: Record<string, string | string[] | undefined>,
): Promise<AuthContext> {
  const authHeader = pickHeader(headers, "authorization");

  if (!authHeader || !/^bearer /i.test(authHeader)) {
    // Case 1 — no Bearer header at all
    const headerUid = pickHeader(headers, "x-user-id");
    return { userID: headerUid ?? "usr-theo" };
  }

  const token = authHeader.slice(7).trim();
  const supabase = getSupabase();

  if (!supabase) {
    // Case 2 — Bearer present but Supabase not configured; fall back gracefully
    const headerUid = pickHeader(headers, "x-user-id");
    return { userID: headerUid ?? "usr-theo" };
  }

  // Cases 3 / 4 / 5 — Supabase is live; must not fall back to x-user-id
  let getUserResult: Awaited<ReturnType<typeof supabase.auth.getUser>>;
  try {
    getUserResult = await withTimeout(supabase.auth.getUser(token), AUTH_TIMEOUT_MS);
  } catch (err) {
    if (err instanceof AuthError) throw err;
    // Unexpected throw from supabase client → 503
    throw new AuthError("Auth service unavailable", 503);
  }

  const { data, error } = getUserResult;

  if (error || !data.user) {
    // Case 4 — token was presented but rejected in-band
    throw new AuthError("Invalid or expired token", 401);
  }

  // Token is valid — resolve to the external_id of the PRE-PROVISIONED user row.
  // Identity is bridged by users.auth_uid, set by handle_new_auth_user on first
  // sign-in via email relink (migration 0005). We match on auth_uid, NOT user_id:
  // user_id is the app-generated PK that memberships/songs/notes reference and is
  // NOT the Supabase auth UID. (Requires 0005 applied before this serves traffic.)
  const authUid = data.user.id;
  try {
    const userQuery = supabase
      .from("users")
      .select("external_id")
      .eq("auth_uid", authUid)
      .maybeSingle();
    const userRes = await withTimeout(Promise.resolve(userQuery), AUTH_TIMEOUT_MS);
    const external = (userRes.data as { external_id?: string } | null)
      ?.external_id;
    if (external) return { userID: external };
    // Not yet relinked (user hasn't completed email-matched sign-in, or is a
    // brand-new account mid-provision). Fall back to the raw auth UID rather than
    // 500ing — they resolve to a memberless identity (fail-closed at authz),
    // never to someone else's data.
    return { userID: authUid };
  } catch (err) {
    if (err instanceof AuthError) throw err;
    // Timeout or throw during users lookup → 503
    throw new AuthError("Auth service unavailable", 503);
  }
}

// ---------------------------------------------------------------------------
// requireAuthedFromRequest — like authFromHeaders but enforces JWT when
// REQUIRE_JWT_AUTH=true and Supabase is configured.
//
// When REQUIRE_JWT_AUTH=true + Supabase enabled + no Bearer header was
// provided, this throws AuthError(401) instead of accepting the x-user-id
// fallback. This closes the x-user-id bypass in hardened environments.
//
// Default: REQUIRE_JWT_AUTH is unset → behaviour-preserving (same as
// authFromHeaders).
// ---------------------------------------------------------------------------

export async function requireAuthedFromHeaders(
  headers: Record<string, string | string[] | undefined>,
): Promise<AuthContext> {
  const strictMode = process.env.REQUIRE_JWT_AUTH === "true";

  if (strictMode && getSupabase() !== null) {
    const authHeader = pickHeader(headers, "authorization");
    if (!authHeader || !/^bearer /i.test(authHeader)) {
      throw new AuthError(
        "Authentication required: Bearer token missing",
        401,
      );
    }
  }

  return authFromHeaders(headers);
}

// ---------------------------------------------------------------------------
// assertInternalSecret — shared-secret guard for the legacy x-user-id routes
// (POST /notes, POST /versions/:id/approvals) that the iMessage extension uses.
// Those routes trust a caller-supplied x-user-id with no verification, so any
// client could POST as `usr-theo`. When INTERNAL_WRITE_SECRET is set, every such
// request must carry a matching `x-internal-secret` header. When the env is
// UNSET, this is a no-op — so it's safe to deploy BEFORE the extension is
// updated to send the header (behaviour-preserving until you opt in).
// ---------------------------------------------------------------------------

export function assertInternalSecret(
  headers: Record<string, string | string[] | undefined>,
): void {
  const required = process.env.INTERNAL_WRITE_SECRET;
  if (!required) return; // unset ⇒ behaviour-preserving no-op
  const provided = pickHeader(headers, "x-internal-secret") ?? "";
  // Constant-time compare over fixed-length SHA-256 digests — avoids leaking the
  // secret's length or a byte-by-byte match position via response timing.
  const a = createHash("sha256").update(provided).digest();
  const b = createHash("sha256").update(required).digest();
  if (!timingSafeEqual(a, b)) {
    throw new AuthError("Invalid or missing internal secret", 401);
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function pickHeader(
  headers: Record<string, string | string[] | undefined>,
  name: string,
): string | undefined {
  const v = headers[name];
  if (Array.isArray(v)) return v[0];
  return v ?? undefined;
}
