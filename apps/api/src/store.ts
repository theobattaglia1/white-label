import { randomUUID } from "node:crypto";
import {
  answerWorkspaceQuestion,
  appendVersion,
  computeDeliverables,
  createSeedSnapshot,
  getVisibleNotesForVersion,
  promoteVersion,
  proposeUploadGroupings,
  resolveShareLink,
  type ActivityEvent,
  type Approval,
  type DownloadPolicy,
  type FileAsset,
  type LinkAccess,
  type Note,
  type NoteVisibility,
  type ShareLink,
  type VersionPolicy,
  type VersionType,
  type WorkspaceSnapshot,
} from "@pmw/shared";
import { hashToken, makeShareToken } from "./hash";
import { loadSnapshotFromSupabase } from "./supabase-loader";
import { persistNote, persistNoteReopen, persistNoteResolution } from "./supabase-persist";
import { isSupabaseEnabled } from "./supabase";

export interface AuthContext {
  userID: string;
}

type UploadState = {
  upload_id: string;
  workspace_id: string;
  filename: string;
  size_bytes: number;
  received_bytes: number;
  checksum_sha256?: string;
  created_at: string;
};

export class WorkspaceStore {
  private snapshot: WorkspaceSnapshot = createSeedSnapshot();
  private uploads = new Map<string, UploadState>();

  get data(): WorkspaceSnapshot {
    return this.snapshot;
  }

  /**
   * Hydrate from Supabase if SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY are
   * set; otherwise keep the in-memory seed. Call from server boot before
   * `server.listen()`.
   */
  async hydrate(): Promise<void> {
    if (!isSupabaseEnabled()) return;
    const fromDb = await loadSnapshotFromSupabase();
    if (fromDb) this.snapshot = fromDb;
  }

  reset(): WorkspaceSnapshot {
    this.snapshot = createSeedSnapshot();
    this.uploads.clear();
    return this.snapshot;
  }

  me(auth: AuthContext) {
    const user = this.snapshot.users.find((candidate) => candidate.user_id === auth.userID) ?? this.snapshot.users[0];
    const memberships = this.snapshot.memberships.filter((membership) => membership.user_id === user.user_id);
    return { user, memberships };
  }

  listRooms(workspaceID: string) {
    return this.snapshot.rooms.filter((room) => room.workspace_id === workspaceID);
  }

  getRoom(roomID: string) {
    const room = this.snapshot.rooms.find((candidate) => candidate.room_id === roomID);
    if (!room) throw new Error("Room not found");
    const songs = this.snapshot.songs.filter((song) => song.primary_room_id === room.room_id);
    return {
      room,
      songs,
      versions: this.snapshot.versions.filter((version) => songs.some((song) => song.song_id === version.song_id)),
      assets: this.snapshot.assets,
      notes: this.snapshot.notes.filter((note) => songs.some((song) => song.song_id === note.song_id)),
      links: this.snapshot.shareLinks.filter((link) => link.target_id === room.room_id),
    };
  }

  getSong(songID: string) {
    const song = this.snapshot.songs.find((candidate) => candidate.song_id === songID);
    if (!song) throw new Error("Song not found");
    const versions = this.snapshot.versions
      .filter((version) => version.song_id === song.song_id)
      .sort((a, b) => a.version_number - b.version_number);
    const assets = this.snapshot.assets.filter((asset) => versions.some((version) => version.file_asset_id === asset.asset_id));
    const currentVersion = versions.find((version) => version.version_id === song.current_version_id) ?? versions.at(-1);
    const notes = currentVersion
      ? getVisibleNotesForVersion({
          version: currentVersion,
          versions,
          notes: this.snapshot.notes,
          assets: this.snapshot.assets,
        })
      : [];
    return {
      song,
      versions,
      assets,
      currentVersion,
      notes,
      approvals: this.snapshot.approvals.filter((approval) =>
        versions.some((version) => version.version_id === approval.version_id)
      ),
      links: this.snapshot.shareLinks.filter((link) => link.target_type === "song" && link.target_id === song.song_id),
      deliverables: computeDeliverables(song, this.snapshot.versions, this.snapshot.assets),
    };
  }

