import type { ActivityEvent, AssistantAnswer, FileAsset, Playlist, PlaylistItem, Room, SavedView, ShareLink, Song, Version, VisibleNote } from "@pmw/shared";
import { supabase } from "./auth";

// =====================================================================
// Pin / Recent types  (Pieces 4 & 5 — defined here for the client layer)
// =====================================================================

export type PinnedSong = {
  song_id: string;
  title: string;
  artist_display_name?: string;
  project_name?: string;
  status: string;
  pinned_at: string;
};

export type PinnedPlaylist = {
  playlist_id: string;
  title: string;
  item_count: number;
  cover_seed: string;
  pinned_at: string;
};

export type PinnedProject = {
  project_id: string;
  title: string;
  project_type: string;
  song_count: number;
  pinned_at: string;
};

export type MyPinsPayload = {
  songs: PinnedSong[];
  playlists: PinnedPlaylist[];
  projects: PinnedProject[];
};

export type RecentItem = {
  entity_type: "song" | "playlist" | "project";
  entity_id: string;
  title: string;
  artist_display_name?: string;
  project_name?: string;
  version_label?: string;
  status?: string;
  last_activity_at: string;
};

const API_URL = import.meta.env.VITE_API_URL ?? "http://localhost:4317";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  // Attach the current Supabase session JWT if logged in; otherwise fall back
  // to the dev x-user-id header (used by recipient/shared routes that don't
  // require auth).
  const { data } = await supabase.auth.getSession();
  const headers: Record<string, string> = {
    "content-type": "application/json",
    ...(init?.headers as Record<string, string> | undefined ?? {}),
  };
  if (data.session?.access_token) {
    headers["authorization"] = `Bearer ${data.session.access_token}`;
  } else if (!headers["x-user-id"]) {
    headers["x-user-id"] = "usr-theo";
  }

  const response = await fetch(`${API_URL}${path}`, { ...init, headers });
  const payload = await response.json();
  if (!response.ok || payload.error) {
    throw new Error(payload.error ?? "Request failed");
  }
  return payload.data as T;
}

export type RoomPayload = {
  room: Room;
  songs: Song[];
  versions: Version[];
  assets: FileAsset[];
  notes: VisibleNote[];
  links: ShareLink[];
};

export type SongPayload = {
  song: Song;
  versions: Version[];
  assets: FileAsset[];
  currentVersion?: Version;
  notes: VisibleNote[];
  approvals: Array<{ approval_id: string; version_id: string; state: string; note?: string }>;
  links: ShareLink[];
  deliverables: { ready: boolean; present: string[]; missing: string[] };
};

export type SharedPayload = {
  link: ShareLink;
  songs: Song[];
  versions: Version[];
  assets: FileAsset[];
  rooms: Room[];
  /** Set when the link's `target_type === "playlist"`. */
  playlist?: Playlist | null;
};

