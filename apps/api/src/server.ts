import cors from "@fastify/cors";
import Fastify, { type FastifyReply } from "fastify";
import { randomUUID } from "node:crypto";
import { store, type AuthContext } from "./store";
import {
  signUpload,
  finalizeUpload,
  finalizeNewSongUpload,
  signPlaybackUrl,
  type FinalizeNewSongInput,
  type FinalizeUploadInput,
  type SignUploadInput
} from "./uploads";
import { loadSnapshotFromSupabase } from "./supabase-loader";
import { getSupabase, isSupabaseEnabled } from "./supabase";
import { authFromHeaders, requireAuthedFromHeaders, assertInternalSecret, AuthError } from "./auth";
import { isAssistantLlmEnabled } from "./assistant";
import { rateLimit } from "./ratelimit";
import { persistSongPatch } from "./supabase-persist";
import {
  enqueueStemJob,
  isStemsWorkerEnabled,
  latestStemJobForVersion,
  liveStemJobForVersionOrAsset,
} from "./stems-worker";

/**
 * Builds and returns a fully-registered Fastify instance without binding a
 * port. Used by tests (via `inject()`) and by the normal boot path below.
 * The store is reset to a fresh seed so each test gets a clean slate when
 * they call `store.reset()` before injecting.
 */
export async function buildApp() {
const server = Fastify({ logger: false });

await server.register(cors, { origin: true });

/**
 * Legacy sync version, kept for routes that don't yet need verified auth
 * (recipient/shared endpoints, dev/reset). Use authFromHeaders for any
 * route that takes producer action.
 */
function authFromRequest(request: { headers: Record<string, string | string[] | undefined> }): AuthContext {
  const header = request.headers["x-user-id"];
  return { userID: Array.isArray(header) ? header[0] : header ?? "usr-theo" };
}

/**
 * Async, verified-JWT version. Use this for all owner-scoped mutation routes.
 *
 * JWT-capable routes (migrated to authedFromRequest + await):
 *   POST /playlists, POST /playlists/:id/items, DELETE /playlists/:id/items/:itemId,
 *   POST /playlists/:id/reorder, DELETE /playlists/:id,
 *   POST /songs/:id/versions, POST /versions/:id/set-current,
 *   PATCH /notes/:id, POST /notes/:id/convert-to-task,
 *   POST /links, PATCH /links/:id, POST /links/:id/revoke,
 *   PATCH /songs/:id, DELETE /songs/:id,
 *   POST /views, DELETE /views/:id
 *
 * Intentionally kept on legacy authFromRequest (x-user-id only, NO JWT):
 *   POST /notes          — iMessage extension (WLReceiptAPI) posts here with
 *                          x-user-id and cannot obtain a Supabase JWT (separate
 *                          sandbox, no App Group). See runbook 2026-05-29.
 *   POST /versions/:id/approvals — same sandbox constraint as above.
 *
 * Enforcement note: JWT verification is inert until SUPABASE_URL +
 * SUPABASE_SERVICE_ROLE_KEY are configured AND clients send a Bearer token.
 * Until then authedFromRequest gracefully falls back to x-user-id ?? "usr-theo",
 * making this swap completely behaviour-preserving in the current prod config.
 */
async function authedFromRequest(request: { headers: Record<string, string | string[] | undefined> }): Promise<AuthContext> {
  return authFromHeaders(request.headers);
}

/**
 * Strict-mode variant: when REQUIRE_JWT_AUTH=true + Supabase is enabled,
 * throws AuthError(401) if no Bearer token was provided (closes the
 * x-user-id bypass). Falls back to authedFromRequest behaviour otherwise.
 * Wire all 16 migrated owner-mutation routes to this.
 */
async function requireAuthedFromRequest(request: { headers: Record<string, string | string[] | undefined> }): Promise<AuthContext> {
  return requireAuthedFromHeaders(request.headers);
}

function ok<T>(value: T): { data: T } {
  return { data: value };
}

function isVisibleSong(song: { status?: string; deleted_at?: string | null }): boolean {
  return song.status !== "deleted" && !song.deleted_at;
}

server.get("/health", async () => ok({ status: "ok", product: "playback" }));

server.post("/internal/hydrate", async (request, reply) => {
  if (process.env.NODE_ENV === "production" && !process.env.INTERNAL_WRITE_SECRET) {
    return reply.code(404).send({ error: "Not found" });
  }
  assertInternalSecret(request.headers);
  if (!isSupabaseEnabled()) return reply.code(503).send({ error: "Requires Supabase" });
  await store.hydrate();
  const snapshot = store.data;
  return ok({
    hydrated: true,
    songs: snapshot.songs.length,
    versions: snapshot.versions.length,
    assets: snapshot.assets.length,
  });
});

// Destructive: wipes the in-memory snapshot back to seed. NEVER expose in
// production — an unauthenticated POST would let anyone reachable on the
// internet reset every connected client's workspace. Registered only outside
// production; tests call store.reset() directly, not this route.
if (process.env.NODE_ENV !== "production") {
  server.post("/dev/reset", async () => ok(store.reset()));
}

server.get("/me", async (request, reply) => {
  const auth = await requireAuthedFromRequest(request);
  let result = store.me(auth);
  if (!result.user && isSupabaseEnabled()) {
    // Brand-new invited user: their DB row was created by handle_new_auth_user()
    // but the in-memory store snapshot is stale. Re-hydrate once and retry.
    try {
      await store.hydrate();
      result = store.me(auth);
    } catch { /* hydrate failure — fall through to 404 below */ }
  }
  if (!result.user) {
    server.log.warn({ userID: auth.userID }, "GET /me: unknown identity — returning 404");
    return reply.code(404).send({ error: "User not found" });
  }
  const workspaceIDs = new Set(result.memberships.map((membership) => membership.workspace_id));
  return ok({
    ...result,
    workspaces: store.data.workspaces.filter((workspace) => workspaceIDs.has(workspace.workspace_id)),
  });
});

server.patch("/me", async (request, reply) => {
  const auth = await requireAuthedFromRequest(request);
  const body = request.body as { display_name?: string };
  const trimmed = body.display_name?.trim();
  if (!trimmed) return reply.code(400).send({ error: "display_name is required" });

  const idx = store.data.users.findIndex((u) => u.user_id === auth.userID);
  if (idx < 0) return reply.code(404).send({ error: "User not found" });

  store.data.users = store.data.users.map((u) =>
    u.user_id === auth.userID ? { ...u, display_name: trimmed } : u,
  );

  const supabase = getSupabase();
  if (supabase) {
    void supabase
      .from("users")
      .update({ display_name: trimmed })
      .eq("user_id", auth.userID);
  }

  return ok(store.data.users.find((u) => u.user_id === auth.userID));
});
server.get("/workspaces", async () => ok(store.data.workspaces));
server.get("/workspaces/:id", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.data.workspaces.find((workspace) => workspace.workspace_id === id));
});
server.get("/workspaces/:id/members", async (request) => {
  const { id } = request.params as { id: string };
  const membershipUserIDs = new Set(
    store.data.memberships
      .filter((m) => m.workspace_id === id)
      .map((m) => m.user_id),
  );
  // Enrich users with their workspace membership role (if any) so the
  // client can render "Maya Chen · Manager".
  const roleByUser = new Map(
    store.data.memberships
      .filter((m) => m.workspace_id === id)
      .map((m) => [m.user_id, m.role]),
  );
  const members = store.data.users
    .filter((u) => membershipUserIDs.has(u.user_id))
    .map((u) => ({
      user_id: u.user_id,
      display_name: u.display_name,
      role: roleByUser.get(u.user_id) ?? "Member",
      member_number: (u as unknown as { member_number?: number }).member_number ?? null,
    }));
  return ok(members);
});

