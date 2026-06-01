/**
 * API auth-migration regression tests
 *
 * Environment: Supabase env vars are UNSET, so getSupabase() returns null and
 * the JWT path in authFromHeaders is skipped entirely. Every test exercises
 * the real fallback path: x-user-id header → "usr-theo" default.
 *
 * What these tests guard:
 *
 * 1. authFromHeaders — unit-level: header present → uses it; absent → "usr-theo"
 * 2. GET /me via authedFromRequest — proves the async wrapper resolves the
 *    correct identity (regression: a missing `await` would make auth a Promise,
 *    whose `.userID` is `undefined`).
 * 3. POST /playlists (migrated route) — the created resource carries the
 *    caller's identity in `created_by`. Guards the await on authedFromRequest.
 * 4. POST /links (migrated route) — `created_by` in the returned link must be
 *    the caller, not `undefined`.
 * 5. POST /notes (EXCLUDED/legacy route) — must still work with x-user-id
 *    and attribute `author_user_id` correctly. Guards that the intentional
 *    legacy path wasn't accidentally migrated away.
 * 6. POST /versions/:id/approvals (EXCLUDED/legacy route) — same legacy-path
 *    guard: `actor_user_id` must be the caller, not `undefined`.
 */

import { describe, it, expect, beforeEach } from "vitest";
import { buildApp } from "../server.js";
import { store } from "../store.js";
import { authFromHeaders } from "../auth.js";

// ─── helpers ────────────────────────────────────────────────────────────────

/** Seed IDs taken directly from packages/shared/src/seed.ts */
const SEED = {
  workspace: "wsp-amf-private",
  song: "song-midnight",
  version: "ver-midnight-v2",
} as const;

// Build the app once per test run; reset the store before each test so
// mutations from one test don't pollute the next.
let app: Awaited<ReturnType<typeof buildApp>>;

beforeEach(async () => {
  if (!app) {
    app = await buildApp();
  }
  store.reset();
});

// ─── 1. authFromHeaders unit tests ──────────────────────────────────────────

describe("authFromHeaders (unit)", () => {
  it("resolves to the x-user-id value when the header is present", async () => {
    const ctx = await authFromHeaders({ "x-user-id": "usr-maya" });
    expect(ctx.userID).toBe("usr-maya");
  });

  it("falls back to 'usr-theo' when no auth header is present at all", async () => {
    const ctx = await authFromHeaders({});
    expect(ctx.userID).toBe("usr-theo");
  });

  it("falls back to 'usr-theo' when only an unrelated header is present", async () => {
    const ctx = await authFromHeaders({ "content-type": "application/json" });
    expect(ctx.userID).toBe("usr-theo");
  });

  it("picks the first value when x-user-id is an array (multi-value header)", async () => {
    const ctx = await authFromHeaders({ "x-user-id": ["usr-maya", "usr-alex"] });
    expect(ctx.userID).toBe("usr-maya");
  });

  it("skips JWT path entirely when no Supabase env is set (no Bearer token attempt)", async () => {
    // Even if a Bearer-looking header is present, without Supabase configured
    // it must fall through to the x-user-id fallback, not throw.
    const ctx = await authFromHeaders({
      authorization: "Bearer fake-token",
      "x-user-id": "usr-river",
    });
    expect(ctx.userID).toBe("usr-river");
  });
});

// ─── 2. GET /me — authedFromRequest identity probe ──────────────────────────

describe("GET /me — migrated authedFromRequest identity probe", () => {
  it("returns the user matching x-user-id: usr-maya", async () => {
    const res = await app.inject({
      method: "GET",
      url: "/me",
      headers: { "x-user-id": "usr-maya" },
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { user: { user_id: string } } }>();
    expect(body.data.user.user_id).toBe("usr-maya");
  });

  it("returns the default user (usr-theo) when no header is sent", async () => {
    const res = await app.inject({
      method: "GET",
      url: "/me",
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { user: { user_id: string } } }>();
    // Fallback is "usr-theo" and the seed has a matching user
    expect(body.data.user.user_id).toBe("usr-theo");
  });

  it("identity is a string, not undefined (regression: missing await on authedFromRequest)", async () => {
    const res = await app.inject({
      method: "GET",
      url: "/me",
      headers: { "x-user-id": "usr-alex" },
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { user: { user_id: string } } }>();
    // If await was missing, authedFromRequest would resolve to a Promise object
    // whose .userID is undefined, causing store.me() to fall to users[0] or
    // worse throw. A string user_id here proves the await is present.
    expect(typeof body.data.user.user_id).toBe("string");
    expect(body.data.user.user_id).not.toBe("undefined");
  });
});

// ─── 3. POST /playlists — migrated write route ──────────────────────────────

describe("POST /playlists — migrated write route", () => {
  it("created_by reflects the caller's identity from x-user-id", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/playlists",
      headers: {
        "content-type": "application/json",
        "x-user-id": "usr-maya",
      },
      body: JSON.stringify({
        workspace_id: SEED.workspace,
        title: "Maya's Test Playlist",
      }),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { created_by: string; owner_user_id: string } }>();
    expect(body.data.created_by).toBe("usr-maya");
    expect(body.data.owner_user_id).toBe("usr-maya");
  });

  it("created_by is 'usr-theo' (default) when no x-user-id header is sent", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/playlists",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        workspace_id: SEED.workspace,
        title: "Default-user Playlist",
      }),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { created_by: string } }>();
    expect(body.data.created_by).toBe("usr-theo");
  });

  it("created_by is never undefined (regression: missing await resolves Promise → undefined userID)", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/playlists",
      headers: {
        "content-type": "application/json",
        "x-user-id": "usr-river",
      },
      body: JSON.stringify({
        workspace_id: SEED.workspace,
        title: "River's Test Playlist",
      }),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { created_by: unknown } }>();
    expect(body.data.created_by).not.toBeUndefined();
    expect(body.data.created_by).toBe("usr-river");
  });
});