  getVersionNotes(versionID: string) {
    const version = this.snapshot.versions.find((candidate) => candidate.version_id === versionID);
    if (!version) throw new Error("Version not found");
    const versions = this.snapshot.versions.filter((candidate) => candidate.song_id === version.song_id);
    return getVisibleNotesForVersion({
      version,
      versions,
      notes: this.snapshot.notes,
      assets: this.snapshot.assets,
    });
  }

  createAsset(params: {
    workspaceID: string;
    filename: string;
    sizeBytes?: number;
    checksum?: string;
    durationMs?: number;
    lufs?: number;
  }): FileAsset {
    const id = randomUUID();
    const duration = params.durationMs ?? 186000 + Math.round(Math.random() * 28000);
    const asset: FileAsset = {
      asset_id: id,
      workspace_id: params.workspaceID,
      original_filename: params.filename,
      normalized_filename: params.filename.toLowerCase().replace(/\s+/g, "-"),
      key_original: `originals/${id}`,
      key_flac: `derivatives/${id}.flac`,
      key_aac_256: `derivatives/${id}-256.aac`,
      key_aac_128: `derivatives/${id}-128.aac`,
      key_waveform_json: `waveforms/${id}.json`,
      mime_type: "audio/wav",
      file_size_bytes: params.sizeBytes ?? duration * 88,
      checksum_sha256: params.checksum ?? `sha256-${id}`,
      duration_ms: duration,
      sample_rate: 48000,
      bit_depth: 24,
      loudness_lufs: params.lufs ?? -14,
      true_peak_db: -1.0,
      virus_scan_status: "clean",
      transcoding_status: "ready",
      waveform_peaks: Array.from({ length: 96 }, (_, index) =>
        Number((0.16 + Math.abs(Math.sin(index * 0.21 + duration / 10000)) * 0.78).toFixed(2))
      ),
      created_at: new Date().toISOString(),
    };
    this.snapshot.assets = [...this.snapshot.assets, asset];
    return asset;
  }

  addVersion(songID: string, auth: AuthContext, params: { filename: string; type?: VersionType; label?: string; durationMs?: number; lufs?: number }) {
    const song = this.snapshot.songs.find((candidate) => candidate.song_id === songID);
    if (!song) throw new Error("Song not found");
    const asset = this.createAsset({
      workspaceID: song.workspace_id,
      filename: params.filename,
      durationMs: params.durationMs,
      lufs: params.lufs,
    });
    const result = appendVersion({
      song,
      versions: this.snapshot.versions,
      asset,
      uploadedBy: auth.userID,
      type: params.type,
      label: params.label,
      idFactory: randomUUID,
    });
    this.snapshot.songs = this.snapshot.songs.map((candidate) =>
      candidate.song_id === song.song_id ? result.song : candidate
    );
    this.snapshot.versions = result.versions;
    this.recordEvent({
      workspace_id: song.workspace_id,
      actor_user_id: auth.userID,
      event_type: "uploaded_version",
      target_type: "version",
      target_id: result.version.version_id,
      song_id: song.song_id,
      version_id: result.version.version_id,
      metadata: { filename: params.filename, prior_current_version_id: song.current_version_id },
    });
    return this.getSong(songID);
  }

  promoteVersion(versionID: string, auth: AuthContext) {
    const version = this.snapshot.versions.find((candidate) => candidate.version_id === versionID);
    if (!version) throw new Error("Version not found");
    const song = this.snapshot.songs.find((candidate) => candidate.song_id === version.song_id);
    if (!song) throw new Error("Song not found");
    const result = promoteVersion({
      song,
      versions: this.snapshot.versions,
      versionID,
    });
    this.snapshot.songs = this.snapshot.songs.map((candidate) =>
      candidate.song_id === song.song_id ? result.song : candidate
    );
    this.snapshot.versions = result.versions;
    this.recordEvent({
      workspace_id: song.workspace_id,
      actor_user_id: auth.userID,
      event_type: "changed_permission",
      target_type: "version",
      target_id: versionID,
      song_id: song.song_id,
      version_id: versionID,
      metadata: { action: "set_current" },
    });
    return this.getSong(song.song_id);
  }