// === Workspace invites (invite-only beta access) ========================

server.post("/workspaces/:id/invite", async (request, reply) => {
  await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  const body = request.body as { email?: string; role?: string; display_name?: string };

  if (!body?.email?.trim()) return reply.code(400).send({ error: "email is required" });

  const supabase = getSupabase();
  if (!supabase) return reply.code(503).send({ error: "Invites require Supabase to be configured" });

  const email = body.email.toLowerCase().trim();
  const role = body.role ?? "viewer";

  // Resolve workspace UUID
  const wsRes = await supabase.from("workspaces").select("workspace_id").eq("external_id", id).maybeSingle();
  if (!wsRes.data) return reply.code(404).send({ error: "Workspace not found" });
  const workspaceUuid = (wsRes.data as { workspace_id: string }).workspace_id;

  // Check whether this email already has a confirmed Playback account.
  // "Confirmed" means auth_uid is set — the trigger ran and linked them.
  const existingRes = await supabase
    .from("users")
    .select("user_id, auth_uid")
    .eq("email", email)
    .maybeSingle();
  const existing = existingRes.data as { user_id: string; auth_uid: string | null } | null;

  if (existing?.auth_uid) {
    // ── Path B: user already confirmed ──────────────────────────────────────
    // Grant membership immediately; no invite email needed.
    const memberRes = await supabase.from("memberships").upsert(
      { workspace_id: workspaceUuid, user_id: existing.user_id, role },
      { onConflict: "workspace_id,user_id" },
    );
    if (memberRes.error) {
      return reply.code(500).send({ error: `Could not grant membership: ${memberRes.error.message}` });
    }
    // Clean up any stale invite row for this email + workspace.
    await supabase.from("workspace_invites")
      .delete()
      .eq("workspace_id", workspaceUuid)
      .eq("email", email);
    // Refresh in-memory snapshot so the next GET /me sees the new membership.
    try { await store.hydrate(); } catch { /* non-fatal */ }
    server.log.info({ email, role }, "invite: existing confirmed user — membership granted immediately");
    return ok({ invited: true, email, role, invite_id: null, immediate: true });
  }

  // ── Path A: user doesn't exist yet ──────────────────────────────────────
  // Write the invite row; the handle_new_auth_user trigger will convert it
  // to a membership when they confirm their email after signing up.
  const upsertRes = await supabase.from("workspace_invites").upsert({
    workspace_id: workspaceUuid,
    email,
    role,
    display_name: body.display_name ?? null,
    invited_at: new Date().toISOString(),
  }, { onConflict: "workspace_id,email" }).select("invite_id").single();

  if (upsertRes.error) {
    return reply.code(500).send({ error: `Could not save invite: ${upsertRes.error.message}` });
  }

  // Send the magic-link invite email via Supabase Auth admin API.
  const appUrl = process.env.APP_URL ?? "https://playback-web.onrender.com";
  const { error: inviteError } = await supabase.auth.admin.inviteUserByEmail(email, {
    redirectTo: appUrl,
    data: { display_name: body.display_name ?? null, workspace_role: role },
  });

  if (inviteError) {
    server.log.warn({ email, err: inviteError.message }, "invite email warning — invite row saved, email failed");
  }

  return ok({ invited: true, email, role, invite_id: (upsertRes.data as { invite_id: string }).invite_id, immediate: false });
});

server.get("/workspaces/:id/invites", async (request, reply) => {
  await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };

  const supabase = getSupabase();
  if (!supabase) return ok([]);

  const wsRes = await supabase.from("workspaces").select("workspace_id").eq("external_id", id).maybeSingle();
  if (!wsRes.data) return reply.code(404).send({ error: "Workspace not found" });
  const workspaceUuid = (wsRes.data as { workspace_id: string }).workspace_id;

  const res = await supabase
    .from("workspace_invites")
    .select("invite_id, email, role, display_name, invited_by, invited_at")
    .eq("workspace_id", workspaceUuid)
    .order("invited_at", { ascending: false });

  return ok(res.data ?? []);
});

server.delete("/workspaces/:id/invites/:inviteId", async (request, reply) => {
  await requireAuthedFromRequest(request);
  const { id, inviteId } = request.params as { id: string; inviteId: string };

  const supabase = getSupabase();
  if (!supabase) return reply.code(503).send({ error: "Requires Supabase" });

  const wsRes = await supabase.from("workspaces").select("workspace_id").eq("external_id", id).maybeSingle();
  if (!wsRes.data) return reply.code(404).send({ error: "Workspace not found" });
  const workspaceUuid = (wsRes.data as { workspace_id: string }).workspace_id;

  await supabase.from("workspace_invites").delete().eq("invite_id", inviteId).eq("workspace_id", workspaceUuid);
  return ok({ revoked: true });
});

server.get("/workspaces/:id/rooms", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.listRooms(id));
});

/** Rooms enriched with their song-count + open-note-count — used to render
 *  the room switcher dropdown without doing N round-trips. */
server.get("/workspaces/:id/rooms-summary", async (request) => {
  const { id } = request.params as { id: string };
  const rooms = store.listRooms(id);
  const summary = rooms.map((room) => {
    const songs = store.data.songs.filter((s) => s.primary_room_id === room.room_id && isVisibleSong(s));
    const songIDs = new Set(songs.map((s) => s.song_id));
    const openNotes = store.data.notes.filter(
      (n) => n.status === "open" && songIDs.has(n.song_id),
    );
    return {
      ...room,
      song_count: songs.length,
      open_note_count: openNotes.length,
    };
  });
  return ok(summary);
});

/** Saved smart-views (queries against the library). Surfaced as
 *  smart-playlists in the sidebar. */
server.get("/workspaces/:id/saved-views", async (request) => {
  const { id } = request.params as { id: string };
  const views = store.data.savedViews.filter((v) => v.workspace_id === id);
  return ok(views);
});

/** All playlists in the workspace. Each is enriched with its item-count
 *  and a small preview (first 3 song titles) for the picker rendering. */
server.get("/workspaces/:id/playlists", async (request) => {
  const { id } = request.params as { id: string };
  const playlists = store.data.playlists.filter((p) => p.workspace_id === id);
  const songByID = new Map(store.data.songs.map((s) => [s.song_id, s]));
  const items = store.data.playlistItems;
  const enriched = playlists.map((p) => {
    const own = items
      .filter((it) => it.playlist_id === p.playlist_id)
      .sort((a, b) => a.position - b.position);
    return {
      ...p,
      item_count: own.length,
      preview_titles: own.slice(0, 3).map((it) => songByID.get(it.song_id)?.title ?? "").filter((t): t is string => t.length > 0),
    };
  });
  return ok(enriched);
});