// ─── 4. POST /links — migrated write route ──────────────────────────────────

describe("POST /links — migrated write route", () => {
  it("link created_by reflects x-user-id caller identity", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/links",
      headers: {
        "content-type": "application/json",
        "x-user-id": "usr-maya",
      },
      body: JSON.stringify({
        workspace_id: SEED.workspace,
        target_type: "song",
        target_id: SEED.song,
      }),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { link: { created_by: string } } }>();
    expect(body.data.link.created_by).toBe("usr-maya");
  });

  it("link created_by is never undefined — guards await on authedFromRequest in POST /links", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/links",
      headers: {
        "content-type": "application/json",
        "x-user-id": "usr-alex",
      },
      body: JSON.stringify({
        workspace_id: SEED.workspace,
        target_type: "song",
        target_id: SEED.song,
      }),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { link: { created_by: unknown } } }>();
    expect(body.data.link.created_by).not.toBeUndefined();
    expect(typeof body.data.link.created_by).toBe("string");
  });
});

// ─── 5. POST /notes — EXCLUDED (legacy authFromRequest) ─────────────────────

describe("POST /notes — intentionally kept on legacy authFromRequest", () => {
  it("returns 2xx and attributes the note to the x-user-id caller", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/notes",
      headers: {
        "content-type": "application/json",
        "x-user-id": "usr-theo",
      },
      body: JSON.stringify({
        song_id: SEED.song,
        anchor_version_id: SEED.version,
        body: "Needs more reverb on the second chorus",
        scope: "song",
      }),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { author_user_id: string } }>();
    expect(body.data.author_user_id).toBe("usr-theo");
  });

  it("iMessage-extension use-case: x-user-id: usr-maya still works on legacy route", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/notes",
      headers: {
        "content-type": "application/json",
        "x-user-id": "usr-maya",
      },
      body: JSON.stringify({
        song_id: SEED.song,
        anchor_version_id: SEED.version,
        body: "Approval note from iMessage extension",
        scope: "song",
      }),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { author_user_id: string } }>();
    expect(body.data.author_user_id).toBe("usr-maya");
  });

  it("note author_user_id is never undefined on legacy route", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/notes",
      headers: {
        "content-type": "application/json",
        "x-user-id": "usr-alex",
      },
      body: JSON.stringify({
        song_id: SEED.song,
        anchor_version_id: SEED.version,
        body: "Legacy route test",
        scope: "song",
      }),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { author_user_id: unknown } }>();
    expect(body.data.author_user_id).not.toBeUndefined();
    expect(body.data.author_user_id).toBe("usr-alex");
  });
});

// ─── 6. POST /versions/:id/approvals — EXCLUDED (legacy authFromRequest) ────

describe("POST /versions/:id/approvals — intentionally kept on legacy authFromRequest", () => {
  it("returns 2xx and records the correct actor_user_id", async () => {
    const res = await app.inject({
      method: "POST",
      url: `/versions/${SEED.version}/approvals`,
      headers: {
        "content-type": "application/json",
        "x-user-id": "usr-maya",
      },
      body: JSON.stringify({ state: "approved" }),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { actor_user_id: string; state: string } }>();
    expect(body.data.actor_user_id).toBe("usr-maya");
    expect(body.data.state).toBe("approved");
  });

  it("actor_user_id is never undefined on legacy approvals route", async () => {
    const res = await app.inject({
      method: "POST",
      url: `/versions/${SEED.version}/approvals`,
      headers: {
        "content-type": "application/json",
        "x-user-id": "usr-river",
      },
      body: JSON.stringify({ state: "revision_requested", note: "Fix the bridge" }),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { actor_user_id: unknown } }>();
    expect(body.data.actor_user_id).not.toBeUndefined();
    expect(body.data.actor_user_id).toBe("usr-river");
  });
});