  patchVersion(versionID: string, patch: { version_label?: string; type?: VersionType }) {
    this.snapshot.versions = this.snapshot.versions.map((version) =>
      version.version_id === versionID
        ? {
            ...version,
            version_label: patch.version_label ?? version.version_label,
            type: patch.type ?? version.type,
          }
        : version
    );
    return this.snapshot.versions.find((version) => version.version_id === versionID);
  }

  createNote(auth: AuthContext, params: {
    song_id: string;
    anchor_version_id: string;
    body: string;
    timestamp_start_ms?: number;
    timestamp_end_ms?: number;
    scope?: "song" | "version";
    visibility?: NoteVisibility;
    assigned_to_user_id?: string;
    assigned_to_role?: string;
    author_guest_label?: string;
  }) {
    const song = this.snapshot.songs.find((candidate) => candidate.song_id === params.song_id);
    if (!song) throw new Error("Song not found");
    const note: Note = {
      note_id: randomUUID(),
      song_id: params.song_id,
      anchor_version_id: params.anchor_version_id,
      room_id: song.primary_room_id,
      author_user_id: params.author_guest_label ? undefined : auth.userID,
      author_guest_label: params.author_guest_label,
      body: params.body,
      scope: params.scope ?? "song",
      visibility: params.visibility ?? "everyone",
      timestamp_start_ms: params.timestamp_start_ms,
      timestamp_end_ms: params.timestamp_end_ms,
      timestamp_uncertain: false,
      assigned_to_user_id: params.assigned_to_user_id,
      assigned_to_role: params.assigned_to_role as Note["assigned_to_role"],
      priority: "normal",
      status: "open",
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };
    this.snapshot.notes = [...this.snapshot.notes, note];
    this.recordEvent({
      workspace_id: song.workspace_id,
      actor_user_id: note.author_user_id,
      actor_recipient_label: note.author_guest_label,
      event_type: "commented",
      target_type: "note",
      target_id: note.note_id,
      song_id: song.song_id,
      version_id: note.anchor_version_id,
      metadata: { timestamp_ms: note.timestamp_start_ms },
    });
    // Best-effort write-through to Supabase. Failures log only.
    void persistNote(note).catch(() => undefined);
    return note;
  }

  patchNote(noteID: string, auth: AuthContext, patch: { status?: "open" | "resolved"; body?: string; assigned_to_user_id?: string }) {
    const now = new Date().toISOString();
    let touchedNote: Note | undefined;
    let resolvingTransition = false;
    let resolvingOnVersion: string | undefined;
    this.snapshot.notes = this.snapshot.notes.map((note) => {
      if (note.note_id !== noteID) return note;
      const currentVersion = this.snapshot.songs.find((song) => song.song_id === note.song_id)?.current_version_id;
      const resolving = patch.status === "resolved" && note.status !== "resolved";
      resolvingTransition = resolving;
      resolvingOnVersion = currentVersion;
      const next: Note = {
        ...note,
        body: patch.body ?? note.body,
        assigned_to_user_id: patch.assigned_to_user_id ?? note.assigned_to_user_id,
        status: patch.status ?? note.status,
        resolved_by: resolving ? auth.userID : patch.status === "open" ? undefined : note.resolved_by,
        resolved_at: resolving ? now : patch.status === "open" ? undefined : note.resolved_at,
        resolved_on_version_id: resolving ? currentVersion : patch.status === "open" ? undefined : note.resolved_on_version_id,
        updated_at: now,
      };
      touchedNote = next;
      return next;
    });
    // Write-through to Supabase
    if (touchedNote) {
      if (resolvingTransition && resolvingOnVersion) {
        void persistNoteResolution(noteID, auth.userID, resolvingOnVersion).catch(() => undefined);
      } else if (patch.status === "open") {
        void persistNoteReopen(noteID).catch(() => undefined);
      }
    }
    return touchedNote;
  }

