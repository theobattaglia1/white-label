import cors from "@fastify/cors";
import Fastify from "fastify";
import { randomUUID } from "node:crypto";
import { store, type AuthContext } from "./store";
import { signUpload, finalizeUpload, type FinalizeUploadInput, type SignUploadInput } from "./uploads";
import { loadSnapshotFromSupabase } from "./supabase-loader";
import { isSupabaseEnabled } from "./supabase";
import { authFromHeaders, requireAuthedFromHeaders, assertInternalSecret, AuthError } from "./auth";

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

server.get("/health", async () => ok({ status: "ok", product: "private-music-workspace" }));
server.post("/dev/reset", async () => ok(store.reset()));

server.get("/me", async (request, reply) => {
  const auth = await authedFromRequest(request);
  const result = store.me(auth);
  if (!result.user) {
    server.log.warn({ userID: auth.userID }, "GET /me: unknown identity — returning 404");
    return reply.code(404).send({ error: "User not found" });
  }
  return ok(result);
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
    }));
  return ok(members);
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
    const songs = store.data.songs.filter((s) => s.primary_room_id === room.room_id);
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
  const songs = store.data.songs.filter((s) => s.workspace_id === id);
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
  return ok(store.getSong(id));
});
server.delete("/songs/:id", async (request) => {
  await requireAuthedFromRequest(request);
  const { id } = request.params as { id: string };
  store.data.songs = store.data.songs.map((song) =>
    song.song_id === id ? { ...song, status: "deleted", updated_at: new Date().toISOString() } : song
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
  return ok(current ? store.getVersionNotes(current.version_id) : []);
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
  return ok(store.createLink(auth, request.body as never));
});
server.get("/links/:id", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.data.shareLinks.find((link) => link.link_id === id));
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

server.get("/inbox", async (request) => ok(store.inbox(authFromRequest(request).userID)));
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

server.post("/assistant/ask", async (request) => {
  const body = request.body as { question?: string };
  return ok(store.ask(body.question ?? ""));
});

server.get("/shared/:token", async (request) => {
  const { token } = request.params as { token: string };
  const payload = store.resolveShared(token);
  return ok(payload);
});
server.get("/shared/:token/stream/:versionId", async (request, reply) => {
  const { token, versionId } = request.params as { token: string; versionId: string };
  const shared = store.resolveShared(token);
  const version = shared.versions.find((candidate) => candidate.version_id === versionId);
  if (!version) throw new Error("Version is not available through this link");
  return reply.code(501).send({ error: "not_implemented", message: "Audio streaming not yet wired to R2 storage" });
});
server.post("/shared/:token/notes", async (request) => {
  const { token } = request.params as { token: string };
  const shared = store.resolveShared(token);
  if (!shared.link.allow_comments) throw new Error("Comments are disabled for this link");
  return ok(store.createNote({ userID: "guest" }, request.body as never));
});
server.post("/shared/:token/approve", async (request) => {
  const { token } = request.params as { token: string };
  const shared = store.resolveShared(token);
  if (!shared.link.allow_approval) throw new Error("Approvals are disabled for this link");
  const body = request.body as { version_id: string; state?: "approved" | "revision_requested" | "passed"; note?: string };
  return ok(store.createApproval(body.version_id, { userID: "guest" }, body.state ?? "approved", body.note));
});
server.get("/shared/:token/download/:versionId", async (request, reply) => {
  const { token, versionId } = request.params as { token: string; versionId: string };
  const shared = store.resolveShared(token);
  if (shared.link.download_policy === "none") throw new Error("Downloads are disabled for this link");
  return reply.code(501).send({ error: "not_implemented", message: "Audio streaming not yet wired to R2 storage" });
});

// ===== Real audio uploads (Supabase Storage) ============================

/** Mint a signed upload URL the client uses to PUT directly to Supabase Storage. */
server.post("/storage/sign-upload", async (request) => {
  // Auth required — falls back gracefully to x-user-id in dev/offline
  await authedFromRequest(request);
  const body = request.body as SignUploadInput;
  if (!body?.filename) throw new Error("filename is required");
  return ok(await signUpload(body));
});

/** After the client finishes uploading, create file_asset + version rows
 *  AND re-hydrate the in-memory store so subsequent reads see the new data. */
server.post("/storage/finalize-upload", async (request) => {
  // Auth required — falls back gracefully to x-user-id in dev/offline
  await authedFromRequest(request);
  const body = request.body as FinalizeUploadInput;
  if (!body?.storagePath || !body?.songExternalId || !body?.publicUrl) {
    throw new Error("storagePath, publicUrl, and songExternalId are required");
  }
  const result = await finalizeUpload(body);
  // Refresh in-memory snapshot so the new version is immediately visible.
  // A hydrate failure must NOT 500 a successful upload — log and continue.
  try {
    await store.hydrate();
  } catch (hydrateErr) {
    server.log.warn({ err: hydrateErr }, "store.hydrate() failed after finalize-upload; snapshot may be stale");
  }
  return ok(result);
});

server.setErrorHandler((error, _request, reply) => {
  if (error instanceof AuthError) {
    // Typed auth failures → precise status (401 token-rejected, 503 service-down)
    reply.code(error.httpStatus).send({ error: error.message });
    return;
  }
  server.log.error(error);
  reply.status(400).send({ error: error.message });
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