/** One playlist + its ordered items + each item's song / version / asset. */
server.get("/playlists/:id", async (request) => {
  const { id } = request.params as { id: string };
  const playlist = store.data.playlists.find((p) => p.playlist_id === id);
  if (!playlist) throw new Error("Playlist not found");
  const ownItems = store.data.playlistItems
    .filter((it) => it.playlist_id === id)
    .sort((a, b) => a.position - b.position);
  const songByID = new Map(store.data.songs.map((s) => [s.song_id, s]));
  const versionByID = new Map(store.data.versions.map((v) => [v.version_id, v]));
  const assetByID = new Map(store.data.assets.map((a) => [a.asset_id, a]));
  const items = ownItems.map((it) => {
    const song = songByID.get(it.song_id);
    const current = song?.current_version_id ? versionByID.get(song.current_version_id) : undefined;
    const asset = current ? assetByID.get(current.file_asset_id) : undefined;
    return {
      item: it,
      song: song ?? null,
      current_version: current ?? null,
      asset: asset ?? null,
    };
  });
  return ok({ playlist, items });
});

server.post("/playlists", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const body = request.body as {
    workspace_id: string;
    title: string;
    description?: string;
    owner_user_id?: string;
  };
  const playlist = {
    playlist_id: `playlist-${randomUUID()}`,
    workspace_id: body.workspace_id,
    owner_user_id: body.owner_user_id ?? auth.userID,
    title: body.title,
    description: body.description,
    cover_seed: `${body.title.toLowerCase().replace(/\s+/g, "-")}-${Date.now()}`,
    is_pinned: false,
    created_by: auth.userID,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
  store.data.playlists.push(playlist);
  return ok(playlist);
});

server.post("/playlists/:id/items", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  const body = request.body as { song_id: string; note?: string };
  const existing = store.data.playlistItems.filter((it) => it.playlist_id === id);
  const nextPosition = (existing.reduce((max, it) => Math.max(max, it.position), 0)) + 1;
  const item = {
    playlist_item_id: `pli-${randomUUID()}`,
    playlist_id: id,
    song_id: body.song_id,
    position: nextPosition,
    added_by: auth.userID,
    added_at: new Date().toISOString(),
    note: body.note,
  };
  store.data.playlistItems.push(item);
  return ok(item);
});

server.delete("/playlists/:id/items/:itemId", async (request) => {
  await requireAuthedFromRequest(request);
  const { itemId } = request.params as { id: string; itemId: string };
  const before = store.data.playlistItems.length;
  store.data.playlistItems = store.data.playlistItems.filter(
    (it) => it.playlist_item_id !== itemId,
  );
  return ok({ removed: before - store.data.playlistItems.length });
});

/** Bulk reorder — client sends the new ordered list of item ids and
 *  the server rewrites positions accordingly. */
server.post("/playlists/:id/reorder", async (request) => {
  await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  const body = request.body as { item_ids: string[] };
  const orderByID = new Map(body.item_ids.map((itemId, idx) => [itemId, idx + 1]));
  store.data.playlistItems = store.data.playlistItems.map((it) => {
    if (it.playlist_id !== id) return it;
    const nextPos = orderByID.get(it.playlist_item_id);
    return nextPos ? { ...it, position: nextPos } : it;
  });
  return ok({ reordered: orderByID.size });
});

server.delete("/playlists/:id", async (request) => {
  await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  store.data.playlists = store.data.playlists.filter((p) => p.playlist_id !== id);
  store.data.playlistItems = store.data.playlistItems.filter((it) => it.playlist_id !== id);
  return ok({ removed: true });
});

/** Workspace-wide library. Every song in the workspace plus its room +
 *  current version + asset, suitable for an "All Songs" surface. */
server.get("/workspaces/:id/library", async (request) => {
  const { id } = request.params as { id: string };
  const songs = store.data.songs.filter((s) => s.workspace_id === id && isVisibleSong(s));
  const roomByID = new Map(store.data.rooms.map((r) => [r.room_id, r]));
  const items = songs.map((song) => {
    const current = store.data.versions.find((v) => v.version_id === song.current_version_id);
    const asset = current
      ? store.data.assets.find((a) => a.asset_id === current.file_asset_id)
      : undefined;
    const room = song.primary_room_id ? roomByID.get(song.primary_room_id) : undefined;
    return {
      song,
      room: room ? { room_id: room.room_id, title: room.title, type: room.type } : null,
      current_version: current ?? null,
      asset: asset ?? null,
    };
  });
  return ok(items);
});
server.get("/workspaces/:id/tasks", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.data.tasks.filter((task) => task.workspace_id === id));
});
server.get("/workspaces/:id/activity", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.data.activityEvents.filter((event) => event.workspace_id === id));
});

// ===== Server-side pins (per user, per workspace) =======================

/** The caller's pin list — "type:id" strings matching the iOS PinRef
 *  encoding (e.g. "song:song-1"). Identity-scoped, so reads use the same
 *  auth resolution as /inbox. */
server.get("/workspaces/:id/pins", async (request) => {
  const auth = await authedFromRequest(request);
  const { id } = request.params as { id: string };
  return ok(store.getPins(auth, id));
});

/** Replace the caller's pin list (last-write-wins). Entries must match
 *  ^(song|playlist|room): and are capped at 50. */
server.put("/workspaces/:id/pins", async (request, reply) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  const body = request.body as { pins?: unknown } | undefined;
  if (!body || body.pins === undefined) {
    return reply.code(400).send({ error: "pins is required" });
  }
  return ok(store.setPins(auth, id, body.pins));
});


server.get("/rooms/:id", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.getRoom(id));
});
server.get("/rooms/:id/songs", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.getRoom(id).songs);
});
server.get("/rooms/:id/analytics", async (request) => {
  const { id } = request.params as { id: string };
  const room = store.getRoom(id);
  const songIDs = new Set(room.songs.map((song) => song.song_id));
  const events = store.data.activityEvents.filter((event) => event.song_id && songIDs.has(event.song_id));
  // Enrich with actor display name so the client doesn't have to do a second join
  const userByID = new Map(store.data.users.map((u) => [u.user_id, u]));
  const enriched = events.map((event) => ({
    ...event,
    actor_display_name:
      (event.actor_user_id && userByID.get(event.actor_user_id)?.display_name) ??
      event.actor_recipient_label ??
      "Unknown",
  }));
  return ok(enriched);
});

