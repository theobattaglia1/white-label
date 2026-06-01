/**
 * Auth hardening tests — require mocking getSupabase so Supabase appears
 * enabled (returning a fake client), letting us exercise the fail-closed
 * paths that the original tests (with Supabase disabled) cannot reach.
 *
 * Covers:
 *  A. Bearer + Supabase-enabled + getUser returns error in-band  → 401
 *  B. Bearer + Supabase-enabled + getUser throws                 → 503
 *  C. REQUIRE_JWT_AUTH=true + no Bearer on protected route       → 401
 *  D. REQUIRE_JWT_AUTH unset  + no Bearer on protected route     → 2xx (behaviour-preserved)
 *  E. PATCH /songs/:id ignores a non-allowlisted field
 *  F. GET /me with unknown identity does NOT leak users[0]
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { buildApp } from "../server.js";
import { store } from "../store.js";
import { authFromHeaders } from "../auth.js";

// ─── Mock supabase module ────────────────────────────────────────────────────
// Use vi.hoisted() so the mock variables are available inside the vi.mock
// factory (which is hoisted to the top of the file before any imports).

const { mockGetUser, mockFrom } = vi.hoisted(() => ({
  mockGetUser: vi.fn(),
  mockFrom: vi.fn(),
}));

vi.mock("../supabase.js", () => ({
  getSupabase: vi.fn(() => ({
    auth: { getUser: mockGetUser },
    from: mockFrom,
  })),
  isSupabaseEnabled: vi.fn(() => true),
}));

// ─── Seed IDs ────────────────────────────────────────────────────────────────

const SEED = {
  workspace: "wsp-amf-private",
  song: "song-midnight",
  version: "ver-midnight-v2",
} as const;

let app: Awaited<ReturnType<typeof buildApp>>;

beforeEach(async () => {
  if (!app) {
    app = await buildApp();
  }
  store.reset();
  vi.clearAllMocks();
  // Restore default REQUIRE_JWT_AUTH to unset
  delete process.env.REQUIRE_JWT_AUTH;
});

afterEach(() => {
  delete process.env.REQUIRE_JWT_AUTH;
});

// ─── A. Bearer + Supabase enabled + getUser returns in-band error → 401 ─────

describe("Bearer token rejected by Supabase → 401", () => {
  it("responds 401 when getUser returns an in-band error", async () => {
    mockGetUser.mockResolvedValue({ data: { user: null }, error: { message: "invalid JWT" } });

    const res = await app.inject({
      method: "POST",
      url: "/playlists",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer bad-token",
      },
      body: JSON.stringify({ workspace_id: SEED.workspace, title: "Test" }),
    });

    expect(res.statusCode).toBe(401);
    const body = res.json<{ error: string }>();
    expect(body.error).toMatch(/invalid|expired|token/i);
  });

  it("responds 401 when getUser returns a user=null with no error", async () => {
    mockGetUser.mockResolvedValue({ data: { user: null }, error: null });

    const res = await app.inject({
      method: "POST",
      url: "/links",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer token-no-user",
      },
      body: JSON.stringify({ workspace_id: SEED.workspace, target_type: "song", target_id: SEED.song }),
    });

    expect(res.statusCode).toBe(401);
  });
});

// ─── B. Bearer + Supabase enabled + getUser throws → 503 ─────────────────────

describe("getUser throws (network error) → 503", () => {
  it("responds 503 when getUser rejects", async () => {
    mockGetUser.mockRejectedValue(new Error("network failure"));

    const res = await app.inject({
      method: "POST",
      url: "/playlists",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer some-token",
      },
      body: JSON.stringify({ workspace_id: SEED.workspace, title: "Test" }),
    });

    expect(res.statusCode).toBe(503);
    const body = res.json<{ error: string }>();
    expect(body.error).toMatch(/unavailable|timed out/i);
  });
});

// ─── C. REQUIRE_JWT_AUTH=true + no Bearer → 401 ──────────────────────────────

describe("REQUIRE_JWT_AUTH=true strict mode", () => {
  beforeEach(() => {
    process.env.REQUIRE_JWT_AUTH = "true";
  });

  it("responds 401 when no Bearer token on a protected route", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/playlists",
      headers: {
        "content-type": "application/json",
        "x-user-id": "usr-theo",
      },
      body: JSON.stringify({ workspace_id: SEED.workspace, title: "Strict-mode test" }),
    });

    expect(res.statusCode).toBe(401);
    const body = res.json<{ error: string }>();
    expect(body.error).toMatch(/authentication required|Bearer/i);
  });

  it("responds 401 when no auth headers at all on a protected route", async () => {
    const res = await app.inject({
      method: "DELETE",
      url: `/playlists/any-id`,
      headers: { "content-type": "application/json" },
    });

    expect(res.statusCode).toBe(401);
  });
});

// ─── D. REQUIRE_JWT_AUTH unset → behaviour-preserved (x-user-id still works) ─

describe("REQUIRE_JWT_AUTH unset — behaviour-preserving", () => {
  it("2xx with only x-user-id on a protected route when Supabase enabled but no Bearer", async () => {
    // getSupabase returns the fake client but no Bearer → strict mode is OFF
    // so authFromHeaders falls to x-user-id fallback
    const res = await app.inject({
      method: "POST",
      url: "/playlists",
      headers: {
        "content-type": "application/json",
        "x-user-id": "usr-maya",
      },
      body: JSON.stringify({ workspace_id: SEED.workspace, title: "Non-strict test" }),
    });

    // When no bearer is sent, authFromHeaders falls to x-user-id regardless of
    // whether Supabase is configured — the strict guard is the only thing that
    // would block it
    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { created_by: string } }>();
    expect(body.data.created_by).toBe("usr-maya");
  });
});

// ─── E. PATCH /songs/:id ignores non-allowlisted field ───────────────────────

describe("PATCH /songs/:id mass-assignment prevention", () => {
  it("silently ignores a non-allowlisted field (e.g. created_by)", async () => {
    // Need a valid token for this route since Supabase is mocked as enabled
    // Make getUser return a valid user so the JWT path succeeds
    mockGetUser.mockResolvedValue({ data: { user: { id: "uuid-theo" } }, error: null });
    // Mock the public.users lookup to return an external_id
    mockFrom.mockReturnValue({
      select: () => ({
        eq: () => ({
          maybeSingle: () => Promise.resolve({ data: { external_id: "usr-theo" }, error: null }),
        }),
      }),
    });

    const originalSong = store.data.songs.find((s) => s.song_id === SEED.song);
    expect(originalSong).toBeDefined();
    const originalCreatedBy = (originalSong as unknown as Record<string, unknown>)["created_by"];

    const res = await app.inject({
      method: "PATCH",
      url: `/songs/${SEED.song}`,
      headers: {
        "content-type": "application/json",
        authorization: "Bearer valid-token",
      },
      body: JSON.stringify({
        title: "New Title",
        // Non-allowlisted: should be ignored
        created_by: "attacker",
        workspace_id: "evil-workspace",
        song_id: "tampered-id",
      }),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { song: Record<string, unknown> } }>();
    const patchedSong = body.data.song;

    // Allowlisted field was applied
    expect(patchedSong["title"]).toBe("New Title");
    // Non-allowlisted fields were NOT applied
    expect(patchedSong["created_by"]).toBe(originalCreatedBy);
    expect(patchedSong["song_id"]).toBe(SEED.song);
    expect(patchedSong["workspace_id"]).toBe(originalSong!.workspace_id);
  });

  it("only applies fields in the allowlist — unknown fields are dropped", async () => {
    mockGetUser.mockResolvedValue({ data: { user: { id: "uuid-theo" } }, error: null });
    mockFrom.mockReturnValue({
      select: () => ({
        eq: () => ({
          maybeSingle: () => Promise.resolve({ data: { external_id: "usr-theo" }, error: null }),
        }),
      }),
    });

    const res = await app.inject({
      method: "PATCH",
      url: `/songs/${SEED.song}`,
      headers: {
        "content-type": "application/json",
        authorization: "Bearer valid-token",
      },
      body: JSON.stringify({
        status: "approved",
        __proto__: { polluted: true },
        is_admin: true,
      }),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { song: Record<string, unknown> } }>();
    expect(body.data.song["status"]).toBe("approved");
    expect(body.data.song["is_admin"]).toBeUndefined();
  });
});

// ─── F. GET /me with unknown identity does NOT leak users[0] ─────────────────

describe("GET /me identity-leak prevention", () => {
  it("returns 404 for an identity that exists in no public.users row", async () => {
    mockGetUser.mockResolvedValue({ data: { user: { id: "uuid-unknown" } }, error: null });
    // Mock users lookup returns null (no matching row)
    mockFrom.mockReturnValue({
      select: () => ({
        eq: () => ({
          maybeSingle: () => Promise.resolve({ data: null, error: null }),
        }),
      }),
    });

    // The auth UID "uuid-unknown" has no external_id, so userID becomes the raw UUID.
    // The store has no user with user_id === "uuid-unknown" → me() returns null user.
    const res = await app.inject({
      method: "GET",
      url: "/me",
      headers: {
        authorization: "Bearer token-for-unknown-user",
      },
    });

    expect(res.statusCode).toBe(404);
    const body = res.json<{ error: string }>();
    expect(body.error).toBeTruthy();
  });

  it("does NOT return users[0] when x-user-id maps to no known user", async () => {
    // No Bearer — uses x-user-id fallback path (getSupabase won't be consulted)
    // Use a completely unknown user ID
    const res = await app.inject({
      method: "GET",
      url: "/me",
      headers: { "x-user-id": "usr-does-not-exist-xyz" },
    });

    expect(res.statusCode).toBe(404);
    const body = res.json<Record<string, unknown>>();
    // Must NOT contain a leaked user object
    expect((body["data"] as Record<string, unknown> | undefined)?.["user"]).toBeFalsy();
  });
});

// ─── G. users lookup queries auth_uid column (not user_id) ───────────────────
// These tests exercise authFromHeaders directly so they can capture the exact
// arguments passed to .select() and .eq() — validating the 0005-migration
// column rename at the JS layer.

describe("users lookup uses auth_uid column and returns external_id (migration 0005)", () => {
  it("resolves to external_id when auth_uid row exists", async () => {
    // Capture the arguments passed into the Supabase query chain.
    const maybeSingleFn = vi.fn().mockResolvedValue({
      data: { external_id: "usr-theo" },
      error: null,
    });
    const eqFn = vi.fn().mockReturnValue({ maybeSingle: maybeSingleFn });
    const selectFn = vi.fn().mockReturnValue({ eq: eqFn });
    mockFrom.mockReturnValue({ select: selectFn });

    mockGetUser.mockResolvedValue({
      data: { user: { id: "supabase-uuid-abc" } },
      error: null,
    });

    const ctx = await authFromHeaders({
      authorization: "Bearer valid-jwt",
    });

    // Result: external_id is returned as the resolved identity
    expect(ctx.userID).toBe("usr-theo");

    // The query selected only external_id (not "external_id, user_id")
    expect(selectFn).toHaveBeenCalledWith("external_id");

    // The filter used auth_uid (not user_id) with the Supabase auth UID
    expect(eqFn).toHaveBeenCalledWith("auth_uid", "supabase-uuid-abc");
  });

  it("falls back to the raw auth UID when no public.users row matches", async () => {
    const maybeSingleFn = vi.fn().mockResolvedValue({ data: null, error: null });
    const eqFn = vi.fn().mockReturnValue({ maybeSingle: maybeSingleFn });
    const selectFn = vi.fn().mockReturnValue({ eq: eqFn });
    mockFrom.mockReturnValue({ select: selectFn });

    mockGetUser.mockResolvedValue({
      data: { user: { id: "supabase-uuid-unlinked" } },
      error: null,
    });

    const ctx = await authFromHeaders({
      authorization: "Bearer valid-jwt-unlinked",
    });

    // Falls back to the raw auth UID rather than 500ing or leaking another user
    expect(ctx.userID).toBe("supabase-uuid-unlinked");

    // Column names are still correct even on the no-match path
    expect(selectFn).toHaveBeenCalledWith("external_id");
    expect(eqFn).toHaveBeenCalledWith("auth_uid", "supabase-uuid-unlinked");
  });
});
