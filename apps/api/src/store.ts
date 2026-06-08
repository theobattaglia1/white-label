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
  type Membership,
  type Note,
  type NoteVisibility,
  type ShareLink,
  type ShareRecipient,
  type ShareRecipientRole,
  type User,
  type VersionPolicy,
  type VersionType,
  type WorkspaceSnapshot,
} from "@pmw/shared";
import { answerWorkspaceQuestionLlm } from "./assistant";
import { hashToken, makeShareToken } from "./hash";
import { loadSnapshotFromSupabase } from "./supabase-loader";
import {
  persistNote,
  persistNoteReopen,
  persistNoteResolution,
  persistLinkRevocation,
  persistShareLink,
  persistShareRecipientPatch,
  persistShareRecipients,
} from "./supabase-persist";
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

  // TODO(authz): per-resource membership/ownership authorization in store mutations — see runbook

  me(auth: AuthContext): { user: User | null; memberships: Membership[] } {
    const user =
      this.snapshot.users.find((candidate) => candidate.user_id === auth.userID) ?? null;
    if (!user) return { user: null, memberships: [] };
    const memberships = this.snapshot.memberships.filter(
      (membership) => membership.user_id === user.user_id,
    );
    return { user, memberships };
  }

  listRooms(workspaceID: string) {
    return this.snapshot.rooms.filter((room) => room.workspace_id === workspaceID);
  }

  getRoom(roomID: string) {
    const canonicalRoomID = roomID === "room-secret-album" ? "room-hudson-ingram-lp" : roomID;
    const room = this.snapshot.rooms.find((candidate) => candidate.room_id === canonicalRoomID);
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
    target_type: "song" | "room" | "playlist";
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
    void persistShareLink(link).catch(() => undefined);
    return { link, token };
  }

  listShareRecipients(linkID: string): ShareRecipient[] {
    return this.snapshot.shareRecipients
      .filter((recipient) => recipient.link_id === linkID)
      .sort((a, b) => a.email.localeCompare(b.email));
  }

  inviteShareRecipients(
    linkID: string,
    auth: AuthContext,
    recipients: Array<{ email: string; display_name?: string; role?: ShareRecipientRole }>,
  ): ShareRecipient[] {
    const link = this.snapshot.shareLinks.find((candidate) => candidate.link_id === linkID);
    if (!link) throw new Error("Link not found");
    const now = new Date().toISOString();
    const changed: ShareRecipient[] = [];

    for (const input of recipients) {
      const email = input.email.trim().toLowerCase();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) continue;
      const role = input.role ?? "listen";
      const existing = this.snapshot.shareRecipients.find(
        (candidate) => candidate.link_id === linkID && candidate.email.toLowerCase() === email,
      );

      if (existing) {
        const updated: ShareRecipient = {
          ...existing,
          display_name: input.display_name?.trim() || existing.display_name,
          role,
          last_sent_at: now,
          revoked_at: undefined,
        };
        this.snapshot.shareRecipients = this.snapshot.shareRecipients.map((candidate) =>
          candidate.recipient_id === existing.recipient_id ? updated : candidate
        );
        changed.push(updated);
        void persistShareRecipientPatch(updated).catch(() => undefined);
      } else {
        const recipient: ShareRecipient = {
          recipient_id: `shr-${randomUUID()}`,
          link_id: linkID,
          email,
          display_name: input.display_name?.trim() || undefined,
          role,
          invited_by: auth.userID,
          invited_at: now,
          last_sent_at: now,
        };
        this.snapshot.shareRecipients = [...this.snapshot.shareRecipients, recipient];
        changed.push(recipient);
      }
    }

    if (changed.length > 0) {
      this.recordEvent({
        workspace_id: link.workspace_id,
        actor_user_id: auth.userID,
        event_type: "invited_recipient",
        target_type: link.target_type,
        target_id: link.target_id,
        link_id: link.link_id,
        metadata: {
          count: changed.length,
          recipients: changed.map((recipient) => ({ email: recipient.email, role: recipient.role })),
        },
      });
      void persistShareRecipients(changed).catch(() => undefined);
    }

    return this.listShareRecipients(linkID);
  }

  patchShareRecipient(
    linkID: string,
    recipientID: string,
    auth: AuthContext,
    patch: Partial<Pick<ShareRecipient, "role" | "display_name" | "revoked_at">>,
  ): ShareRecipient {
    const link = this.snapshot.shareLinks.find((candidate) => candidate.link_id === linkID);
    if (!link) throw new Error("Link not found");
    const existing = this.snapshot.shareRecipients.find(
      (recipient) => recipient.link_id === linkID && recipient.recipient_id === recipientID,
    );
    if (!existing) throw new Error("Recipient not found");
    const updated: ShareRecipient = {
      ...existing,
      display_name: patch.display_name ?? existing.display_name,
      role: patch.role ?? existing.role,
      revoked_at: Object.prototype.hasOwnProperty.call(patch, "revoked_at") ? patch.revoked_at : existing.revoked_at,
    };
    this.snapshot.shareRecipients = this.snapshot.shareRecipients.map((recipient) =>
      recipient.recipient_id === recipientID ? updated : recipient
    );
    this.recordEvent({
      workspace_id: link.workspace_id,
      actor_user_id: auth.userID,
      event_type: "changed_permission",
      target_type: link.target_type,
      target_id: link.target_id,
      link_id: link.link_id,
      metadata: { recipient_id: recipientID, email: updated.email, role: updated.role, revoked_at: updated.revoked_at },
    });
    void persistShareRecipientPatch(updated).catch(() => undefined);
    return updated;
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
    // Write revocation state through to Supabase so it survives a restart.
    // Without this, re-hydration resets revoked_at to null and a revoked link
    // (and the unreleased audio behind it) comes back. Keyed on the stable
    // token_hash. Best-effort: failures log, never break the in-memory action.
    if (Object.prototype.hasOwnProperty.call(patch, "revoked_at")) {
      void persistLinkRevocation(existing.token_hash, patch.revoked_at ?? null).catch(() => undefined);
    }
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
      playlistItems: this.snapshot.playlistItems,
    });
    // Withhold the permanent public playback_url before it reaches a recipient,
    // but ONLY for real uploaded audio (an absolute https URL → an actual object
    // in Supabase Storage). Those are the unreleased masters that must stream
    // through the revocation-gated GET /shared/:token/stream/:versionId instead
    // of a permanent URL that outlives revocation. Seed/demo audio is served as
    // a static RELATIVE path (/seed-audio/…), isn't in the bucket, and is
    // harmless to expose — leave it so demo playback keeps working.
    const assets = this.snapshot.assets
      .filter((asset) => resolved.versions.some((version) => version.file_asset_id === asset.asset_id))
      .map((asset) => {
        const isRealStorageUrl =
          typeof asset.playback_url === "string" && /^https?:\/\//i.test(asset.playback_url);
        return isRealStorageUrl ? { ...asset, playback_url: undefined } : asset;
      });
    const rooms = this.snapshot.rooms.filter((room) => resolved.songs.some((song) => song.primary_room_id === room.room_id));
    // If this is a playlist link, attach the playlist meta so the recipient
    // can render the playlist hero (cover + title + ordered queue).
    const playlist =
      resolved.link.target_type === "playlist"
        ? this.snapshot.playlists.find((p) => p.playlist_id === resolved.link.target_id) ?? null
        : null;
    const notes = resolved.songs.flatMap((song) => {
      const songVersions = resolved.versions.filter((version) => version.song_id === song.song_id);
      const displayVersion = songVersions.find((version) => version.is_current) ?? songVersions.at(-1);
      if (!displayVersion) return [];
      return getVisibleNotesForVersion({
        version: displayVersion,
        versions: songVersions,
        notes: this.snapshot.notes,
        assets: this.snapshot.assets,
      });
    });
    return { ...resolved, assets, rooms, playlist, notes };
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

  /**
   * Claude-backed Ask, focused by the optional song/version the user is viewing.
   * Falls back to the deterministic `ask` above when no API key is configured
   * or the LLM call fails (handled inside answerWorkspaceQuestionLlm).
   */
  askLlm(question: string, context?: { song_id?: string; version_id?: string }) {
    return answerWorkspaceQuestionLlm(this.snapshot, question, context);
  }

  /**
   * Log that a recipient opened a share link. The analytics + activity surfaces
   * already render `opened_link`, but nothing was writing it — so the manager
   * had no way to tell a link they sent was ever opened (only whether audio was
   * played). Best-effort and never throws: opening a link must not depend on
   * logging succeeding. In-memory only for now (runtime activity isn't yet
   * written through to Supabase — see runbook P2).
   */
  recordShareOpen(token: string) {
    try {
      const link = this.snapshot.shareLinks.find(
        (candidate) => candidate.demo_token === token || candidate.token_hash === hashToken(token),
      );
      if (!link || link.revoked_at) return;
      this.recordEvent({
        workspace_id: link.workspace_id,
        event_type: "opened_link",
        target_type: link.target_type,
        target_id: link.target_id,
        song_id: link.target_type === "song" ? link.target_id : undefined,
        link_id: link.link_id,
        metadata: { access_mode: link.access_mode },
      });
    } catch {
      /* opening must not depend on logging */
    }
  }

  recordShareDownload(token: string, versionID: string) {
    try {
      const link = this.snapshot.shareLinks.find(
        (candidate) => candidate.demo_token === token || candidate.token_hash === hashToken(token),
      );
      const version = this.snapshot.versions.find((candidate) => candidate.version_id === versionID);
      if (!link || !version || link.revoked_at) return;
      this.recordEvent({
        workspace_id: link.workspace_id,
        event_type: "downloaded_file",
        target_type: "version",
        target_id: version.version_id,
        song_id: version.song_id,
        version_id: version.version_id,
        link_id: link.link_id,
        metadata: { access_mode: link.access_mode, download_policy: link.download_policy },
      });
    } catch {
      /* downloading must not depend on logging */
    }
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