server.get("/songs/:id", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.getSong(id));
});
server.patch("/songs/:id", async (request) => {
  await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  // Explicit allowlist — unknown/non-mutable fields are silently ignored (mass-assignment prevention)
  const body = request.body as Record<string, unknown>;
  const SONG_MUTABLE_FIELDS = new Set<string>([
    "title",
    "primary_room_id",
    "status",
    "artist_display_name",
    "project_name",
    "bpm",
    "song_key",
    "explicit_flag",
    "genre_tags",
    "mood_tags",
    "instrument_tags",
    "lyric_theme_tags",
    "artwork_key",
    "artwork_url",
    "release_readiness_status",
  ]);
  const patch: Record<string, unknown> = {};
  for (const key of Object.keys(body)) {
    if (SONG_MUTABLE_FIELDS.has(key)) patch[key] = body[key];
  }
  store.data.songs = store.data.songs.map((song) =>
    song.song_id === id
      ? { ...song, ...patch, song_id: song.song_id, updated_at: new Date().toISOString() }
      : song,
  );
  void persistSongPatch(id, patch as never).catch(() => undefined);
  return ok(store.getSong(id));
});
server.delete("/songs/:id", async (request) => {
  await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  const deletedAt = new Date().toISOString();
  const supabase = getSupabase();
  if (supabase) {
    const { error } = await supabase
      .from("songs")
      .update({ status: "deleted", deleted_at: deletedAt, updated_at: deletedAt })
      .eq("external_id", id);
    if (error) throw error;
  }
  store.data.songs = store.data.songs.map((song) =>
    song.song_id === id ? { ...song, status: "deleted", deleted_at: deletedAt, updated_at: deletedAt } : song
  );
  return ok({ deleted: true });
});
server.get("/songs/:id/deliverables", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.getSong(id).deliverables);
});
server.get("/songs/:id/versions", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.getSong(id).versions);
});
server.post("/songs/:id/versions", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  const body = request.body as {
    filename?: string;
    type?: "demo" | "rough" | "mix" | "master" | "clean" | "explicit" | "instrumental" | "acapella";
    label?: string;
    duration_ms?: number;
    loudness_lufs?: number;
  };
  return ok(
    store.addVersion(id, auth, {
      filename: body.filename ?? "New mix.wav",
      type: body.type,
      label: body.label,
      durationMs: body.duration_ms,
      lufs: body.loudness_lufs,
    })
  );
});
server.get("/songs/:id/notes", async (request) => {
  const { id } = request.params as { id: string };
  const current = store.getSong(id).currentVersion;
  if (!current) return ok([]);
  const notes = store.getVersionNotes(current.version_id);
  const userByID = new Map(store.data.users.map((u) => [u.user_id, u]));
  return ok(
    notes.map((note) => ({
      ...note,
      author_display_name: note.author_user_id
        ? (userByID.get(note.author_user_id)?.display_name ?? null)
        : null,
    })),
  );
});
server.get("/songs/:id/analytics", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.analyticsForSong(id));
});

server.patch("/versions/:id", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.patchVersion(id, request.body as { version_label?: string; type?: never }));
});
server.post("/versions/:id/set-current", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  return ok(store.promoteVersion(id, auth));
});
// iMessage extension (WLReceiptAPI) posts here with x-user-id and cannot obtain a Supabase JWT
// (separate sandbox, no App Group). Kept on legacy auth until the extension has a credential
// path — see runbook 2026-05-29.
server.post("/versions/:id/approvals", async (request) => {
  assertInternalSecret(request.headers); // no-op unless INTERNAL_WRITE_SECRET is set
  const { id } = request.params as { id: string };
  const body = request.body as { state: "approved" | "revision_requested" | "passed"; note?: string };
  return ok(store.createApproval(id, authFromRequest(request), body.state, body.note));
});

// iMessage extension (WLReceiptAPI) posts here with x-user-id and cannot obtain a Supabase JWT
// (separate sandbox, no App Group). Kept on legacy auth until the extension has a credential
// path — see runbook 2026-05-29.
server.post("/notes", async (request) => {
  assertInternalSecret(request.headers); // no-op unless INTERNAL_WRITE_SECRET is set
  return ok(store.createNote(authFromRequest(request), request.body as never));
});
server.patch("/notes/:id", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  return ok(store.patchNote(id, auth, request.body as never));
});
server.post("/notes/:id/convert-to-task", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  const note = store.data.notes.find((candidate) => candidate.note_id === id);
  if (!note) throw new Error("Note not found");
  const task = {
    task_id: randomUUID(),
    workspace_id: store.data.songs.find((song) => song.song_id === note.song_id)?.workspace_id ?? "",
    room_id: note.room_id,
    song_id: note.song_id,
    version_id: note.anchor_version_id,
    source_note_id: id,
    title: note.body.slice(0, 80),
    assigned_to_user_id: note.assigned_to_user_id,
    status: "open",
    priority: note.priority,
    created_by: auth.userID,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
  store.data.tasks = [...store.data.tasks, task];
  return ok(task);
});

server.post("/links", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  return ok(await store.createLink(auth, request.body as never));
});
server.get("/links/:id", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.data.shareLinks.find((link) => link.link_id === id));
});
server.get("/links/:id/recipients", async (request) => {
  await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  return ok(store.listShareRecipients(id));
});
server.post("/links/:id/recipients", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  const body = request.body as {
    recipients?: Array<{ email: string; display_name?: string; role?: "listen" | "comment" | "download" }>;
  };
  const recipients = body.recipients ?? [];
  if (!Array.isArray(recipients) || recipients.length === 0) {
    throw new Error("At least one recipient is required");
  }
  return ok({
    recipients: store.inviteShareRecipients(id, auth, recipients),
    delivery: process.env.EMAIL_PROVIDER_API_KEY ? "queued" : "not_configured",
  });
});
server.patch("/links/:id/recipients/:recipientId", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id, recipientId } = request.params as { id: string; recipientId: string };
  return ok(store.patchShareRecipient(id, recipientId, auth, request.body as never));
});
server.delete("/links/:id/recipients/:recipientId", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id, recipientId } = request.params as { id: string; recipientId: string };
  return ok(store.patchShareRecipient(id, recipientId, auth, { revoked_at: new Date().toISOString() }));
});
server.patch("/links/:id", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  return ok(store.patchLink(id, auth, request.body as never));
});
server.post("/links/:id/revoke", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  return ok(store.revokeLink(id, auth));
});

// ===== Workspace join links (shareable invite links) ====================

/** Owner generates a shareable link. Anyone with the URL can claim it to
 *  create an account and land in the workspace — no email pre-registration. */
server.post("/workspaces/:id/join-links", async (request, reply) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  const body = request.body as { role?: string } | undefined;

  const supabase = getSupabase();
  if (!supabase) return reply.code(503).send({ error: "Requires Supabase" });

  const wsRes = await supabase.from("workspaces").select("workspace_id, name").eq("external_id", id).maybeSingle();
  if (!wsRes.data) return reply.code(404).send({ error: "Workspace not found" });
  const { workspace_id: workspaceUuid, name: workspaceName } = wsRes.data as { workspace_id: string; name: string };

  const role = (body?.role as string | undefined) ?? "viewer";
  const { data, error } = await supabase
    .from("workspace_join_links")
    .insert({ workspace_id: workspaceUuid, role, created_by: auth.userID })
    .select("link_id, token")
    .single();

  if (error || !data) return reply.code(500).send({ error: error?.message ?? "Could not create link" });

  const { token } = data as { link_id: string; token: string };
  const appUrl = process.env.APP_URL ?? "https://playback.allmyfriendsinc.com";
  return ok({ token, url: `${appUrl}/join/${token}`, workspace_name: workspaceName });
});