  createApproval(versionID: string, auth: AuthContext, state: Approval["state"], note?: string) {
    const version = this.snapshot.versions.find((candidate) => candidate.version_id === versionID);
    if (!version) throw new Error("Version not found");
    const approval: Approval = {
      approval_id: randomUUID(),
      version_id: versionID,
      actor_user_id: auth.userID,
      state,
      note,
      created_at: new Date().toISOString(),
    };
    this.snapshot.approvals = [...this.snapshot.approvals, approval];
    this.snapshot.versions = this.snapshot.versions.map((candidate) =>
      candidate.version_id === versionID ? { ...candidate, is_approved: state === "approved" } : candidate
    );
    if (state === "approved") {
      this.snapshot.songs = this.snapshot.songs.map((song) =>
        song.song_id === version.song_id
          ? { ...song, approved_version_id: versionID, status: "approved", updated_at: new Date().toISOString() }
          : song
      );
    }
    this.recordEvent({
      workspace_id: this.snapshot.songs.find((song) => song.song_id === version.song_id)?.workspace_id ?? "",
      actor_user_id: auth.userID,
      event_type: state === "revision_requested" ? "requested_revision" : "approved_version",
      target_type: "version",
      target_id: versionID,
      song_id: version.song_id,
      version_id: versionID,
      metadata: { state, note },
    });
    return approval;
  }

  createLink(auth: AuthContext, params: {
    workspace_id: string;
    target_type: "song" | "room";
    target_id: string;
    link_name?: string;
    access_mode?: LinkAccess;
    download_policy?: DownloadPolicy;
    version_policy?: VersionPolicy;
    requires_identity?: boolean;
    watermark_enabled?: boolean;
    allow_comments?: boolean;
    allow_approval?: boolean;
    allow_forwarding?: boolean;
    expires_at?: string;
  }) {
    const token = makeShareToken();
    const link: ShareLink = {
      link_id: randomUUID(),
      workspace_id: params.workspace_id,
      target_type: params.target_type,
      target_id: params.target_id,
      token_hash: hashToken(token),
      demo_token: token,
      link_name: params.link_name,
      access_mode: params.access_mode ?? "public",
      download_policy: params.download_policy ?? "none",
      version_policy: params.version_policy ?? "latest_only",
      requires_identity: params.requires_identity ?? params.access_mode === "identity_required",
      watermark_enabled: params.watermark_enabled ?? true,
      allow_comments: params.allow_comments ?? true,
      allow_approval: params.allow_approval ?? false,
      allow_forwarding: params.allow_forwarding ?? true,
      expires_at: params.expires_at,
      created_by: auth.userID,
      created_at: new Date().toISOString(),
    };
    this.snapshot.shareLinks = [...this.snapshot.shareLinks, link];
    this.recordEvent({
      workspace_id: params.workspace_id,
      actor_user_id: auth.userID,
      event_type: "created_share_link",
      target_type: params.target_type,
      target_id: params.target_id,
      link_id: link.link_id,
      metadata: { version_policy: link.version_policy, download_policy: link.download_policy },
    });
    return { link, token };
  }

  patchLink(linkID: string, auth: AuthContext, patch: Partial<ShareLink>) {
    const existing = this.snapshot.shareLinks.find((link) => link.link_id === linkID);
    if (!existing) throw new Error("Link not found");
    this.snapshot.shareLinks = this.snapshot.shareLinks.map((link) =>
      link.link_id === linkID
        ? {
            ...link,
            ...patch,
            token_hash: link.token_hash,
            demo_token: link.demo_token,
            link_id: link.link_id,
          }
        : link
    );
    this.recordEvent({
      workspace_id: existing.workspace_id,
      actor_user_id: auth.userID,
      event_type: "changed_permission",
      target_type: existing.target_type,
      target_id: existing.target_id,
      link_id: existing.link_id,
      metadata: patch,
    });
    return this.snapshot.shareLinks.find((link) => link.link_id === linkID);
  }

