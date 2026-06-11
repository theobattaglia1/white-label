import type {
  ActivityEvent,
  AssistantAnswer,
  DecisionResponse,
  DecisionResponseValue,
  FileAsset,
  ListeningEvent,
  ListeningEventType,
  ListeningReport,
  ListeningRoom,
  ListeningRoomParticipant,
  ListeningRoomState,
  ListeningRoomTrack,
  Playlist,
  PlaylistItem,
  Room,
  SavedView,
  ShareLink,
  ShareSession,
  ShareSessionRecipient,
  Song,
  TimestampedReaction,
  Version,
  VisibleNote,
} from "@pmw/shared";
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

const CURRENT_RENDER_API_URL = "https://white-label-api-6mnt.onrender.com";
const LEGACY_RENDER_API_URLS = new Set([
  "https://white-label-api.onrender.com",
  "https://white-label-api.onrender.com/",
]);

function resolveAPIURL() {
  const configured = (import.meta.env.VITE_API_URL as string | undefined)?.trim();
  if (configured && !LEGACY_RENDER_API_URLS.has(configured)) {
    return configured.replace(/\/$/, "");
  }
  return import.meta.env.DEV ? "http://localhost:4317" : CURRENT_RENDER_API_URL;
}

const API_URL = resolveAPIURL();

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
  notes: VisibleNote[];
  /** Set when the link's `target_type === "playlist"`. */
  playlist?: Playlist | null;
};

export type FirstListenPayload = {
  session: ShareSession;
  recipient: ShareSessionRecipient;
  sender: { user_id: string; display_name: string; email: string } | null;
  song: Song;
  version: Version;
  asset: FileAsset | null;
  room: Room | null;
  can_play: boolean;
  can_request_replay: boolean;
  replay_granted: boolean;
  report: ListeningReport | null;
};

export type ListeningRoomPayload = {
  room: ListeningRoom;
  tracks: ListeningRoomTrack[];
  songs: Song[];
  versions: Version[];
  assets: FileAsset[];
  participants: ListeningRoomParticipant[];
  state: ListeningRoomState;
  reactions: TimestampedReaction[];
  decisions: DecisionResponse[];
  events: ListeningEvent[];
  report: ListeningReport | null;
  summary: Record<string, unknown>;
  host: { user_id: string; display_name: string; email: string } | null;
  project: Room | null;
};