/** Public — validates token and returns workspace name for the sign-up page. */
server.get("/join/:token", async (request, reply) => {
  const { token } = request.params as { token: string };
  const supabase = getSupabase();
  if (!supabase) return reply.code(503).send({ error: "Requires Supabase" });

  const { data } = await supabase
    .from("workspace_join_links")
    .select("link_id, workspace_id, role, expires_at")
    .eq("token", token)
    .maybeSingle();

  if (!data) return reply.code(404).send({ error: "This invite link is invalid or has already been used." });
  const link = data as { link_id: string; workspace_id: string; role: string; expires_at: string | null };
  if (link.expires_at && new Date(link.expires_at) < new Date()) {
    return reply.code(410).send({ error: "This invite link has expired." });
  }

  const wsRes = await supabase.from("workspaces").select("name").eq("workspace_id", link.workspace_id).single();
  return ok({ valid: true, workspace_name: (wsRes.data as { name: string } | null)?.name ?? "Playback", role: link.role });
});

/** Public — creates the account, grants membership, optionally sends SMS. */
server.post("/join/:token/claim", async (request, reply) => {
  const { token } = request.params as { token: string };
  const body = request.body as { display_name?: string; email?: string; password?: string; phone?: string };

  if (!body.display_name?.trim() || !body.email?.trim() || !body.password) {
    return reply.code(400).send({ error: "Name, email, and password are required." });
  }

  const supabase = getSupabase();
  if (!supabase) return reply.code(503).send({ error: "Requires Supabase" });

  // Validate the token
  const { data: linkData } = await supabase
    .from("workspace_join_links")
    .select("link_id, workspace_id, role, expires_at")
    .eq("token", token)
    .maybeSingle();

  if (!linkData) return reply.code(404).send({ error: "This invite link is invalid or has already been used." });
  const link = linkData as { link_id: string; workspace_id: string; role: string; expires_at: string | null };
  if (link.expires_at && new Date(link.expires_at) < new Date()) {
    return reply.code(410).send({ error: "This invite link has expired." });
  }

  const email = body.email!.toLowerCase().trim();
  const displayName = body.display_name!.trim();

  // Check if an account already exists
  const { data: existing } = await supabase.from("users").select("user_id, auth_uid").eq("email", email).maybeSingle();
  const existingUser = existing as { user_id: string; auth_uid: string | null } | null;

  let resolvedUserID: string;

  if (existingUser?.auth_uid) {
    // Already confirmed — just grant membership
    resolvedUserID = existingUser.user_id;
  } else {
    // Create a new auto-confirmed account (the link is the trust gate)
    const { data: created, error: createErr } = await supabase.auth.admin.createUser({
      email,
      password: body.password!,
      email_confirm: true,
      user_metadata: { display_name: displayName },
    });
    if (createErr || !created?.user) {
      const msg = createErr?.message ?? "";
      if (msg.toLowerCase().includes("already")) {
        return reply.code(409).send({ error: "An account with that email already exists. Sign in on Playback." });
      }
      return reply.code(500).send({ error: msg || "Account creation failed." });
    }
    resolvedUserID = created.user.id;
  }

  // Grant workspace membership (belt-and-suspenders alongside the trigger)
  await supabase.from("memberships").upsert(
    { workspace_id: link.workspace_id, user_id: resolvedUserID, role: link.role },
    { onConflict: "workspace_id,user_id" },
  );

  // Consume the join link (one-time use)
  await supabase.from("workspace_join_links").delete().eq("link_id", link.link_id);

  // Refresh in-memory store so the next GET /me sees the membership
  try { await store.hydrate(); } catch { /* non-fatal */ }

  // Best-effort SMS — only fires when Twilio env vars + a TestFlight URL are set
  const testflightUrl = process.env.TESTFLIGHT_URL;
  let smsSent = false;
  if (body.phone?.trim() && testflightUrl) {
    smsSent = await sendSms(
      body.phone.trim(),
      `You're in! Download Playback here: ${testflightUrl}\n\nSign in with ${email}`,
    );
  }

  return ok({ email, display_name: displayName, testflight_url: testflightUrl ?? null, sms_sent: smsSent });
});

/** Twilio SMS — fires only when TWILIO_ACCOUNT_SID / TWILIO_AUTH_TOKEN /
 *  TWILIO_FROM_NUMBER are set. Never throws. */
async function sendSms(to: string, message: string): Promise<boolean> {
  const sid = process.env.TWILIO_ACCOUNT_SID;
  const authToken = process.env.TWILIO_AUTH_TOKEN;
  const from = process.env.TWILIO_FROM_NUMBER;
  if (!sid || !authToken || !from) return false;
  try {
    const creds = Buffer.from(`${sid}:${authToken}`).toString("base64");
    const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
      method: "POST",
      headers: { Authorization: `Basic ${creds}`, "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ To: to, From: from, Body: message }).toString(),
    });
    return res.ok;
  } catch { return false; }
}

// ===== Inbox ============================================================

server.get("/inbox", async (request) => {
  const auth = await authedFromRequest(request);
  return ok(store.inbox(auth.userID));
});
server.post("/inbox/:songId/action", async (request) => {
  const { songId } = request.params as { songId: string };
  return ok({ song_id: songId, accepted: true, action: (request.body as { action?: string }).action ?? "save" });
});

server.get("/views", async () => ok(store.data.savedViews));
server.post("/views", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const view = { ...(request.body as object), view_id: randomUUID(), created_by: auth.userID, created_at: new Date().toISOString() };
  store.data.savedViews = [...store.data.savedViews, view as never];
  return ok(view);
});
server.delete("/views/:id", async (request) => {
  await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  store.data.savedViews = store.data.savedViews.filter((view) => view.view_id !== id);
  return ok({ deleted: true });
});

server.post("/uploads", async (request) => {
  const body = request.body as { workspace_id?: string; filename?: string; size_bytes?: number; checksum_sha256?: string };
  return ok(
    store.createUpload(body.workspace_id ?? store.data.workspaces[0].workspace_id, {
      filename: body.filename ?? "upload.wav",
      size_bytes: body.size_bytes ?? 0,
      checksum_sha256: body.checksum_sha256,
    })
  );
});
server.patch("/uploads/:id", async (request, reply) => {
  const { id } = request.params as { id: string };
  const received = Number(request.headers["upload-chunk-bytes"] ?? 0);
  reply.header("Tus-Resumable", "1.0.0");
  return ok(store.patchUpload(id, received));
});
server.post("/uploads/:id/finalize", async (request) => {
  const { id } = request.params as { id: string };
  return ok({ asset: store.finalizeUpload(id), processing_job: { status: "queued", queue: "media-pipeline" } });
});
server.post("/uploads/grouping-proposals", async (request) => {
  const body = request.body as { files: Array<{ filename: string; sizeBytes?: number }> };
  return ok(store.proposeGroupings(body.files ?? []));
});

