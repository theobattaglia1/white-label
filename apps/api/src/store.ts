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
  type AccessRequest,
  type ActivityEvent,
  type Approval,
  type DecisionRequestType,
  type DecisionResponse,
  type DecisionResponseValue,
  type DownloadPolicy,
  type FileAsset,
  type LinkAccess,
  type ListeningEvent,
  type ListeningEventType,
  type ListeningReport,
  type ListeningReportVisibility,
  type ListeningRoom,
  type ListeningRoomParticipant,
  type ListeningRoomPlaybackState,
  type ListeningRoomRetentionPolicy,
  type ListeningRoomState,
  type ListeningRoomTrack,
  type ListeningRoomType,
  type Membership,
  type Note,
  type NoteVisibility,
  type ShareLink,
  type ShareRecipient,
  type ShareRecipientRole,
  type ShareSession,
  type ShareSessionRecipient,
  type ShareAccessState,
  type TimestampedReaction,
  type TimestampedReactionType,
  type User,
  type UserPins,
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
  persistDecisionResponse,
  persistLinkRevocation,
  persistListeningEvent,
  persistListeningReport,
  persistListeningRoom,
  persistListeningRoomBundle,
  persistListeningRoomParticipant,
  persistListeningRoomState,
  persistShareLink,
  persistShareRecipientPatch,
  persistShareRecipients,
  persistShareSession,
  persistShareSessionRecipient,
  persistTimestampedReaction,
  persistVersionPatch,
  type PersistShareLinkResult,
} from "./supabase-persist";
import { getSupabase, isSupabaseEnabled } from "./supabase";
import type { StemJob } from "./stems";

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
  /** Ephemeral stem-split jobs (see stems.ts) — restart loses history by
   *  design; the durable artifact is key_stems_zip on the asset row. */
  readonly stemJobs = new Map<string, StemJob>();

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
    if (fromDb) {
      // accessRequests + userPins aren't persisted in Supabase yet — carry the
      // live in-memory arrays across re-hydrations so a mid-session hydrate
      // (after invites/uploads) doesn't silently drop them.
      this.snapshot = {
        ...fromDb,
        accessRequests: this.snapshot.accessRequests,
        userPins: this.snapshot.userPins,
      };
    }
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
    // Legacy alias: an old seed snapshot renamed "room-secret-album" to
    // "room-hudson-ingram-lp". Resolve against real data first — the alias is
    // only a fallback when the requested id genuinely doesn't exist, so the
    // rewrite can never 400 a room that actually does (production's real room
    // IS "room-secret-album").
    const room =
      this.snapshot.rooms.find((candidate) => candidate.room_id === roomID) ??
      (roomID === "room-secret-album"
        ? this.snapshot.rooms.find((candidate) => candidate.room_id === "room-hudson-ingram-lp")
        : undefined);
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

  /** Stamp key_stems_zip on an in-memory asset after the worker uploads. */
  setAssetStemsKey(assetID: string, key: string): FileAsset | undefined {
    this.snapshot.assets = this.snapshot.assets.map((asset) =>
      asset.asset_id === assetID ? { ...asset, key_stems_zip: key } : asset,
    );
    return this.snapshot.assets.find((asset) => asset.asset_id === assetID);
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
    void persistVersionPatch(versionID, patch).catch(() => undefined);
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

  async createLink(auth: AuthContext, params: {
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
    // Durable-or-fail: await persistence instead of fire-and-forget. The token
    // we hand back must still resolve after a restart or on a sibling instance
    // — an unpersisted link dies with this process, and the recipient lands on
    // a dead /shared/<token> page. If the row can't be written, roll the link
    // back and fail the request so the client never copies a doomed URL.
    const persisted = await persistShareLink(link).catch((err): PersistShareLinkResult => ({
      ok: false,
      reason: "write_failed",
      detail: err instanceof Error ? err.message : String(err),
    }));
    if (!persisted.ok) {
      this.snapshot.shareLinks = this.snapshot.shareLinks.filter((candidate) => candidate.link_id !== link.link_id);
      // Log the REAL failure — the user-facing message below is intentionally
      // generic, so this line is the only place the underlying cause survives.
      console.warn(
        `[store] share link rolled back (${persisted.reason}) for ${link.target_type} ${link.target_id}: ${persisted.detail}`,
      );
      if (persisted.reason === "target_unresolved") {
        // 422: this song/workspace has no Supabase row (e.g. an upload that
        // only succeeded locally on the device) — retrying won't fix it.
        throw Object.assign(
          new Error("This song hasn't finished syncing to the cloud, so a link can't be created yet."),
          { statusCode: 422 },
        );
      }
      // 503: storage write unavailable — transient; retrying may succeed.
      throw Object.assign(
        new Error("Share link storage is temporarily unavailable — try again in a moment."),
        { statusCode: 503 },
      );
    }
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

  /** resolveShared with a Supabase read-through for tokens the in-memory
   *  snapshot doesn't know. Snapshots only hydrate at boot, and links are
   *  created on whichever instance served the POST — so a link created on a
   *  sibling instance (or right before a restart) used to 400 for the
   *  recipient even though its row exists in share_links. The recovered link
   *  is spliced into the snapshot so streams/notes/approvals resolve too. */
  async resolveSharedFresh(token: string) {
    try {
      return this.resolveShared(token);
    } catch (err) {
      const recovered = await this.recoverShareLinkFromSupabase(token).catch(() => false);
      if (!recovered) throw err;
      return this.resolveShared(token);
    }
  }

  private async recoverShareLinkFromSupabase(token: string): Promise<boolean> {
    const supabase = getSupabase();
    if (!supabase) return false;
    const tokenHash = hashToken(token);
    // Already in the snapshot (e.g. revoked or expired) — nothing to recover;
    // let the original resolveShared error stand.
    if (this.snapshot.shareLinks.some((link) => link.token_hash === tokenHash || link.demo_token === token)) {
      return false;
    }
    const { data: row, error } = await supabase
      .from("share_links")
      .select("*")
      .eq("token_hash", tokenHash)
      .maybeSingle();
    if (error || !row) return false;
    // Translate the row's UUID references back to the external ids the
    // snapshot speaks (same mapping as the boot-time loader).
    const targetTable = row.target_type === "song" ? "songs" : row.target_type === "room" ? "rooms" : "playlists";
    const targetColumn = row.target_type === "song" ? "song_id" : row.target_type === "room" ? "room_id" : "playlist_id";
    const { data: target } = await supabase
      .from(targetTable)
      .select("external_id")
      .eq(targetColumn, row.target_id)
      .maybeSingle();
    const { data: workspace } = await supabase
      .from("workspaces")
      .select("external_id")
      .eq("workspace_id", row.workspace_id)
      .maybeSingle();
    const link: ShareLink = {
      link_id: row.external_id ?? row.link_id,
      workspace_id: (workspace?.external_id as string | undefined) ?? row.workspace_id,
      target_type: row.target_type,
      target_id: (target?.external_id as string | undefined) ?? row.target_id,
      token_hash: row.token_hash,
      link_name: row.link_name ?? undefined,
      access_mode: row.access_mode,
      password_hash: row.password_hash ?? undefined,
      expires_at: row.expires_at ?? undefined,
      download_policy: row.download_policy,
      version_policy: row.version_policy,
      requires_identity: !!row.requires_identity,
      watermark_enabled: !!row.watermark_enabled,
      allow_comments: !!row.allow_comments,
      allow_approval: !!row.allow_approval,
      allow_forwarding: !!row.allow_forwarding,
      created_by: undefined,
      revoked_at: row.revoked_at ?? undefined,
      created_at: row.created_at,
    };
    this.snapshot.shareLinks = [...this.snapshot.shareLinks, link];
    return true;
  }

  createFirstListenShare(auth: AuthContext, params: {
    song_id: string;
    version_id?: string;
    decision_request_type?: DecisionRequestType;
    context_note?: string;
    recipient_email?: string;
    recipient_phone?: string;
    display_name?: string;
    expires_at?: string;
    voice_preface_storage_path?: string;
  }) {
    const context = this.songContext(params.song_id, params.version_id);
    const token = makeShareToken();
    const now = new Date().toISOString();
    const session: ShareSession = {
      share_session_id: `fl-${randomUUID()}`,
      workspace_id: context.song.workspace_id,
      artist_name: context.song.artist_display_name,
      song_id: context.song.song_id,
      room_id: context.song.primary_room_id,
      version_id: context.version?.version_id,
      sender_user_id: auth.userID,
      share_type: "first_listen",
      decision_request_type: params.decision_request_type ?? "general_reaction",
      context_note: params.context_note?.trim() || undefined,
      voice_preface_storage_path: params.voice_preface_storage_path,
      token_hash: hashToken(token),
      demo_token: token,
      expires_at: params.expires_at,
      max_first_listens: 1,
      replay_grants_count: 0,
      status: "unused",
      created_at: now,
      updated_at: now,
    };
    const recipient: ShareSessionRecipient = {
      recipient_id: `flr-${randomUUID()}`,
      share_session_id: session.share_session_id,
      recipient_email: params.recipient_email?.trim().toLowerCase() || undefined,
      recipient_phone: params.recipient_phone?.trim() || undefined,
      display_name: params.display_name?.trim() || undefined,
      access_state: "unused",
      created_at: now,
      updated_at: now,
    };
    this.snapshot.shareSessions = [...this.snapshot.shareSessions, session];
    this.snapshot.shareSessionRecipients = [...this.snapshot.shareSessionRecipients, recipient];
    void (async () => {
      await persistShareSession(session);
      await persistShareSessionRecipient(recipient);
    })().catch(() => undefined);
    this.recordEvent({
      workspace_id: session.workspace_id,
      actor_user_id: auth.userID,
      event_type: "created_share_link",
      target_type: "first_listen",
      target_id: session.share_session_id,
      song_id: session.song_id,
      version_id: session.version_id,
      metadata: {
        decision_request_type: session.decision_request_type,
        expires_at: session.expires_at,
        protected_first_listen: true,
      },
    });
    return {
      session,
      recipient,
      token,
      url_path: `/listen/${token}`,
      report: this.firstListenReportSummary(session.share_session_id),
    };
  }

  getFirstListenShare(sessionID: string) {
    const session = this.snapshot.shareSessions.find((candidate) => candidate.share_session_id === sessionID);
    if (!session) throw new Error("First Listen not found");
    const context = this.songContext(session.song_id, session.version_id);
    return {
      session,
      recipients: this.snapshot.shareSessionRecipients.filter((recipient) => recipient.share_session_id === sessionID),
      decisions: this.snapshot.decisionResponses.filter((response) => response.share_session_id === sessionID),
      reactions: this.snapshot.timestampedReactions.filter((reaction) => reaction.share_session_id === sessionID),
      events: this.snapshot.listeningEvents.filter((event) => event.share_session_id === sessionID),
      report: this.firstListenReportSummary(sessionID),
      ...context,
    };
  }

  resolveFirstListen(token: string) {
    const { session, recipient } = this.resolveFirstListenAccess(token, { markOpened: true });
    const context = this.songContext(session.song_id, session.version_id);
    const sender = this.snapshot.users.find((user) => user.user_id === session.sender_user_id) ?? null;
    const canPlay = this.canRecipientPlay(recipient);
    const report = this.snapshot.listeningReports.find((candidate) => candidate.share_session_id === session.share_session_id) ?? null;
    return {
      session,
      recipient,
      sender,
      can_play: canPlay,
      can_request_replay: recipient.access_state === "completed",
      replay_granted: recipient.access_state === "replay_granted",
      report,
      ...context,
    };
  }

  assertFirstListenStream(token: string, versionID: string) {
    const { session, recipient } = this.resolveFirstListenAccess(token);
    if (!this.canRecipientPlay(recipient)) {
      throw new Error("This protected first listen has already been completed. Request a replay to listen again.");
    }
    const context = this.songContext(session.song_id, session.version_id);
    if (context.version?.version_id !== versionID) throw new Error("Version is not available through this First Listen");
    return context.asset;
  }

  recordFirstListenEvent(token: string, params: {
    event_type: ListeningEventType;
    playback_position_ms?: number;
    percent_complete?: number;
    metadata?: Record<string, unknown>;
    intensity?: number;
    note_text?: string;
  }) {
    const { session, recipient } = this.resolveFirstListenAccess(token);
    const context = this.songContext(session.song_id, session.version_id);
    const now = new Date().toISOString();
    const position = Math.max(0, Math.round(params.playback_position_ms ?? recipient.last_position_ms ?? 0));
    const percent = params.percent_complete == null ? undefined : Math.max(0, Math.min(100, Number(params.percent_complete)));

    if ((params.event_type === "started" || params.event_type === "resumed") && !this.canRecipientPlay(recipient)) {
      throw new Error("Replay required before another listen can start.");
    }

    let updatedRecipient: ShareSessionRecipient | undefined;
    this.snapshot.shareSessionRecipients = this.snapshot.shareSessionRecipients.map((candidate) => {
      if (candidate.recipient_id !== recipient.recipient_id) return candidate;
      const completed = params.event_type === "completed" && (percent == null || percent >= 90);
      const nextState: ShareAccessState =
        completed ? "completed"
        : params.event_type === "started" || params.event_type === "resumed" || params.event_type === "paused" ? "started"
        : candidate.access_state;
      updatedRecipient = {
        ...candidate,
        access_state: nextState,
        started_at: (params.event_type === "started" || params.event_type === "resumed") ? (candidate.started_at ?? now) : candidate.started_at,
        completed_at: completed ? now : candidate.completed_at,
        last_position_ms: position,
        updated_at: now,
      };
      return updatedRecipient;
    });
    if (updatedRecipient) void persistShareSessionRecipient(updatedRecipient).catch(() => undefined);

    if (params.event_type === "started" && session.status === "unused") {
      this.patchShareSession(session.share_session_id, { status: "started" });
    }
    if (params.event_type === "completed" && (percent == null || percent >= 90)) {
      this.patchShareSession(session.share_session_id, { status: "completed" });
    }

    const event = this.addListeningEvent({
      share_session_id: session.share_session_id,
      recipient_id: recipient.recipient_id,
      song_id: session.song_id,
      version_id: context.version?.version_id,
      event_type: params.event_type,
      playback_position_ms: position,
      percent_complete: percent,
      metadata: params.metadata ?? {},
    });

    if (params.event_type === "pulse" || params.event_type === "timestamp_marker") {
      this.addTimestampedReaction({
        share_session_id: session.share_session_id,
        recipient_id: recipient.recipient_id,
        song_id: session.song_id,
        version_id: context.version?.version_id,
        playback_position_ms: position,
        reaction_type: params.event_type === "pulse" ? "pulse" : "marker",
        intensity: params.event_type === "pulse" ? Math.max(1, Math.min(10, params.intensity ?? 1)) : undefined,
        note_text: params.note_text,
      });
    }

    if (params.event_type === "completed" && (percent == null || percent >= 90)) {
      this.ensureFirstListenReport(session.share_session_id);
    }

    return {
      event,
      report: this.firstListenReportSummary(session.share_session_id),
      recipient: this.snapshot.shareSessionRecipients.find((candidate) => candidate.recipient_id === recipient.recipient_id),
    };
  }

  submitFirstListenDecision(token: string, params: {
    response_value: DecisionResponseValue;
    text_note?: string;
    confidence?: number;
    voice_note_storage_path?: string;
  }) {
    const { session, recipient } = this.resolveFirstListenAccess(token);
    const context = this.songContext(session.song_id, session.version_id);
    const now = new Date().toISOString();
    const response: DecisionResponse = {
      decision_response_id: `dr-${randomUUID()}`,
      share_session_id: session.share_session_id,
      recipient_id: recipient.recipient_id,
      song_id: session.song_id,
      version_id: context.version?.version_id,
      decision_request_type: session.decision_request_type,
      response_value: params.response_value,
      confidence: params.confidence,
      text_note: params.text_note?.trim() || undefined,
      voice_note_storage_path: params.voice_note_storage_path,
      transcript: params.voice_note_storage_path ? "Transcript pending" : undefined,
      created_at: now,
      updated_at: now,
    };
    this.snapshot.decisionResponses = [...this.snapshot.decisionResponses, response];
    void persistDecisionResponse(response).catch(() => undefined);
    this.addListeningEvent({
      share_session_id: session.share_session_id,
      recipient_id: recipient.recipient_id,
      song_id: session.song_id,
      version_id: context.version?.version_id,
      event_type: "decision_submitted",
      playback_position_ms: recipient.last_position_ms,
      percent_complete: recipient.completed_at ? 100 : undefined,
      metadata: { response_value: response.response_value },
    });
    this.ensureFirstListenReport(session.share_session_id);
    return { response, report: this.firstListenReportSummary(session.share_session_id) };
  }

  requestFirstListenReplay(token: string) {
    const { session, recipient } = this.resolveFirstListenAccess(token, { allowCompleted: true });
    if (recipient.access_state !== "completed") throw new Error("Replay can be requested after the first listen is complete.");
    const now = new Date().toISOString();
    let updatedRecipient: ShareSessionRecipient | undefined;
    this.snapshot.shareSessionRecipients = this.snapshot.shareSessionRecipients.map((candidate) =>
      candidate.recipient_id === recipient.recipient_id
        ? (updatedRecipient = { ...candidate, access_state: "replay_requested", replay_requested_at: now, updated_at: now })
        : candidate
    );
    if (updatedRecipient) void persistShareSessionRecipient(updatedRecipient).catch(() => undefined);
    this.patchShareSession(session.share_session_id, { status: "replay_requested" });
    this.addListeningEvent({
      share_session_id: session.share_session_id,
      recipient_id: recipient.recipient_id,
      song_id: session.song_id,
      version_id: session.version_id,
      event_type: "replay_requested",
      metadata: {},
    });
    return this.getFirstListenShare(session.share_session_id);
  }

  grantFirstListenReplay(sessionID: string, recipientID: string, auth: AuthContext) {
    const session = this.snapshot.shareSessions.find((candidate) => candidate.share_session_id === sessionID);
    if (!session) throw new Error("First Listen not found");
    this.assertWorkspaceManager(session.workspace_id, auth);
    if (session.replay_grants_count >= 1) throw new Error("The MVP supports one additional replay grant.");
    const now = new Date().toISOString();
    let updatedRecipient: ShareSessionRecipient | undefined;
    this.snapshot.shareSessionRecipients = this.snapshot.shareSessionRecipients.map((recipient) => {
      if (recipient.share_session_id !== sessionID || recipient.recipient_id !== recipientID) return recipient;
      updatedRecipient = {
        ...recipient,
        access_state: "replay_granted",
        replay_granted_at: now,
        replay_requested_at: recipient.replay_requested_at,
        completed_at: undefined,
        updated_at: now,
      };
      return updatedRecipient;
    });
    if (!updatedRecipient) throw new Error("Recipient not found");
    this.patchShareSession(sessionID, {
      status: "replay_granted",
      replay_grants_count: session.replay_grants_count + 1,
    });
    void persistShareSessionRecipient(updatedRecipient).catch(() => undefined);
    return this.getFirstListenShare(sessionID);
  }

  getFirstListenReport(sessionID: string) {
    return this.ensureFirstListenReport(sessionID);
  }

  createListeningRoom(auth: AuthContext, params: {
    song_id: string;
    version_id?: string;
    room_type?: ListeningRoomType;
    title?: string;
    context_note?: string;
    decision_request_type?: DecisionRequestType;
    scheduled_start_at?: string;
    retention_policy?: ListeningRoomRetentionPolicy;
  }) {
    const context = this.songContext(params.song_id, params.version_id);
    const token = makeShareToken();
    const now = new Date().toISOString();
    const room: ListeningRoom = {
      listening_room_id: `lr-${randomUUID()}`,
      workspace_id: context.song.workspace_id,
      host_user_id: auth.userID,
      artist_name: context.song.artist_display_name,
      room_id: context.song.primary_room_id,
      room_type: params.room_type ?? "first_listen_room",
      title: params.title?.trim() || `${context.song.title} · Listening Room`,
      context_note: params.context_note?.trim() || undefined,
      decision_request_type: params.decision_request_type ?? "general_reaction",
      scheduled_start_at: params.scheduled_start_at,
      lifecycle_state: params.scheduled_start_at ? "scheduled" : "draft",
      retention_policy: params.retention_policy ?? "save_to_project",
      token_hash: hashToken(token),
      demo_token: token,
      created_at: now,
      updated_at: now,
    };
    const track: ListeningRoomTrack = {
      listening_room_track_id: `lrt-${randomUUID()}`,
      listening_room_id: room.listening_room_id,
      song_id: context.song.song_id,
      version_id: context.version?.version_id,
      sort_order: 0,
      created_at: now,
    };
    const host: ListeningRoomParticipant = {
      participant_id: `lrp-${randomUUID()}`,
      listening_room_id: room.listening_room_id,
      user_id: auth.userID,
      display_name: this.snapshot.users.find((user) => user.user_id === auth.userID)?.display_name ?? "Host",
      role_in_room: "host",
      joined_at: now,
      created_at: now,
      updated_at: now,
    };
    this.snapshot.listeningRooms = [...this.snapshot.listeningRooms, room];
    this.snapshot.listeningRoomTracks = [...this.snapshot.listeningRoomTracks, track];
    this.snapshot.listeningRoomParticipants = [...this.snapshot.listeningRoomParticipants, host];
    const state: ListeningRoomState = {
      listening_room_id: room.listening_room_id,
      current_track_id: context.song.song_id,
      current_version_id: context.version?.version_id,
      playback_state: "lobby",
      host_position_ms: 0,
      updated_at: now,
    };
    this.snapshot.listeningRoomStates = [...this.snapshot.listeningRoomStates, state];
    void persistListeningRoomBundle(room, track, host, state).catch(() => undefined);
    return {
      room,
      tracks: [track],
      host,
      token,
      url_path: `/room/${token}`,
      report: this.roomReportSummary(room.listening_room_id),
    };
  }

  getListeningRoom(roomID: string) {
    const room = this.snapshot.listeningRooms.find((candidate) => candidate.listening_room_id === roomID);
    if (!room) throw new Error("Listening Room not found");
    return this.listeningRoomPayload(room);
  }

  resolveListeningRoom(token: string) {
    const room = this.resolveListeningRoomByToken(token);
    return this.listeningRoomPayload(room);
  }

  joinListeningRoom(token: string, params: { display_name?: string; email?: string; phone?: string; participant_id?: string }) {
    const room = this.resolveListeningRoomByToken(token);
    const now = new Date().toISOString();
    const existing = params.participant_id
      ? this.snapshot.listeningRoomParticipants.find((participant) => participant.participant_id === params.participant_id && participant.listening_room_id === room.listening_room_id)
      : this.snapshot.listeningRoomParticipants.find((participant) =>
          participant.listening_room_id === room.listening_room_id
          && participant.role_in_room === "listener"
          && !!params.email
          && participant.recipient_email?.toLowerCase() === params.email.toLowerCase()
        );
    if (existing) {
      const updated = { ...existing, joined_at: existing.joined_at ?? now, updated_at: now };
      this.snapshot.listeningRoomParticipants = this.snapshot.listeningRoomParticipants.map((participant) =>
        participant.participant_id === existing.participant_id ? updated : participant
      );
      void persistListeningRoomParticipant(updated).catch(() => undefined);
      return { participant: updated, room: this.listeningRoomPayload(room) };
    }
    const participant: ListeningRoomParticipant = {
      participant_id: `lrp-${randomUUID()}`,
      listening_room_id: room.listening_room_id,
      recipient_email: params.email?.trim().toLowerCase() || undefined,
      recipient_phone: params.phone?.trim() || undefined,
      display_name: params.display_name?.trim() || params.email?.trim() || "Listener",
      role_in_room: "listener",
      joined_at: now,
      created_at: now,
      updated_at: now,
    };
    this.snapshot.listeningRoomParticipants = [...this.snapshot.listeningRoomParticipants, participant];
    void persistListeningRoomParticipant(participant).catch(() => undefined);
    this.addListeningEvent({
      listening_room_id: room.listening_room_id,
      participant_id: participant.participant_id,
      song_id: this.primaryRoomTrack(room.listening_room_id).song_id,
      version_id: this.primaryRoomTrack(room.listening_room_id).version_id,
      event_type: "joined",
      metadata: {},
    });
    return { participant, room: this.listeningRoomPayload(room) };
  }

  updateListeningRoomState(roomID: string, auth: AuthContext, params: {
    playback_state: ListeningRoomPlaybackState;
    host_position_ms?: number;
    current_track_id?: string;
    current_version_id?: string;
  }) {
    const room = this.snapshot.listeningRooms.find((candidate) => candidate.listening_room_id === roomID);
    if (!room) throw new Error("Listening Room not found");
    this.assertWorkspaceManager(room.workspace_id, auth);
    const now = new Date().toISOString();
    const started = params.playback_state === "playing" && !room.started_at;
    let updatedRoom: ListeningRoom | undefined;
    this.snapshot.listeningRooms = this.snapshot.listeningRooms.map((candidate) =>
      candidate.listening_room_id === roomID
        ? (updatedRoom = {
            ...candidate,
            lifecycle_state: params.playback_state === "ended" ? "ended" : params.playback_state === "playing" || params.playback_state === "paused" ? "live" : candidate.lifecycle_state,
            started_at: started ? now : candidate.started_at,
            ended_at: params.playback_state === "ended" ? now : candidate.ended_at,
            updated_at: now,
          })
        : candidate
    );
    const track = this.primaryRoomTrack(roomID);
    const nextState: ListeningRoomState = {
      listening_room_id: roomID,
      current_track_id: params.current_track_id ?? track.song_id,
      current_version_id: params.current_version_id ?? track.version_id,
      playback_state: params.playback_state,
      host_position_ms: Math.max(0, Math.round(params.host_position_ms ?? 0)),
      host_started_at_server_time: params.playback_state === "playing" ? now : undefined,
      updated_at: now,
    };
    const hasState = this.snapshot.listeningRoomStates.some((state) => state.listening_room_id === roomID);
    this.snapshot.listeningRoomStates = hasState
      ? this.snapshot.listeningRoomStates.map((state) => state.listening_room_id === roomID ? { ...state, ...nextState } : state)
      : [...this.snapshot.listeningRoomStates, nextState];
    if (updatedRoom) void persistListeningRoom(updatedRoom).catch(() => undefined);
    void persistListeningRoomState(nextState).catch(() => undefined);
    if (params.playback_state === "playing" && started) {
      this.addListeningEvent({
        listening_room_id: roomID,
        participant_id: this.hostParticipant(roomID)?.participant_id,
        song_id: track.song_id,
        version_id: track.version_id,
        event_type: "room_started",
        metadata: {},
      });
    }
    return this.listeningRoomPayload(this.snapshot.listeningRooms.find((candidate) => candidate.listening_room_id === roomID)!);
  }

  recordRoomEvent(token: string, params: {
    participant_id?: string;
    event_type: ListeningEventType;
    playback_position_ms?: number;
    percent_complete?: number;
    intensity?: number;
    note_text?: string;
    reaction_type?: TimestampedReactionType;
    metadata?: Record<string, unknown>;
  }) {
    const room = this.resolveListeningRoomByToken(token);
    const track = this.primaryRoomTrack(room.listening_room_id);
    const participant = this.resolveRoomParticipant(room.listening_room_id, params.participant_id);
    const position = Math.max(0, Math.round(params.playback_position_ms ?? 0));
    const event = this.addListeningEvent({
      listening_room_id: room.listening_room_id,
      participant_id: participant?.participant_id,
      song_id: track.song_id,
      version_id: track.version_id,
      event_type: params.event_type,
      playback_position_ms: position,
      percent_complete: params.percent_complete,
      metadata: params.metadata ?? {},
    });
    if (params.event_type === "pulse" || params.event_type === "timestamp_marker" || params.reaction_type) {
      this.addTimestampedReaction({
        listening_room_id: room.listening_room_id,
        participant_id: participant?.participant_id,
        song_id: track.song_id,
        version_id: track.version_id,
        playback_position_ms: position,
        reaction_type: params.reaction_type ?? (params.event_type === "pulse" ? "pulse" : "marker"),
        intensity: params.event_type === "pulse" ? Math.max(1, Math.min(10, params.intensity ?? 1)) : params.intensity,
        note_text: params.note_text,
      });
    }
    if (params.event_type === "completed" && participant) {
      const now = new Date().toISOString();
      let updatedParticipant: ListeningRoomParticipant | undefined;
      this.snapshot.listeningRoomParticipants = this.snapshot.listeningRoomParticipants.map((candidate) =>
        candidate.participant_id === participant.participant_id
          ? (updatedParticipant = { ...candidate, completed_at: candidate.completed_at ?? now, updated_at: now })
          : candidate
      );
      if (updatedParticipant) void persistListeningRoomParticipant(updatedParticipant).catch(() => undefined);
    }
    return { event, room: this.listeningRoomPayload(room) };
  }

  submitRoomFirstTake(token: string, params: {
    participant_id?: string;
    response_value: DecisionResponseValue;
    text_note?: string;
  }) {
    const room = this.resolveListeningRoomByToken(token);
    const participant = this.resolveRoomParticipant(room.listening_room_id, params.participant_id);
    if (!participant) throw new Error("Join the room before submitting a First Take.");
    const track = this.primaryRoomTrack(room.listening_room_id);
    const now = new Date().toISOString();
    const response: DecisionResponse = {
      decision_response_id: `dr-${randomUUID()}`,
      listening_room_id: room.listening_room_id,
      participant_id: participant.participant_id,
      song_id: track.song_id,
      version_id: track.version_id,
      decision_request_type: room.decision_request_type ?? "general_reaction",
      response_value: params.response_value,
      text_note: params.text_note?.trim() || undefined,
      created_at: now,
      updated_at: now,
    };
    this.snapshot.decisionResponses = [...this.snapshot.decisionResponses, response];
    void persistDecisionResponse(response).catch(() => undefined);
    let updatedParticipant: ListeningRoomParticipant | undefined;
    this.snapshot.listeningRoomParticipants = this.snapshot.listeningRoomParticipants.map((candidate) =>
      candidate.participant_id === participant.participant_id
        ? (updatedParticipant = { ...candidate, first_take_submitted_at: now, updated_at: now })
        : candidate
    );
    if (updatedParticipant) void persistListeningRoomParticipant(updatedParticipant).catch(() => undefined);
    this.addListeningEvent({
      listening_room_id: room.listening_room_id,
      participant_id: participant.participant_id,
      song_id: track.song_id,
      version_id: track.version_id,
      event_type: "decision_submitted",
      metadata: { response_value: response.response_value },
    });
    return { response, room: this.listeningRoomPayload(room) };
  }

  endListeningRoom(roomID: string, auth: AuthContext) {
    const room = this.snapshot.listeningRooms.find((candidate) => candidate.listening_room_id === roomID);
    if (!room) throw new Error("Listening Room not found");
    this.assertWorkspaceManager(room.workspace_id, auth);
    this.updateListeningRoomState(roomID, auth, { playback_state: "ended", host_position_ms: this.roomState(roomID)?.host_position_ms ?? 0 });
    const track = this.primaryRoomTrack(roomID);
    this.addListeningEvent({
      listening_room_id: roomID,
      participant_id: this.hostParticipant(roomID)?.participant_id,
      song_id: track.song_id,
      version_id: track.version_id,
      event_type: "room_ended",
      metadata: {},
    });
    return this.ensureListeningRoomReport(roomID);
  }

  getListeningRoomReport(roomID: string) {
    return this.ensureListeningRoomReport(roomID);
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
    // Pick a real workspace member to show as "shared by" — the first member
    // who isn't the current user. Falls back to "Workspace" when solo.
    const workspaceID = this.snapshot.workspaces[0]?.workspace_id;
    const sharer = workspaceID
      ? this.snapshot.users.find(
          (u) =>
            u.user_id !== userID &&
            this.snapshot.memberships.some(
              (m) => m.workspace_id === workspaceID && m.user_id === u.user_id,
            ),
        )
      : undefined;
    const sharedBy = sharer?.display_name ?? "Workspace";

    return this.snapshot.songs.map((song) => {
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
        shared_by: sharedBy,
        new_since_last_listen: !listened,
        last_listened_at: listened
          ? this.snapshot.activityEvents
              .filter((e) => e.actor_user_id === userID && e.event_type === "played_track" && e.version_id === currentVersion.version_id)
              .sort((a, b) => b.created_at.localeCompare(a.created_at))[0]?.created_at
          : undefined,
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

  // ===== Access requests ("Like Playback? Request access") ================

  /**
   * PUBLIC entry point — a share-link recipient (no account) asks the
   * workspace owner for access. Resolves the token to its link/workspace and
   * captures source context (what they were listening to). Light abuse guard:
   * one pending request per email per workspace.
   */
  createAccessRequest(token: string, params: { name?: string; email?: string }): AccessRequest {
    const name = params.name?.trim();
    const email = params.email?.trim().toLowerCase();
    if (!name) throw new Error("Name is required");
    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Error("A valid email is required");
    const link = this.snapshot.shareLinks.find(
      (candidate) => candidate.demo_token === token || candidate.token_hash === hashToken(token),
    );
    if (!link) throw new Error("Share link not found");
    if (link.revoked_at) throw new Error("This link has been revoked");
    const duplicate = this.snapshot.accessRequests.find(
      (request) =>
        request.workspace_id === link.workspace_id
        && request.status === "pending"
        && request.email === email,
    );
    if (duplicate) throw new Error("A request for this email is already pending.");
    const sourceTitle =
      link.target_type === "song"
        ? this.snapshot.songs.find((song) => song.song_id === link.target_id)?.title
        : link.target_type === "playlist"
          ? this.snapshot.playlists.find((playlist) => playlist.playlist_id === link.target_id)?.title
          : this.snapshot.rooms.find((room) => room.room_id === link.target_id)?.title;
    const request: AccessRequest = {
      request_id: `areq-${randomUUID()}`,
      workspace_id: link.workspace_id,
      name,
      email,
      source_token: token,
      source_song_title: sourceTitle,
      status: "pending",
      created_at: new Date().toISOString(),
    };
    this.snapshot.accessRequests = [...this.snapshot.accessRequests, request];
    return request;
  }

  /** Pending requests for the owner's Inbox, newest first. */
  listAccessRequests(workspaceID: string): AccessRequest[] {
    return this.snapshot.accessRequests
      .filter((request) => request.workspace_id === workspaceID && request.status === "pending")
      .sort((a, b) => b.created_at.localeCompare(a.created_at));
  }

  resolveAccessRequest(requestID: string, action: "approve" | "dismiss"): AccessRequest {
    const existing = this.snapshot.accessRequests.find((request) => request.request_id === requestID);
    if (!existing) throw new Error("Access request not found");
    const updated: AccessRequest = {
      ...existing,
      status: action === "approve" ? "approved" : "dismissed",
    };
    this.snapshot.accessRequests = this.snapshot.accessRequests.map((request) =>
      request.request_id === requestID ? updated : request,
    );
    return updated;
  }

  // ===== Server-side pins (per user, per workspace) =======================

  getPins(auth: AuthContext, workspaceID: string): string[] {
    return (
      this.snapshot.userPins.find(
        (entry) => entry.user_id === auth.userID && entry.workspace_id === workspaceID,
      )?.pins ?? []
    );
  }

  /**
   * Replace the caller's pin list (last-write-wins). Entries are "type:id"
   * strings matching the iOS PinRef encoding; capped at 50 and deduped
   * preserving order.
   */
  setPins(auth: AuthContext, workspaceID: string, pins: unknown): string[] {
    if (!Array.isArray(pins) || !pins.every((pin): pin is string => typeof pin === "string")) {
      throw new Error("pins must be an array of strings");
    }
    if (pins.length > 50) throw new Error("A maximum of 50 pins is supported");
    const invalid = pins.find((pin) => !/^(song|playlist|room):/.test(pin));
    if (invalid !== undefined) {
      throw new Error(`Invalid pin "${invalid}" — entries must look like "song:<id>", "playlist:<id>", or "room:<id>"`);
    }
    const deduped = [...new Set(pins)];
    const now = new Date().toISOString();
    const next: UserPins = { user_id: auth.userID, workspace_id: workspaceID, pins: deduped, updated_at: now };
    const exists = this.snapshot.userPins.some(
      (entry) => entry.user_id === auth.userID && entry.workspace_id === workspaceID,
    );
    this.snapshot.userPins = exists
      ? this.snapshot.userPins.map((entry) =>
          entry.user_id === auth.userID && entry.workspace_id === workspaceID ? next : entry,
        )
      : [...this.snapshot.userPins, next];
    return deduped;
  }

  private songContext(songID: string, versionID?: string) {
    const song = this.snapshot.songs.find((candidate) => candidate.song_id === songID);
    if (!song) throw new Error("Song not found");
    const versions = this.snapshot.versions
      .filter((version) => version.song_id === song.song_id)
      .sort((a, b) => a.version_number - b.version_number);
    const version =
      (versionID ? versions.find((candidate) => candidate.version_id === versionID) : undefined)
      ?? versions.find((candidate) => candidate.version_id === song.current_version_id)
      ?? versions.at(-1);
    const asset = version
      ? this.snapshot.assets.find((candidate) => candidate.asset_id === version.file_asset_id) ?? null
      : null;
    const room = song.primary_room_id
      ? this.snapshot.rooms.find((candidate) => candidate.room_id === song.primary_room_id) ?? null
      : null;
    if (!version) throw new Error("Song has no playable version");
    return { song, version, asset, room };
  }

  private assertWorkspaceManager(workspaceID: string, auth: AuthContext) {
    const membership = this.snapshot.memberships.find(
      (candidate) => candidate.workspace_id === workspaceID && candidate.user_id === auth.userID,
    );
    if (!membership || !["owner", "admin", "manager", "producer", "engineer"].includes(membership.role)) {
      throw new Error("You do not have permission to manage this listening flow.");
    }
  }

  private patchShareSession(sessionID: string, patch: Partial<ShareSession>) {
    const now = new Date().toISOString();
    let updatedSession: ShareSession | undefined;
    this.snapshot.shareSessions = this.snapshot.shareSessions.map((session) =>
      session.share_session_id === sessionID
        ? (updatedSession = { ...session, ...patch, share_session_id: session.share_session_id, token_hash: session.token_hash, demo_token: session.demo_token, updated_at: now })
        : session
    );
    if (updatedSession) void persistShareSession(updatedSession).catch(() => undefined);
  }

  private resolveFirstListenAccess(token: string, opts: { markOpened?: boolean; allowCompleted?: boolean } = {}) {
    const matchingHash = hashToken(token);
    const session = this.snapshot.shareSessions.find(
      (candidate) => candidate.demo_token === token || candidate.token_hash === matchingHash,
    );
    if (!session) throw new Error("First Listen link is invalid.");
    const now = new Date().toISOString();
    const expired = !!session.expires_at && new Date(session.expires_at) < new Date();
    const recipients = this.snapshot.shareSessionRecipients.filter(
      (recipient) => recipient.share_session_id === session.share_session_id,
    );
    const recipient = recipients[0];
    if (!recipient) throw new Error("First Listen recipient not found.");
    if (session.status === "revoked" || recipient.access_state === "revoked") {
      throw new Error("This First Listen has been revoked.");
    }
    if (expired) {
      this.patchShareSession(session.share_session_id, { status: "expired" });
      let expiredRecipient: ShareSessionRecipient | undefined;
      this.snapshot.shareSessionRecipients = this.snapshot.shareSessionRecipients.map((candidate) =>
        candidate.recipient_id === recipient.recipient_id
          ? (expiredRecipient = { ...candidate, access_state: "expired", expired_at: candidate.expired_at ?? now, updated_at: now })
          : candidate
      );
      if (expiredRecipient) void persistShareSessionRecipient(expiredRecipient).catch(() => undefined);
      throw new Error("This First Listen has expired.");
    }
    if (!opts.allowCompleted && recipient.access_state === "completed") {
      return { session, recipient };
    }
    if (opts.markOpened && recipient.access_state === "unused") {
      const opened: ShareSessionRecipient = {
        ...recipient,
        access_state: "opened",
        opened_at: recipient.opened_at ?? now,
        updated_at: now,
      };
      this.snapshot.shareSessionRecipients = this.snapshot.shareSessionRecipients.map((candidate) =>
        candidate.recipient_id === recipient.recipient_id ? opened : candidate
      );
      void persistShareSessionRecipient(opened).catch(() => undefined);
      this.patchShareSession(session.share_session_id, { status: "opened" });
      this.addListeningEvent({
        share_session_id: session.share_session_id,
        recipient_id: recipient.recipient_id,
        song_id: session.song_id,
        version_id: session.version_id,
        event_type: "opened",
        metadata: {},
      });
      return { session: this.snapshot.shareSessions.find((candidate) => candidate.share_session_id === session.share_session_id) ?? session, recipient: opened };
    }
    return { session, recipient };
  }

  private canRecipientPlay(recipient: ShareSessionRecipient) {
    return ["unused", "opened", "started", "replay_granted"].includes(recipient.access_state);
  }

  private addListeningEvent(params: Omit<ListeningEvent, "listening_event_id" | "created_at">) {
    const event: ListeningEvent = {
      ...params,
      listening_event_id: `le-${randomUUID()}`,
      metadata: params.metadata ?? {},
      created_at: new Date().toISOString(),
    };
    this.snapshot.listeningEvents = [...this.snapshot.listeningEvents, event];
    void persistListeningEvent(event).catch(() => undefined);
    return event;
  }

  private addTimestampedReaction(params: Omit<TimestampedReaction, "timestamped_reaction_id" | "created_at">) {
    const reaction: TimestampedReaction = {
      ...params,
      timestamped_reaction_id: `tr-${randomUUID()}`,
      created_at: new Date().toISOString(),
    };
    this.snapshot.timestampedReactions = [...this.snapshot.timestampedReactions, reaction];
    void persistTimestampedReaction(reaction).catch(() => undefined);
    return reaction;
  }

  private formatDecisionSummary(counts: Record<string, number>): string {
    const parts = Object.entries(counts).map(([value, count]) => `${count} ${value.replace(/_/g, " ")}`);
    return parts.length > 0 ? parts.join(", ") : "none";
  }

  private decisionCounts(responses: DecisionResponse[]) {
    return responses.reduce<Record<string, number>>((acc, response) => {
      acc[response.response_value] = (acc[response.response_value] ?? 0) + 1;
      return acc;
    }, {});
  }

  private topPulseMoments(reactions: TimestampedReaction[]) {
    const buckets = new Map<number, { position_ms: number; intensity: number; count: number }>();
    for (const reaction of reactions) {
      if (reaction.reaction_type !== "pulse") continue;
      const bucket = Math.round(reaction.playback_position_ms / 15000) * 15000;
      const existing = buckets.get(bucket) ?? { position_ms: bucket, intensity: 0, count: 0 };
      existing.intensity += reaction.intensity ?? 1;
      existing.count += 1;
      buckets.set(bucket, existing);
    }
    return [...buckets.values()]
      .sort((a, b) => b.intensity - a.intensity)
      .slice(0, 5);
  }

  private firstListenReportSummary(sessionID: string) {
    const session = this.snapshot.shareSessions.find((candidate) => candidate.share_session_id === sessionID);
    if (!session) throw new Error("First Listen not found");
    const recipients = this.snapshot.shareSessionRecipients.filter((recipient) => recipient.share_session_id === sessionID);
    const events = this.snapshot.listeningEvents.filter((event) => event.share_session_id === sessionID);
    const decisions = this.snapshot.decisionResponses.filter((response) => response.share_session_id === sessionID);
    const reactions = this.snapshot.timestampedReactions.filter((reaction) => reaction.share_session_id === sessionID);
    const context = this.songContext(session.song_id, session.version_id);
    const opened = recipients.filter((recipient) => !!recipient.opened_at || recipient.access_state !== "unused").length;
    const started = recipients.filter((recipient) => !!recipient.started_at || ["started", "completed", "replay_requested", "replay_granted"].includes(recipient.access_state)).length;
    const completed = recipients.filter((recipient) => !!recipient.completed_at || recipient.access_state === "completed" || recipient.access_state === "replay_requested").length;
    return {
      report_type: "first_listen",
      share_session_id: sessionID,
      artist_name: context.song.artist_display_name ?? session.artist_name ?? null,
      track_title: context.song.title,
      project_name: context.song.project_name ?? context.room?.title ?? null,
      version_id: context.version.version_id,
      version_label: context.version.version_label,
      total_recipients: recipients.length,
      opened_count: opened,
      started_count: started,
      completed_count: completed,
      completion_rate: recipients.length === 0 ? 0 : Math.round((completed / recipients.length) * 100),
      decision_request_type: session.decision_request_type,
      decision_counts: this.decisionCounts(decisions),
      replay_requests: recipients.filter((recipient) => !!recipient.replay_requested_at || recipient.access_state === "replay_requested").length,
      top_pulse_moments: this.topPulseMoments(reactions),
      timestamp_markers: reactions.filter((reaction) => reaction.reaction_type === "marker"),
      notes: decisions
        .filter((response) => response.text_note || response.voice_note_storage_path)
        .map((response) => ({
          response_id: response.decision_response_id,
          response_value: response.response_value,
          text_note: response.text_note,
          voice_note_storage_path: response.voice_note_storage_path,
          transcript: response.transcript ?? (response.voice_note_storage_path ? "Transcript pending" : undefined),
        })),
      last_event_at: events.at(-1)?.created_at ?? session.updated_at,
      version_heard: {
        song_id: session.song_id,
        version_id: context.version.version_id,
        version_label: context.version.version_label,
      },
    };
  }

  private ensureFirstListenReport(sessionID: string) {
    const session = this.snapshot.shareSessions.find((candidate) => candidate.share_session_id === sessionID);
    if (!session) throw new Error("First Listen not found");
    const summary = this.firstListenReportSummary(sessionID);
    const now = new Date().toISOString();
    const existing = this.snapshot.listeningReports.find((report) => report.share_session_id === sessionID);
    if (existing) {
      const updated: ListeningReport = { ...existing, summary_json: summary, updated_at: now };
      this.snapshot.listeningReports = this.snapshot.listeningReports.map((report) =>
        report.listening_report_id === existing.listening_report_id ? updated : report
      );
      void persistListeningReport(updated).catch(() => undefined);
      return updated;
    }
    const report: ListeningReport = {
      listening_report_id: `lrep-${randomUUID()}`,
      report_type: "first_listen",
      share_session_id: sessionID,
      workspace_id: session.workspace_id,
      artist_name: session.artist_name,
      song_id: session.song_id,
      room_id: session.room_id,
      version_id: session.version_id,
      summary_json: summary,
      created_by: session.sender_user_id,
      visibility: "private",
      created_at: now,
      updated_at: now,
    };
    this.snapshot.listeningReports = [...this.snapshot.listeningReports, report];
    void persistListeningReport(report).catch(() => undefined);
    const context = this.songContext(session.song_id, session.version_id);
    this.createNote({ userID: session.sender_user_id }, {
      song_id: session.song_id,
      anchor_version_id: context.version.version_id,
      body: `First Listen Report: ${summary.completed_count}/${summary.total_recipients} completed · decisions ${this.formatDecisionSummary(summary.decision_counts)}`,
      scope: "song",
      visibility: "internal",
    });
    return report;
  }

  private resolveListeningRoomByToken(token: string) {
    const matchingHash = hashToken(token);
    const room = this.snapshot.listeningRooms.find(
      (candidate) => candidate.demo_token === token || candidate.token_hash === matchingHash,
    );
    if (!room) throw new Error("Listening Room link is invalid.");
    if (room.lifecycle_state === "canceled" || room.lifecycle_state === "expired") {
      throw new Error("This Listening Room is no longer available.");
    }
    return room;
  }

  private primaryRoomTrack(roomID: string) {
    const track = this.snapshot.listeningRoomTracks
      .filter((candidate) => candidate.listening_room_id === roomID)
      .sort((a, b) => a.sort_order - b.sort_order)[0];
    if (!track) throw new Error("Listening Room has no tracks.");
    return track;
  }

  private roomState(roomID: string) {
    return this.snapshot.listeningRoomStates.find((state) => state.listening_room_id === roomID);
  }

  private hostParticipant(roomID: string) {
    return this.snapshot.listeningRoomParticipants.find(
      (participant) => participant.listening_room_id === roomID && participant.role_in_room === "host",
    );
  }

  private resolveRoomParticipant(roomID: string, participantID?: string) {
    if (!participantID) return undefined;
    return this.snapshot.listeningRoomParticipants.find(
      (participant) => participant.listening_room_id === roomID && participant.participant_id === participantID,
    );
  }

  private listeningRoomPayload(room: ListeningRoom) {
    const tracks = this.snapshot.listeningRoomTracks
      .filter((track) => track.listening_room_id === room.listening_room_id)
      .sort((a, b) => a.sort_order - b.sort_order);
    const songs = tracks
      .map((track) => this.snapshot.songs.find((song) => song.song_id === track.song_id))
      .filter((song): song is NonNullable<typeof song> => !!song);
    const versions = tracks
      .map((track) => this.snapshot.versions.find((version) => version.version_id === track.version_id))
      .filter((version): version is NonNullable<typeof version> => !!version);
    const assets = versions
      .map((version) => this.snapshot.assets.find((asset) => asset.asset_id === version.file_asset_id))
      .filter((asset): asset is NonNullable<typeof asset> => !!asset);
    const participants = this.snapshot.listeningRoomParticipants.filter((participant) => participant.listening_room_id === room.listening_room_id);
    const reactions = this.snapshot.timestampedReactions.filter((reaction) => reaction.listening_room_id === room.listening_room_id);
    const decisions = this.snapshot.decisionResponses.filter((response) => response.listening_room_id === room.listening_room_id);
    const events = this.snapshot.listeningEvents.filter((event) => event.listening_room_id === room.listening_room_id);
    const report = this.snapshot.listeningReports.find((candidate) => candidate.listening_room_id === room.listening_room_id) ?? null;
    return {
      room,
      tracks,
      songs,
      versions,
      assets,
      participants,
      state: this.roomState(room.listening_room_id) ?? {
        listening_room_id: room.listening_room_id,
        current_track_id: tracks[0]?.song_id,
        current_version_id: tracks[0]?.version_id,
        playback_state: "lobby",
        host_position_ms: 0,
        updated_at: room.updated_at,
      },
      reactions,
      decisions,
      events,
      report,
      summary: this.roomReportSummary(room.listening_room_id),
      host: this.snapshot.users.find((user) => user.user_id === room.host_user_id) ?? null,
      project: room.room_id ? this.snapshot.rooms.find((project) => project.room_id === room.room_id) ?? null : null,
    };
  }

  private roomReportSummary(roomID: string) {
    const room = this.snapshot.listeningRooms.find((candidate) => candidate.listening_room_id === roomID);
    if (!room) throw new Error("Listening Room not found");
    const participants = this.snapshot.listeningRoomParticipants.filter((participant) => participant.listening_room_id === roomID);
    const reactions = this.snapshot.timestampedReactions.filter((reaction) => reaction.listening_room_id === roomID);
    const decisions = this.snapshot.decisionResponses.filter((response) => response.listening_room_id === roomID);
    const track = this.primaryRoomTrack(roomID);
    const context = this.songContext(track.song_id, track.version_id);
    const started = room.started_at ? new Date(room.started_at).getTime() : undefined;
    const ended = room.ended_at ? new Date(room.ended_at).getTime() : undefined;
    return {
      report_type: "listening_room",
      listening_room_id: roomID,
      room_title: room.title,
      room_type: room.room_type,
      lifecycle_state: room.lifecycle_state,
      retention_policy: room.retention_policy,
      artist_name: context.song.artist_display_name ?? room.artist_name ?? null,
      project_name: context.song.project_name ?? null,
      track_title: context.song.title,
      version_heard: {
        song_id: context.song.song_id,
        version_id: context.version.version_id,
        version_label: context.version.version_label,
      },
      invited_count: participants.length,
      attended_count: participants.filter((participant) => !!participant.joined_at).length,
      completed_count: participants.filter((participant) => !!participant.completed_at).length,
      room_duration_ms: started && ended ? Math.max(0, ended - started) : 0,
      decision_counts: this.decisionCounts(decisions),
      top_pulse_moments: this.topPulseMoments(reactions),
      run_it_back_requests: reactions.filter((reaction) => reaction.reaction_type === "run_it_back"),
      timestamped_notes: reactions.filter((reaction) => ["marker", "voice_note", "text_note"].includes(reaction.reaction_type)),
      participant_first_takes: decisions.map((response) => ({
        participant_id: response.participant_id,
        response_value: response.response_value,
        text_note: response.text_note,
      })),
      next_step: "Set next step",
    };
  }

  private ensureListeningRoomReport(roomID: string) {
    const room = this.snapshot.listeningRooms.find((candidate) => candidate.listening_room_id === roomID);
    if (!room) throw new Error("Listening Room not found");
    const summary = this.roomReportSummary(roomID);
    const now = new Date().toISOString();
    const expiresAt =
      room.retention_policy === "visible_24h"
        ? new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString()
        : room.retention_policy === "disappear_after_room"
          ? now
          : undefined;
    const visibility: ListeningReportVisibility =
      room.retention_policy === "save_to_project" ? "project"
      : room.retention_policy === "visible_24h" ? "visible_24h"
      : "private";
    const existing = this.snapshot.listeningReports.find((report) => report.listening_room_id === roomID);
    if (existing) {
      const updated: ListeningReport = { ...existing, summary_json: summary, visibility, expires_at: expiresAt, updated_at: now };
      this.snapshot.listeningReports = this.snapshot.listeningReports.map((report) =>
        report.listening_report_id === existing.listening_report_id ? updated : report
      );
      void persistListeningReport(updated).catch(() => undefined);
      return updated;
    }
    const track = this.primaryRoomTrack(roomID);
    const report: ListeningReport = {
      listening_report_id: `lrep-${randomUUID()}`,
      report_type: "listening_room",
      listening_room_id: roomID,
      workspace_id: room.workspace_id,
      artist_name: room.artist_name,
      song_id: track.song_id,
      room_id: room.room_id,
      version_id: track.version_id,
      summary_json: summary,
      created_by: room.host_user_id,
      visibility,
      expires_at: expiresAt,
      created_at: now,
      updated_at: now,
    };
    this.snapshot.listeningReports = [...this.snapshot.listeningReports, report];
    void persistListeningReport(report).catch(() => undefined);
    const context = this.songContext(track.song_id, track.version_id);
    this.createNote({ userID: room.host_user_id }, {
      song_id: track.song_id,
      anchor_version_id: context.version.version_id,
      body: `Listening Room Report: ${summary.attended_count} attended · decisions ${this.formatDecisionSummary(summary.decision_counts)}${summary.top_pulse_moments.length > 0 ? ` · top moments ${summary.top_pulse_moments.length}` : ""}`,
      scope: "song",
      visibility: room.retention_policy === "save_to_project" ? "internal" : "private",
    });
    return report;
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