export const api = {
  me: () => request<{ user: { member_number?: number; display_name: string; user_id: string } | null; memberships: unknown[] }>("/me"),
  room: (id = "room-secret-album") => request<RoomPayload>(`/rooms/${id}`),
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
  roomAnalytics: (id: string) =>
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
  /** The caller's ordered pin list — raw "type:id" strings matching the iOS
   *  PinRef encoding ("song:ID" | "playlist:ID" | "room:ID"). Feeds THE SHELF
   *  on Home; resolved client-side against already-loaded workspace data. */
  workspacePins: (workspaceID = "wsp-amf-private") =>
    request<string[]>(`/workspaces/${workspaceID}/pins`),
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

  // === Team / Invites =======================================================

  workspaceMembersRich: (id = "wsp-amf-private") =>
    request<Array<{ user_id: string; display_name: string; role: string; member_number: number | null }>>(`/workspaces/${id}/members`),
  listInvites: (id = "wsp-amf-private") =>
    request<Array<{ invite_id: string; email: string; role: string; display_name: string | null; invited_at: string }>>(`/workspaces/${id}/invites`),
  sendInvite: (id: string, body: { email: string; role: string; display_name?: string }) =>
    request<{ invited: boolean; email: string; role: string; invite_id: string }>(`/workspaces/${id}/invite`, { method: "POST", body: JSON.stringify(body) }),
  revokeInvite: (workspaceId: string, inviteId: string) =>
    request<{ revoked: boolean }>(`/workspaces/${workspaceId}/invites/${inviteId}`, { method: "DELETE" }),

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
      // Seed/demo audio keeps its static playback_url (the server only strips
      // real uploaded masters). Only route through the gated stream endpoint
      // when the server withheld the URL.
      if (asset.playback_url) return asset;
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
  sharedNote: (token: string, body: {
    song_id: string;
    anchor_version_id: string;
    body: string;
    timestamp_start_ms?: number;
    scope?: "song" | "version";
    visibility?: "everyone" | "internal" | "private";
  }) => request<VisibleNote>(`/shared/${token}/notes`, { method: "POST", body: JSON.stringify(body) }),
  /** PUBLIC — recipient asks the workspace owner for Playback access. */
  sharedRequestAccess: (token: string, body: { name: string; email: string }) =>
    request<{
      request: {
        request_id: string;
        workspace_id: string;
        name: string;
        email: string;
        source_token?: string;
        source_song_title?: string;
        status: "pending" | "approved" | "dismissed";
        created_at: string;
      };
    }>(`/shared/${token}/access-request`, { method: "POST", body: JSON.stringify(body) }),

  firstListen: async (token: string) => {
    const payload = await request<FirstListenPayload>(`/listen/${token}`);
    if (payload.asset && !payload.asset.playback_url) {
      payload.asset = { ...payload.asset, playback_url: `${API_URL}/listen/${token}/stream/${payload.version.version_id}` };
    }
    return payload;
  },
  firstListenEvent: (token: string, body: {
    event_type: ListeningEventType;
    playback_position_ms?: number;
    percent_complete?: number;
    intensity?: number;
    note_text?: string;
    metadata?: Record<string, unknown>;
  }) => request<{ event: ListeningEvent; report: Record<string, unknown>; recipient: ShareSessionRecipient }>(
    `/listen/${token}/events`,
    { method: "POST", body: JSON.stringify(body) },
  ),
  firstListenDecision: (token: string, body: {
    response_value: DecisionResponseValue;
    text_note?: string;
    confidence?: number;
    voice_note_storage_path?: string;
  }) => request<{ response: DecisionResponse; report: Record<string, unknown> }>(
    `/listen/${token}/decision`,
    { method: "POST", body: JSON.stringify(body) },
  ),
  requestFirstListenReplay: (token: string) =>
    request<FirstListenPayload>(`/listen/${token}/replay-request`, { method: "POST", body: JSON.stringify({}) }),

  recipientRoom: async (token: string) => {
    const payload = await request<ListeningRoomPayload>(`/room/${token}`);
    const versionIdByAsset = new Map<string, string>();
    for (const version of payload.versions) {
      versionIdByAsset.set(version.file_asset_id, version.version_id);
    }
    payload.assets = payload.assets.map((asset) => {
      if (asset.playback_url) return asset;
      const versionID = versionIdByAsset.get(asset.asset_id);
      return versionID ? { ...asset, playback_url: `${API_URL}/room/${token}/stream/${versionID}` } : asset;
    });
    return payload;
  },
  recipientRoomState: (token: string) => request<ListeningRoomState>(`/room/${token}/state`),
  joinRoom: (token: string, body: { display_name?: string; email?: string; phone?: string; participant_id?: string }) =>
    request<{ participant: ListeningRoomParticipant; room: ListeningRoomPayload }>(
      `/room/${token}/join`,
      { method: "POST", body: JSON.stringify(body) },
    ),
  roomEvent: (token: string, body: {
    participant_id?: string;
    event_type: ListeningEventType;
    playback_position_ms?: number;
    percent_complete?: number;
    intensity?: number;
    note_text?: string;
    reaction_type?: string;
    metadata?: Record<string, unknown>;
  }) => request<{ event: ListeningEvent; room: ListeningRoomPayload }>(
    `/room/${token}/events`,
    { method: "POST", body: JSON.stringify(body) },
  ),
  roomFirstTake: (token: string, body: { participant_id?: string; response_value: DecisionResponseValue; text_note?: string }) =>
    request<{ response: DecisionResponse; room: ListeningRoomPayload }>(
      `/room/${token}/first-take`,
      { method: "POST", body: JSON.stringify(body) },
    ),
  roomNote: (token: string, body: { participant_id?: string; playback_position_ms?: number; note_text?: string; reaction_type?: string }) =>
    request<{ event: ListeningEvent; room: ListeningRoomPayload }>(
      `/room/${token}/notes`,
      { method: "POST", body: JSON.stringify(body) },
    ),

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

  /** Finalize an uploaded object into a brand-new song + v1 (drop-anywhere path). */
  finalizeNewSong: (body: {
    storagePath: string;
    publicUrl: string;
    filename: string;
    title: string;
    contentType?: string;
    fileSizeBytes: number;
    durationMs?: number;
    sampleRate?: number;
    artist?: string;
    projectName?: string;
    roomExternalId?: string;
    versionLabel?: string;
    versionType?: string;
  }) =>
    request<{
      assetExternalId: string;
      versionExternalId: string;
      versionNumber: number;
      songExternalId: string;
    }>("/storage/finalize-new-song", { method: "POST", body: JSON.stringify(body) }),
};

// =====================================================================
// Audio upload helper — picks duration via Web Audio API, uploads to
// Supabase Storage via signed URL, finalizes the version row.
// =====================================================================
/**
 * Shared steps 1–3 of every audio upload: mint a signed URL, best-effort
 * probe duration/sample-rate via Web Audio, then PUT straight to storage.
 * `uploadAudio` (new version of an existing song) and `uploadNewSong`
 * (drop-anywhere library add) differ only in which finalize they call.
 */
async function pushAudioToStorage(
  file: File,
  songExternalId: string | undefined,
  onProgress?: (pct: number) => void
): Promise<{
  sig: Awaited<ReturnType<typeof api.signUpload>>;
  durationMs?: number;
  sampleRate?: number;
}> {
  // 1) Ask API for a signed upload URL
  const sig = await api.signUpload({
    filename: file.name,
    contentType: file.type || "audio/mpeg",
    songExternalId,
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

  return { sig, durationMs, sampleRate };
}

export async function uploadAudio(
  file: File,
  opts: { songExternalId: string; versionLabel?: string; versionType?: string },
  onProgress?: (pct: number) => void
): Promise<{ assetExternalId: string; versionExternalId: string; versionNumber: number }> {
  const { sig, durationMs, sampleRate } = await pushAudioToStorage(file, opts.songExternalId, onProgress);

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

/**
 * Upload a file as a BRAND-NEW song (the drop-anywhere path): same sign →
 * probe → PUT mechanics as uploadAudio, finalized via /storage/finalize-new-song
 * which creates the song row + v1 in one shot.
 */
export async function uploadNewSong(
  file: File,
  opts: { title: string; artist?: string; projectName?: string },
  onProgress?: (pct: number) => void
): Promise<{ songExternalId: string; versionExternalId: string; versionNumber: number }> {
  const { sig, durationMs, sampleRate } = await pushAudioToStorage(file, undefined, onProgress);

  const result = await api.finalizeNewSong({
    storagePath: sig.storagePath,
    publicUrl: sig.publicUrl,
    filename: file.name,
    title: opts.title,
    contentType: file.type || "audio/mpeg",
    fileSizeBytes: file.size,
    durationMs,
    sampleRate,
    artist: opts.artist,
    projectName: opts.projectName,
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