/** Whether the Claude-backed Ask is live (API key configured) vs the
 *  deterministic fallback. Lets the client phrase its disclaimer honestly. */
server.get("/assistant/status", async () => ok({ llm_enabled: isAssistantLlmEnabled() }));

server.post("/assistant/ask", async (request, reply) => {
  // Participate in strict-auth mode: when REQUIRE_JWT_AUTH + Supabase are on, an
  // anonymous caller is rejected here (closes the x-user-id bypass on the paid
  // path). Behaviour-preserving otherwise.
  const auth = await requireAuthedFromRequest(request);
  const body = request.body as { question?: string; song_id?: string; version_id?: string };
  const question = body.question ?? "";
  // Hard cap the free-text input before it drives an Opus call — cheap guard
  // against oversized / cost-abusive prompts.
  if (question.length > 2000) throw new Error("Question is too long (2000 character max).");
  // Per-identity fixed-window limit (falls back to client IP) bounds how fast
  // any one caller can drive LLM spend.
  const limit = rateLimit(`ask:${auth.userID || request.ip}`, 20, 60_000);
  if (!limit.allowed) {
    return reply
      .header("retry-after", Math.ceil(limit.retryAfterMs / 1000))
      .code(429)
      .send({ error: "Too many questions in a short window — give it a moment." });
  }
  return ok(await store.askLlm(question, { song_id: body.song_id, version_id: body.version_id }));
});

function redactRecipientAsset<T extends { playback_url?: string } | null>(asset: T): T {
  if (!asset?.playback_url || !/^https?:\/\//i.test(asset.playback_url)) return asset;
  return { ...asset, playback_url: undefined };
}

async function redirectToPlayableAsset(reply: FastifyReply, asset: { playback_url?: string; key_original?: string } | null | undefined) {
  if (!asset) {
    return reply.code(404).send({ error: "audio_unavailable", message: "Audio is not available." });
  }
  if (asset.playback_url?.startsWith("/")) {
    return reply.code(302).header("location", asset.playback_url).send();
  }
  if (!asset.key_original) {
    return reply.code(404).send({ error: "audio_unavailable", message: "Audio is not available." });
  }
  try {
    const url = await signPlaybackUrl(asset.key_original);
    return reply.code(302).header("location", url).send();
  } catch (err) {
    server.log.warn({ err }, "signPlaybackUrl failed for protected stream");
    return reply.code(404).send({ error: "audio_unavailable", message: "Audio is not available." });
  }
}

// ===== First Listen ======================================================

server.post("/first-listens", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  return ok(store.createFirstListenShare(auth, request.body as never));
});
server.get("/first-listens/:id", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.getFirstListenShare(id));
});
server.get("/first-listens/:id/report", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.getFirstListenReport(id));
});
server.post("/first-listens/:id/recipients/:recipientId/grant-replay", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id, recipientId } = request.params as { id: string; recipientId: string };
  return ok(store.grantFirstListenReplay(id, recipientId, auth));
});

server.get("/listen/:token", async (request) => {
  const { token } = request.params as { token: string };
  const payload = store.resolveFirstListen(token);
  return ok({
    ...payload,
    asset: redactRecipientAsset(payload.asset),
  });
});
server.get("/listen/:token/stream/:versionId", async (request, reply) => {
  const { token, versionId } = request.params as { token: string; versionId: string };
  const asset = store.assertFirstListenStream(token, versionId);
  return redirectToPlayableAsset(reply, asset);
});
server.post("/listen/:token/events", async (request) => {
  const { token } = request.params as { token: string };
  return ok(store.recordFirstListenEvent(token, request.body as never));
});
server.post("/listen/:token/decision", async (request) => {
  const { token } = request.params as { token: string };
  return ok(store.submitFirstListenDecision(token, request.body as never));
});
server.post("/listen/:token/replay-request", async (request) => {
  const { token } = request.params as { token: string };
  return ok(store.requestFirstListenReplay(token));
});

// ===== Listening Room ====================================================

server.post("/listening-rooms", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  return ok(store.createListeningRoom(auth, request.body as never));
});
server.get("/listening-rooms/:id", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.getListeningRoom(id));
});
server.post("/listening-rooms/:id/state", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  return ok(store.updateListeningRoomState(id, auth, request.body as never));
});
server.post("/listening-rooms/:id/start", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  const body = request.body as { host_position_ms?: number };
  return ok(store.updateListeningRoomState(id, auth, { playback_state: "playing", host_position_ms: body.host_position_ms ?? 0 }));
});
server.post("/listening-rooms/:id/end", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  return ok(store.endListeningRoom(id, auth));
});
server.get("/listening-rooms/:id/report", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.getListeningRoomReport(id));
});

server.get("/room/:token", async (request) => {
  const { token } = request.params as { token: string };
  const payload = store.resolveListeningRoom(token);
  return ok({
    ...payload,
    assets: payload.assets.map(redactRecipientAsset),
  });
});
server.get("/room/:token/state", async (request) => {
  const { token } = request.params as { token: string };
  return ok(store.resolveListeningRoom(token).state);
});
server.get("/room/:token/stream/:versionId", async (request, reply) => {
  const { token, versionId } = request.params as { token: string; versionId: string };
  const payload = store.resolveListeningRoom(token);
  const version = payload.versions.find((candidate) => candidate.version_id === versionId);
  if (!version) throw new Error("Version is not available through this Listening Room");
  const asset = payload.assets.find((candidate) => candidate.asset_id === version.file_asset_id);
  return redirectToPlayableAsset(reply, asset);
});
server.post("/room/:token/join", async (request) => {
  const { token } = request.params as { token: string };
  return ok(store.joinListeningRoom(token, request.body as never));
});
server.post("/room/:token/events", async (request) => {
  const { token } = request.params as { token: string };
  return ok(store.recordRoomEvent(token, request.body as never));
});
server.post("/room/:token/first-take", async (request) => {
  const { token } = request.params as { token: string };
  return ok(store.submitRoomFirstTake(token, request.body as never));
});
server.post("/room/:token/notes", async (request) => {
  const { token } = request.params as { token: string };
  const body = request.body as { participant_id?: string; playback_position_ms?: number; note_text?: string; reaction_type?: string };
  return ok(store.recordRoomEvent(token, {
    participant_id: body.participant_id,
    event_type: "timestamp_marker",
    playback_position_ms: body.playback_position_ms,
    note_text: body.note_text,
    reaction_type: (body.reaction_type as never) ?? "text_note",
  }));
});