  revokeLink(linkID: string, auth: AuthContext) {
    return this.patchLink(linkID, auth, { revoked_at: new Date().toISOString() });
  }

  resolveShared(token: string) {
    const matchingHash = hashToken(token);
    const seeded = this.snapshot.shareLinks.find((link) => link.demo_token === token);
    const resolved = resolveShareLink({
      tokenHash: seeded?.token_hash ?? matchingHash,
      links: this.snapshot.shareLinks,
      songs: this.snapshot.songs,
      versions: this.snapshot.versions,
    });
    const assets = this.snapshot.assets.filter((asset) => resolved.versions.some((version) => version.file_asset_id === asset.asset_id));
    const rooms = this.snapshot.rooms.filter((room) => resolved.songs.some((song) => song.primary_room_id === room.room_id));
    return { ...resolved, assets, rooms };
  }

  createUpload(workspaceID: string, params: { filename: string; size_bytes: number; checksum_sha256?: string }) {
    const upload: UploadState = {
      upload_id: randomUUID(),
      workspace_id: workspaceID,
      filename: params.filename,
      size_bytes: params.size_bytes,
      received_bytes: 0,
      checksum_sha256: params.checksum_sha256,
      created_at: new Date().toISOString(),
    };
    this.uploads.set(upload.upload_id, upload);
    return upload;
  }

  patchUpload(uploadID: string, bytes: number) {
    const upload = this.uploads.get(uploadID);
    if (!upload) throw new Error("Upload not found");
    upload.received_bytes = Math.min(upload.size_bytes, upload.received_bytes + bytes);
    return upload;
  }

  finalizeUpload(uploadID: string) {
    const upload = this.uploads.get(uploadID);
    if (!upload) throw new Error("Upload not found");
    return this.createAsset({
      workspaceID: upload.workspace_id,
      filename: upload.filename,
      sizeBytes: upload.size_bytes,
      checksum: upload.checksum_sha256,
    });
  }

  proposeGroupings(files: Array<{ filename: string; sizeBytes?: number }>) {
    return proposeUploadGroupings(files);
  }

  inbox(userID: string) {
    return this.snapshot.songs.map((song, index) => {
      const currentVersion = this.snapshot.versions.find((version) => version.version_id === song.current_version_id);
      const asset = this.snapshot.assets.find((candidate) => candidate.asset_id === currentVersion?.file_asset_id);
      const room = this.snapshot.rooms.find((candidate) => candidate.room_id === song.primary_room_id);
      if (!currentVersion || !asset || !room) return undefined;
      const listened = this.snapshot.activityEvents.some(
        (event) => event.actor_user_id === userID && event.event_type === "played_track" && event.version_id === currentVersion.version_id
      );
      return {
        song,
        room,
        current_version: currentVersion,
        asset,
        shared_by: "Maya Chen",
        new_since_last_listen: !listened || index === 0,
        last_listened_at: listened ? "2026-05-22T16:30:00.000Z" : undefined,
      };
    }).filter(Boolean);
  }

  analyticsForSong(songID: string) {
    return {
      events: this.snapshot.activityEvents.filter((event) => event.song_id === songID),
      by_version: this.snapshot.versions
        .filter((version) => version.song_id === songID)
        .map((version) => ({
          version,
          plays: this.snapshot.activityEvents.filter(
            (event) => event.event_type === "played_track" && event.version_id === version.version_id
          ).length,
          comments: this.snapshot.notes.filter((note) => note.anchor_version_id === version.version_id).length,
        })),
    };
  }

  ask(question: string) {
    return answerWorkspaceQuestion(this.snapshot, question);
  }

  private recordEvent(event: Omit<ActivityEvent, "event_id" | "created_at">) {
    this.snapshot.activityEvents = [
      ...this.snapshot.activityEvents,
      {
        ...event,
        event_id: randomUUID(),
        created_at: new Date().toISOString(),
      },
    ];
  }
}

export const store = new WorkspaceStore();