export const api = {
  room: (id = "room-hudson-ingram-lp") => request<RoomPayload>(`/rooms/${id}`),
  song: (id: string) => request<SongPayload>(`/songs/${id}`),
  inbox: () =>
    request<
      Array<{
        song: Song;
        room: Room;
        current_version: Version;
        asset: FileAsset;
        shared_by: string;
        new_since_last_listen: boolean;
        last_listened_at?: string;
      }>
    >("/inbox"),
  ask: (question: string, context?: { song_id?: string; version_id?: string }) =>
    request<AssistantAnswer>("/assistant/ask", { method: "POST", body: JSON.stringify({ question, ...context }) }),
  assistantStatus: () => request<{ llm_enabled: boolean }>("/assistant/status"),
  addVersion: (songID: string, body: { filename: string; label?: string; type?: string; duration_ms?: number; loudness_lufs?: number }) =>
    request<SongPayload>(`/songs/${songID}/versions`, { method: "POST", body: JSON.stringify(body) }),
  setCurrent: (versionID: string) =>
    request<SongPayload>(`/versions/${versionID}/set-current`, { method: "POST", body: JSON.stringify({}) }),
  createNote: (body: {
    song_id: string;
    anchor_version_id: string;
    body: string;
    timestamp_start_ms?: number;
    scope?: "song" | "version";
    visibility?: "everyone" | "internal" | "private";
  }) => request<VisibleNote>("/notes", { method: "POST", body: JSON.stringify(body) }),
  patchNote: (noteID: string, body: { status?: "open" | "resolved" }) =>
    request<VisibleNote>(`/notes/${noteID}`, { method: "PATCH", body: JSON.stringify(body) }),
  approve: (versionID: string, state: "approved" | "revision_requested" | "passed") =>
    request(`/versions/${versionID}/approvals`, { method: "POST", body: JSON.stringify({ state }) }),
  createLink: (body: Partial<ShareLink> & { workspace_id: string; target_type: "song" | "room" | "playlist"; target_id: string }) =>
    request<{ link: ShareLink; token: string }>("/links", { method: "POST", body: JSON.stringify(body) }),
  revokeLink: (id: string) => request<ShareLink>(`/links/${id}/revoke`, { method: "POST", body: JSON.stringify({}) }),
  roomAnalytics: (id = "room-hudson-ingram-lp") =>
    request<Array<ActivityEvent & { actor_display_name: string }>>(`/rooms/${id}/analytics`),
  workspaceMembers: (id = "wsp-amf-private") =>
    request<Array<{ user_id: string; display_name: string; role: string }>>(`/workspaces/${id}/members`),
  roomsSummary: (id = "wsp-amf-private") =>
    request<Array<Room & { song_count: number; open_note_count: number }>>(`/workspaces/${id}/rooms-summary`),
  workspaceLibrary: (id = "wsp-amf-private") =>
    request<Array<{
      song: Song;
      room: { room_id: string; title: string; type: string } | null;
      current_version: Version | null;
      asset: FileAsset | null;
    }>>(`/workspaces/${id}/library`),
  playlists: (id = "wsp-amf-private") =>
    request<Array<Playlist & { item_count: number; preview_titles: string[] }>>(`/workspaces/${id}/playlists`),
  playlist: (id: string) =>
    request<{
      playlist: Playlist;
      items: Array<{
        item: PlaylistItem;
        song: Song | null;
        current_version: Version | null;
        asset: FileAsset | null;
      }>;
    }>(`/playlists/${id}`),
  createPlaylist: (body: { workspace_id: string; title: string; description?: string }) =>
    request<Playlist>("/playlists", { method: "POST", body: JSON.stringify(body) }),
  addToPlaylist: (playlistID: string, body: { song_id: string; note?: string }) =>
    request<PlaylistItem>(`/playlists/${playlistID}/items`, { method: "POST", body: JSON.stringify(body) }),
  removeFromPlaylist: (playlistID: string, itemID: string) =>
    request<{ removed: number }>(`/playlists/${playlistID}/items/${itemID}`, { method: "DELETE" }),
  savedViews: (id = "wsp-amf-private") =>
    request<SavedView[]>(`/workspaces/${id}/saved-views`),
  reorderPlaylistItems: (playlistID: string, item_ids: string[]) =>
    request<{ reordered: number }>(`/playlists/${playlistID}/reorder`, {
      method: "POST",
      body: JSON.stringify({ item_ids }),
    }),
  // === Pins & Recent (Pieces 4 & 5) ====================================

  getMyPins: (workspaceID = "wsp-amf-private") =>
    request<MyPinsPayload>(`/workspaces/${workspaceID}/my-pins`),
  pinSong: (workspaceID: string, songID: string) =>
    request<{ pinned: true }>(`/workspaces/${workspaceID}/my-pins/songs/${songID}`, { method: "PUT", body: JSON.stringify({}) }),
  unpinSong: (workspaceID: string, songID: string) =>
    request<{ unpinned: true }>(`/workspaces/${workspaceID}/my-pins/songs/${songID}`, { method: "DELETE" }),
  pinPlaylist: (workspaceID: string, playlistID: string) =>
    request<{ pinned: true }>(`/workspaces/${workspaceID}/my-pins/playlists/${playlistID}`, { method: "PUT", body: JSON.stringify({}) }),
  unpinPlaylist: (workspaceID: string, playlistID: string) =>
    request<{ unpinned: true }>(`/workspaces/${workspaceID}/my-pins/playlists/${playlistID}`, { method: "DELETE" }),
  pinProject: (workspaceID: string, projectID: string) =>
    request<{ pinned: true }>(`/workspaces/${workspaceID}/my-pins/projects/${projectID}`, { method: "PUT", body: JSON.stringify({}) }),
  unpinProject: (workspaceID: string, projectID: string) =>
    request<{ unpinned: true }>(`/workspaces/${workspaceID}/my-pins/projects/${projectID}`, { method: "DELETE" }),
  recent: (workspaceID: string, limit = 20) =>
    request<RecentItem[]>(`/workspaces/${workspaceID}/recent?limit=${limit}`),

  shared: async (token: string) => {
    const payload = await request<SharedPayload>(`/shared/${token}`);
    // Route recipient audio through the revocation-gated streaming endpoint
    // rather than a permanent public URL. The server strips playback_url from
    // shared assets; we point each asset at /shared/:token/stream/:versionId,
    // which 302s to a fresh short-lived signed URL on every load and dies the
    // moment the link is revoked. The <audio> element follows the redirect
    // transparently, so the player needs no change.
    const versionIdByAsset = new Map<string, string>();
    for (const v of payload.versions) {
      if (v.file_asset_id && !versionIdByAsset.has(v.file_asset_id)) {
        versionIdByAsset.set(v.file_asset_id, v.version_id);
      }
    }
    payload.assets = payload.assets.map((asset) => {
      const versionId = versionIdByAsset.get(asset.asset_id);
      return versionId
        ? { ...asset, playback_url: `${API_URL}/shared/${token}/stream/${versionId}` }
        : asset;
    });
    return payload;
  },
  sharedApprove: (token: string, versionId: string, state: "approved" | "revision_requested" | "passed" = "approved", note?: string) =>
    request<{ approval_id: string; state: string }>(`/shared/${token}/approve`, {
      method: "POST",
      body: JSON.stringify({ version_id: versionId, state, note }),
    }),

  // === Real audio uploads (Supabase Storage) ============================

  signUpload: (body: { filename: string; contentType?: string; songExternalId?: string }) =>
    request<{
      uploadUrl: string;
      token: string;
      storagePath: string;
      publicUrl: string;
      expiresInSeconds: number;
    }>("/storage/sign-upload", { method: "POST", body: JSON.stringify(body) }),

  finalizeUpload: (body: {
    storagePath: string;
    publicUrl: string;
    filename: string;
    contentType?: string;
    fileSizeBytes: number;
    durationMs?: number;
    sampleRate?: number;
    songExternalId: string;
    versionLabel?: string;
    versionType?: string;
  }) =>
    request<{ assetExternalId: string; versionExternalId: string; versionNumber: number }>(
      "/storage/finalize-upload",
      { method: "POST", body: JSON.stringify(body) }
    ),
};