server.get("/shared/:token", async (request, reply) => {
  const { token } = request.params as { token: string };
  const payload = await store.resolveSharedFresh(token);
  // A link that resolves but exposes nothing playable (target song/version
  // missing from this instance's snapshot) is a dead link to the recipient —
  // return an honest 404 instead of a 200 the player can never render.
  if (payload.songs.length === 0 || payload.versions.length === 0) {
    return reply.code(404).send({
      error: "link_target_unavailable",
      message: "Nothing is available through this link anymore.",
    });
  }
  // Log the open so the manager can see the link was opened (not just played).
  store.recordShareOpen(token);
  return ok(payload);
});
server.get("/shared/:token/stream/:versionId", async (request, reply) => {
  const { token, versionId } = request.params as { token: string; versionId: string };
  // resolveShared() throws if the link is revoked or expired — so this mint is
  // gated on the link being LIVE. Revoking a link immediately stops streaming,
  // and the recipient never holds a permanent URL (only this endpoint, which
  // re-checks on every load). This is what makes revocation real.
  const shared = await store.resolveSharedFresh(token);
  const version = shared.versions.find((candidate) => candidate.version_id === versionId);
  if (!version) throw new Error("Version is not available through this link");
  const asset = shared.assets.find((candidate) => candidate.asset_id === version.file_asset_id);
  if (!asset?.key_original) {
    return reply.code(404).send({ error: "audio_unavailable", message: "Audio isn't available for this version yet." });
  }
  try {
    const url = await signPlaybackUrl(asset.key_original);
    // 302 to a fresh short-lived signed URL. Using code+location (not
    // reply.redirect) keeps this stable across Fastify major versions.
    return reply.code(302).header("location", url).send();
  } catch (err) {
    server.log.warn({ err }, "signPlaybackUrl failed for shared stream");
    return reply.code(404).send({ error: "audio_unavailable", message: "Audio isn't available for this version yet." });
  }
});
server.post("/shared/:token/notes", async (request) => {
  const { token } = request.params as { token: string };
  const shared = await store.resolveSharedFresh(token);
  if (!shared.link.allow_comments) throw new Error("Comments are disabled for this link");
  // Scope guard: a recipient may only comment on a song + version that this
  // link actually exposes. resolveShared() already filters to the link's
  // target; trusting the request body's song_id/anchor_version_id without this
  // check would let a link-holder attach notes to ANY song whose IDs they know.
  const body = request.body as { song_id?: string; anchor_version_id?: string };
  const songInScope = shared.songs.some((s) => s.song_id === body.song_id);
  const versionInScope = shared.versions.some((v) => v.version_id === body.anchor_version_id);
  if (!songInScope || !versionInScope) {
    throw new Error("That song or version is not available through this link");
  }
  return ok(store.createNote({ userID: "guest" }, request.body as never));
});
server.post("/shared/:token/approve", async (request) => {
  const { token } = request.params as { token: string };
  const shared = await store.resolveSharedFresh(token);
  if (!shared.link.allow_approval) throw new Error("Approvals are disabled for this link");
  const body = request.body as { version_id: string; state?: "approved" | "revision_requested" | "passed"; note?: string };
  // Scope guard: only a version this link exposes may be approved through it.
  if (!shared.versions.some((v) => v.version_id === body.version_id)) {
    throw new Error("That version is not available through this link");
  }
  return ok(store.createApproval(body.version_id, { userID: "guest" }, body.state ?? "approved", body.note));
});
server.get("/shared/:token/download/:versionId", async (request, reply) => {
  const { token, versionId } = request.params as { token: string; versionId: string };
  const shared = await store.resolveSharedFresh(token);
  if (shared.link.download_policy === "none") throw new Error("Downloads are disabled for this link");
  const version = shared.versions.find((candidate) => candidate.version_id === versionId);
  if (!version) throw new Error("Version is not available through this link");
  if (shared.link.download_policy === "current" && !version.is_current) {
    throw new Error("Only the current version can be downloaded through this link");
  }
  const asset = shared.assets.find((candidate) => candidate.asset_id === version.file_asset_id);
  if (!asset) {
    return reply.code(404).send({ error: "audio_unavailable", message: "Audio isn't available for this version yet." });
  }
  store.recordShareDownload(token, versionId);
  if (asset.playback_url?.startsWith("/")) {
    return reply.code(302).header("location", asset.playback_url).send();
  }
  try {
    const url = await signPlaybackUrl(asset.key_original);
    return reply.code(302).header("location", url).send();
  } catch (err) {
    server.log.warn({ err }, "signPlaybackUrl failed for shared download");
    return reply.code(404).send({ error: "audio_unavailable", message: "Audio isn't available for this version yet." });
  }
});

// ===== Access requests ("Like Playback? Request access") ================

/** PUBLIC, no auth — a share-link recipient asks the workspace owner for
 *  access from the recipient player. Light per-IP rate limit plus the
 *  store-level duplicate-pending-email guard. */
server.post("/shared/:token/access-request", async (request, reply) => {
  const { token } = request.params as { token: string };
  const limit = rateLimit(`access-request:${request.ip}`, 5, 60_000);
  if (!limit.allowed) {
    return reply
      .header("retry-after", Math.ceil(limit.retryAfterMs / 1000))
      .code(429)
      .send({ error: "Too many requests — give it a moment." });
  }
  const body = request.body as { name?: string; email?: string } | undefined;
  return ok({ request: store.createAccessRequest(token, { name: body?.name, email: body?.email }) });
});

/** Owner-facing: pending access requests for the Inbox. */
server.get("/workspaces/:id/access-requests", async (request) => {
  await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  return ok(store.listAccessRequests(id));
});

/** Approve or dismiss a request. Approving generates an invite link via the
 *  same workspace_join_links mechanism as POST /workspaces/:id/join-links
 *  (the Profile "Generate invite link" path) and returns it so the client
 *  can hand the URL to the requester. */
server.post("/access-requests/:id/resolve", async (request, reply) => {
  const auth = await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  const body = request.body as { action?: "approve" | "dismiss" } | undefined;
  if (body?.action !== "approve" && body?.action !== "dismiss") {
    return reply.code(400).send({ error: 'action must be "approve" or "dismiss"' });
  }

  if (body.action === "dismiss") {
    return ok({ request: store.resolveAccessRequest(id, "dismiss"), invite: null });
  }

  // Approve: create the invite link BEFORE flipping status, so a failure
  // leaves the request pending and the owner can simply retry.
  const pending = store.data.accessRequests.find((candidate) => candidate.request_id === id);
  if (!pending) return reply.code(404).send({ error: "Access request not found" });

  const supabase = getSupabase();
  if (!supabase) return reply.code(503).send({ error: "Invites require Supabase to be configured" });

  const wsRes = await supabase
    .from("workspaces")
    .select("workspace_id, name")
    .eq("external_id", pending.workspace_id)
    .maybeSingle();
  if (!wsRes.data) return reply.code(404).send({ error: "Workspace not found" });
  const { workspace_id: workspaceUuid, name: workspaceName } = wsRes.data as { workspace_id: string; name: string };

  const { data, error } = await supabase
    .from("workspace_join_links")
    .insert({ workspace_id: workspaceUuid, role: "viewer", created_by: auth.userID })
    .select("link_id, token")
    .single();
  if (error || !data) return reply.code(500).send({ error: error?.message ?? "Could not create invite link" });

  const { token: inviteToken } = data as { link_id: string; token: string };
  const appUrl = process.env.APP_URL ?? "https://playback.allmyfriendsinc.com";
  const resolved = store.resolveAccessRequest(id, "approve");
  return ok({
    request: resolved,
    invite: {
      token: inviteToken,
      url: `${appUrl}/join/${inviteToken}`,
      workspace_name: workspaceName,
      email: resolved.email,
      role: "viewer",
    },
  });
});

