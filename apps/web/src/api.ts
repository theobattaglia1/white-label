import type { AssistantAnswer, FileAsset, Room, ShareLink, Song, Version, VisibleNote } from "@pmw/shared";

const API_URL = import.meta.env.VITE_API_URL ?? "http://localhost:4317";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${API_URL}${path}`, {
    ...init,
    headers: {
      "content-type": "application/json",
      "x-user-id": "usr-theo",
      ...(init?.headers ?? {}),
    },
  });
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
};

export const api = {
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
  ask: (question: string) =>
    request<AssistantAnswer>("/assistant/ask", { method: "POST", body: JSON.stringify({ question }) }),
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
  createLink: (body: Partial<ShareLink> & { workspace_id: string; target_type: "song" | "room"; target_id: string }) =>
    request<{ link: ShareLink; token: string }>("/links", { method: "POST", body: JSON.stringify(body) }),
  revokeLink: (id: string) => request<ShareLink>(`/links/${id}/revoke`, { method: "POST", body: JSON.stringify({}) }),
  shared: (token: string) => request<SharedPayload>(`/shared/${token}`),
};

export function assetForVersion(assets: FileAsset[], version?: Version): FileAsset | undefined {
  if (!version) return undefined;
  return assets.find((asset) => asset.asset_id === version.file_asset_id);
}

export function versionsForSong(versions: Version[], songID: string): Version[] {
  return versions.filter((version) => version.song_id === songID).sort((a, b) => a.version_number - b.version_number);
}