// =====================================================================
// Audio upload helper — picks duration via Web Audio API, uploads to
// Supabase Storage via signed URL, finalizes the version row.
// =====================================================================
export async function uploadAudio(
  file: File,
  opts: { songExternalId: string; versionLabel?: string; versionType?: string },
  onProgress?: (pct: number) => void
): Promise<{ assetExternalId: string; versionExternalId: string; versionNumber: number }> {
  // 1) Ask API for a signed upload URL
  const sig = await api.signUpload({
    filename: file.name,
    contentType: file.type || "audio/mpeg",
    songExternalId: opts.songExternalId,
  });
  onProgress?.(5);

  // 2) Extract duration via Web Audio API (best-effort)
  let durationMs: number | undefined;
  let sampleRate: number | undefined;
  try {
    const arrayBuffer = await file.arrayBuffer();
    const AC = (window.AudioContext || (window as any).webkitAudioContext) as typeof AudioContext;
    const ctx = new AC();
    const decoded = await ctx.decodeAudioData(arrayBuffer.slice(0));
    durationMs = Math.round(decoded.duration * 1000);
    sampleRate = decoded.sampleRate;
    ctx.close();
  } catch (err) {
    console.warn("Could not decode audio for metadata", err);
  }
  onProgress?.(15);

  // 3) PUT the file directly to Supabase Storage
  const putRes = await fetch(sig.uploadUrl, {
    method: "PUT",
    headers: { "content-type": file.type || "audio/mpeg", "x-upsert": "true" },
    body: file,
  });
  if (!putRes.ok) {
    const detail = await putRes.text().catch(() => "");
    throw new Error(`Upload failed (${putRes.status}): ${detail.slice(0, 200)}`);
  }
  onProgress?.(90);

  // 4) Tell the API the upload finished — creates file_asset + version rows
  const result = await api.finalizeUpload({
    storagePath: sig.storagePath,
    publicUrl: sig.publicUrl,
    filename: file.name,
    contentType: file.type || "audio/mpeg",
    fileSizeBytes: file.size,
    durationMs,
    sampleRate,
    songExternalId: opts.songExternalId,
    versionLabel: opts.versionLabel,
    versionType: opts.versionType,
  });
  onProgress?.(100);
  return result;
}

export function assetForVersion(assets: FileAsset[], version?: Version): FileAsset | undefined {
  if (!version) return undefined;
  return assets.find((asset) => asset.asset_id === version.file_asset_id);
}

export function versionsForSong(versions: Version[], songID: string): Version[] {
  return versions.filter((version) => version.song_id === songID).sort((a, b) => a.version_number - b.version_number);
}