// ===== Real audio uploads (Supabase Storage) ============================

/** Mint a signed upload URL the client uses to PUT directly to Supabase Storage. */
server.post("/storage/sign-upload", async (request) => {
  // Real-audio write path: enforce JWT in strict mode (was authedFromRequest,
  // which left the x-user-id bypass open even with REQUIRE_JWT_AUTH=true).
  await requireAuthedFromRequest(request);
  const body = request.body as SignUploadInput;
  if (!body?.filename) throw new Error("filename is required");
  return ok(await signUpload(body));
});

/** After the client finishes uploading, create file_asset + version rows
 *  AND re-hydrate the in-memory store so subsequent reads see the new data. */
server.post("/storage/finalize-upload", async (request) => {
  // Real-audio write path: enforce JWT in strict mode (was authedFromRequest).
  const auth = await requireAuthedFromRequest(request);
  const body = request.body as FinalizeUploadInput;
  if (!body?.storagePath || !body?.songExternalId || !body?.publicUrl) {
    throw new Error("storagePath, publicUrl, and songExternalId are required");
  }
  // Attribute the upload to the authenticated caller, never a request-body field
  // (a client could otherwise forge `uploadedBy: usr-theo`). The body value is
  // ignored in favour of the resolved identity.
  const result = await finalizeUpload({ ...body, uploadedBy: auth.userID });
  // Refresh in-memory snapshot so the new version is immediately visible.
  // A hydrate failure must NOT 500 a successful upload — log and continue.
  try {
    await store.hydrate();
  } catch (hydrateErr) {
    server.log.warn({ err: hydrateErr }, "store.hydrate() failed after finalize-upload; snapshot may be stale");
  }
  return ok(result);
});

/** Finalize an uploaded audio object into a brand-new song + v1 version. */
server.post("/storage/finalize-new-song", async (request) => {
  const auth = await requireAuthedFromRequest(request);
  const body = request.body as FinalizeNewSongInput;
  if (!body?.storagePath || !body?.publicUrl || !body?.title) {
    throw new Error("storagePath, publicUrl, and title are required");
  }
  const result = await finalizeNewSongUpload({ ...body, uploadedBy: auth.userID });
  try {
    await store.hydrate();
  } catch (hydrateErr) {
    server.log.warn({ err: hydrateErr }, "store.hydrate() failed after finalize-new-song; snapshot may be stale");
  }
  return ok(result);
});

// ===== Stem splitting (Demucs worker — local deployments only) ==========

/** Kick a stem-split job for a version. 503 when the worker isn't enabled on
 *  this deployment (prod Render can't run demucs); 409 when a live job already
 *  covers this version/asset or stems already exist (unless {force:true}). */
server.post("/versions/:id/split-stems", async (request, reply) => {
  await requireAuthedFromRequest(request);
  if (!isStemsWorkerEnabled()) {
    return reply.code(503).send({ error: "stems worker unavailable on this deployment" });
  }
  const { id } = request.params as { id: string };
  const body = (request.body ?? {}) as { force?: boolean };
  const version = store.data.versions.find((v) => v.version_id === id);
  if (!version) return reply.code(404).send({ error: "Version not found" });
  const song = store.data.songs.find((s) => s.song_id === version.song_id);
  const asset = store.data.assets.find((a) => a.asset_id === version.file_asset_id);
  if (!song || !asset) return reply.code(404).send({ error: "Song or asset not found for version" });

  const live = liveStemJobForVersionOrAsset(version.version_id, asset.asset_id);
  if (live) return reply.code(409).send({ error: "A stem job is already running for this version", job: live });
  if (asset.key_stems_zip && !body.force) {
    return reply.code(409).send({ error: "Stems already exist for this version", key_stems_zip: asset.key_stems_zip });
  }
  return ok(enqueueStemJob({ song, version, asset }));
});

/** Job state — the UI polls this every ~2s while a job is live. */
server.get("/stem-jobs/:id", async (request, reply) => {
  const { id } = request.params as { id: string };
  const job = store.stemJobs.get(id);
  if (!job) return reply.code(404).send({ error: "Stem job not found" });
  return ok(job);
});

/** Latest job for a version (lets the UI resume polling after a reload). */
server.get("/versions/:id/stem-job", async (request) => {
  const { id } = request.params as { id: string };
  return ok(latestStemJobForVersion(id) ?? null);
});

/** Short-lived signed URL for the stems zip — resolved like other storage
 *  assets (signed per-request, never a stored permanent URL). */
server.get("/versions/:id/stems-url", async (request, reply) => {
  const { id } = request.params as { id: string };
  const version = store.data.versions.find((v) => v.version_id === id);
  const asset = version ? store.data.assets.find((a) => a.asset_id === version.file_asset_id) : undefined;
  if (!asset?.key_stems_zip) return reply.code(404).send({ error: "No stems for this version" });
  try {
    const url = await signPlaybackUrl(asset.key_stems_zip);
    return ok({ url, key: asset.key_stems_zip });
  } catch (err) {
    server.log.warn({ err }, "signPlaybackUrl failed for stems zip");
    return reply.code(404).send({ error: "Stems zip is not available" });
  }
});

server.setErrorHandler((error, _request, reply) => {
  if (error instanceof AuthError) {
    // Typed auth failures → precise status (401 token-rejected, 503 service-down)
    reply.code(error.httpStatus).send({ error: error.message });
    return;
  }
  server.log.error(error);
  // Honor an explicit statusCode carried by the error (e.g. 503 "storage write
  // unavailable" / 422 "target not synced" from createLink) so clients can
  // distinguish retryable failures from permanent ones. Bare Errors keep the
  // legacy 400 behaviour.
  const status =
    typeof error.statusCode === "number" && error.statusCode >= 400 && error.statusCode <= 599
      ? error.statusCode
      : 400;
  reply.status(status).send({ error: error.message });
});

  return server;
} // end buildApp()

// Boot path — only runs when this module is the entry point, not when imported by tests.
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, "/"))) {
  const port = Number(process.env.API_PORT ?? process.env.PORT ?? 4317);
  const app = await buildApp();

  // Hydrate from Supabase BEFORE listening so first requests already see real data
  await store.hydrate();

  if (process.env.NODE_ENV === "production" && !isSupabaseEnabled()) {
    app.log.warn(
      { supabaseEnabled: false },
      "write routes running in x-user-id FALLBACK mode — JWT not enforced because Supabase is not configured (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing)",
    );
  }

  if (process.env.NODE_ENV === "production" && !process.env.INTERNAL_WRITE_SECRET) {
    app.log.warn(
      { internalWriteSecret: false },
      "POST /notes and POST /versions/:id/approvals accept an UNVERIFIED x-user-id header — set INTERNAL_WRITE_SECRET (and have the iMessage extension send a matching x-internal-secret) to close this spoofing surface. See runbook.",
    );
  }

  await app.listen({ port, host: "0.0.0.0" });
}
