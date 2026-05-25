import cors from "@fastify/cors";
import Fastify from "fastify";
import { randomUUID } from "node:crypto";
import { store, type AuthContext } from "./store";

const port = Number(process.env.API_PORT ?? 4317);
const server = Fastify({ logger: true });

await server.register(cors, { origin: true });

function authFromRequest(request: { headers: Record<string, string | string[] | undefined> }): AuthContext {
  const header = request.headers["x-user-id"];
  return { userID: Array.isArray(header) ? header[0] : header ?? "usr-theo" };
}

function ok<T>(value: T): { data: T } {
  return { data: value };
}

server.get("/health", async () => ok({ status: "ok", product: "private-music-workspace" }));
server.post("/dev/reset", async () => ok(store.reset()));

server.get("/me", async (request) => ok(store.me(authFromRequest(request))));
server.get("/workspaces", async () => ok(store.data.workspaces));
server.get("/workspaces/:id", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.data.workspaces.find((workspace) => workspace.workspace_id === id));
});
server.get("/workspaces/:id/rooms", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.listRooms(id));
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
  return ok(store.data.activityEvents.filter((event) => event.song_id && songIDs.has(event.song_id)));
});

server.get("/songs/:id", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.getSong(id));
});
server.patch("/songs/:id", async (request) => {
  const { id } = request.params as { id: string };
  const patch = request.body as Record<string, unknown>;
  store.data.songs = store.data.songs.map((song) =>
    song.song_id === id ? { ...song, ...patch, song_id: song.song_id, updated_at: new Date().toISOString() } : song
  );
  return ok(store.getSong(id));
});
server.delete("/songs/:id", async (request) => {
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
  const { id } = request.params as { id: string };
  const body = request.body as {
    filename?: string;
    type?: "demo" | "rough" | "mix" | "master" | "clean" | "explicit" | "instrumental" | "acapella";
    label?: string;
    duration_ms?: number;
    loudness_lufs?: number;
  };
  return ok(
    store.addVersion(id, authFromRequest(request), {
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
  const { id } = request.params as { id: string };
  return ok(store.promoteVersion(id, authFromRequest(request)));
});
server.post("/versions/:id/approvals", async (request) => {
  const { id } = request.params as { id: string };
  const body = request.body as { state: "approved" | "revision_requested" | "passed"; note?: string };
  return ok(store.createApproval(id, authFromRequest(request), body.state, body.note));
});

server.post("/notes", async (request) => ok(store.createNote(authFromRequest(request), request.body as never)));
server.patch("/notes/:id", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.patchNote(id, authFromRequest(request), request.body as never));
});
server.post("/notes/:id/convert-to-task", async (request) => {
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
    created_by: authFromRequest(request).userID,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
  store.data.tasks = [...store.data.tasks, task];
  return ok(task);
});

server.post("/links", async (request) => ok(store.createLink(authFromRequest(request), request.body as never)));
server.get("/links/:id", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.data.shareLinks.find((link) => link.link_id === id));
});
server.patch("/links/:id", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.patchLink(id, authFromRequest(request), request.body as never));
});
server.post("/links/:id/revoke", async (request) => {
  const { id } = request.params as { id: string };
  return ok(store.revokeLink(id, authFromRequest(request)));
});

server.get("/inbox", async (request) => ok(store.inbox(authFromRequest(request).userID)));
server.post("/inbox/:songId/action", async (request) => {
  const { songId } = request.params as { songId: string };
  return ok({ song_id: songId, accepted: true, action: (request.body as { action?: string }).action ?? "save" });
});

server.get("/views", async () => ok(store.data.savedViews));
server.post("/views", async (request) => {
  const view = { ...(request.body as object), view_id: randomUUID(), created_at: new Date().toISOString() };
  store.data.savedViews = [...store.data.savedViews, view as never];
  return ok(view);
});
server.delete("/views/:id", async (request) => {
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
server.get("/shared/:token/stream/:versionId", async (request) => {
  const { token, versionId } = request.params as { token: string; versionId: string };
  const shared = store.resolveShared(token);
  const version = shared.versions.find((candidate) => candidate.version_id === versionId);
  if (!version) throw new Error("Version is not available through this link");
  return ok({ signed_url: `https://r2.example.invalid/signed/${versionId}?ttl=300`, expires_in_seconds: 300 });
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
server.get("/shared/:token/download/:versionId", async (request) => {
  const { token, versionId } = request.params as { token: string; versionId: string };
  const shared = store.resolveShared(token);
  if (shared.link.download_policy === "none") throw new Error("Downloads are disabled for this link");
  return ok({
    signed_url: `https://r2.example.invalid/watermarked/${versionId}?ttl=300`,
    watermark: shared.link.watermark_enabled ? "recipient-bound trace rendition queued" : "disabled",
  });
});

server.setErrorHandler((error, _request, reply) => {
  server.log.error(error);
  reply.status(400).send({ error: error.message });
});

// Hydrate from Supabase BEFORE listening so first requests already see real data
await store.hydrate();
await server.listen({ port, host: "0.0.0.0" });
