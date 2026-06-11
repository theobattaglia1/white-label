export type PlanType = "free" | "creator" | "producer" | "team" | "label";
export type MemberRole =
  | "owner"
  | "admin"
  | "manager"
  | "producer"
  | "engineer"
  | "artist"
  | "anr"
  | "viewer"
  | "guest";
export type RoomType =
  | "project"
  | "producer_delivery"
  | "album_ep"
  | "anr"
  | "pitch"
  | "submission_portal"
  | "release"
  | "inner_circle"
  | "archive";
export type VersionType =
  | "demo"
  | "rough"
  | "mix"
  | "master"
  | "clean"
  | "explicit"
  | "instrumental"
  | "acapella"
  | "tv_track"
  | "sped_up"
  | "slowed"
  | "alt_arrangement"
  | "reference"
  | "stem_derived";
export type NoteScope = "song" | "version";
export type NoteStatus = "open" | "resolved";
export type NoteVisibility = "everyone" | "internal" | "private";
export type ApprovalState = "approved" | "revision_requested" | "passed";
export type LinkAccess = "public" | "password" | "identity_required";
export type VersionPolicy = "latest_only" | "full_history";
export type DownloadPolicy = "none" | "current" | "all";
export type DecisionRequestType =
  | "general_reaction"
  | "single_candidate"
  | "meeting_interest"
  | "forward_interest"
  | "sync_fit"
  | "mix_note"
  | "version_comparison";
export type DecisionResponseValue =
  | "love"
  | "hold"
  | "pass"
  | "need_context"
  | "needs_revision"
  | "would_forward";
export type ShareSessionType = "first_listen" | "standard" | "room_invite";
export type ShareAccessState =
  | "unused"
  | "opened"
  | "started"
  | "completed"
  | "expired"
  | "replay_requested"
  | "replay_granted"
  | "revoked";
export type ListeningEventType =
  | "opened"
  | "started"
  | "paused"
  | "resumed"
  | "completed"
  | "abandoned"
  | "replay_requested"
  | "decision_submitted"
  | "pulse"
  | "timestamp_marker"
  | "voice_reply_uploaded"
  | "joined"
  | "left"
  | "room_started"
  | "room_ended";
export type TimestampedReactionType = "pulse" | "marker" | "emoji" | "run_it_back" | "voice_note" | "text_note";
export type ListeningRoomType = "first_listen_room" | "revision_room" | "single_room" | "mix_notes_room";
export type ListeningRoomLifecycleState = "draft" | "scheduled" | "live" | "ended" | "archived" | "expired" | "canceled";
export type ListeningRoomRetentionPolicy = "disappear_after_room" | "visible_24h" | "save_to_project";
export type ListeningRoomPlaybackState = "lobby" | "playing" | "paused" | "ended";
export type ListeningReportType = "first_listen" | "listening_room";
export type ListeningReportVisibility = "private" | "visible_24h" | "project";
export type EventType =
  | "uploaded_version"
  | "played_track"
  | "opened_link"
  | "downloaded_file"
  | "invited_recipient"
  | "commented"
  | "mentioned_user"
  | "approved_version"
  | "requested_revision"
  | "revoked_link"
  | "changed_permission"
  | "created_share_link";

export interface Workspace {
  workspace_id: string;
  name: string;
  owner_user_id: string;
  plan_type: PlanType;
  storage_quota_bytes: number;
  used_storage_bytes: number;
  billing_status: string;
  default_link_policy?: Record<string, unknown>;
  default_naming_convention?: Record<string, unknown>;
  created_at: string;
  updated_at: string;
}

export interface User {
  user_id: string;
  email: string;
  display_name: string;
  avatar_url?: string;
  auth_provider?: string;
  two_factor_enabled: boolean;
  notification_preferences: Record<string, unknown>;
  member_number?: number;  // sequential account identity — PB-001 is the first
  created_at: string;
  updated_at: string;
}

export interface Membership {
  membership_id: string;
  workspace_id: string;
  user_id: string;
  role: MemberRole;
  created_at: string;
}

export interface Room {
  room_id: string;
  workspace_id: string;
  type: RoomType;
  title: string;
  description?: string;
  visibility: string;
  status: string;
  default_version_visibility: VersionPolicy;
  default_download_policy: DownloadPolicy;
  due_date?: string;
  created_by: string;
  created_at: string;
  updated_at: string;
}

export interface FileAsset {
  asset_id: string;
  workspace_id: string;
  original_filename: string;
  normalized_filename?: string;
  key_original: string;
  key_flac?: string;
  key_aac_256?: string;
  key_aac_128?: string;
  key_waveform_json?: string;
  key_stems_zip?: string;
  mime_type?: string;
  file_size_bytes: number;
  checksum_sha256: string;
  duration_ms: number;
  sample_rate: number;
  bit_depth: number;
  loudness_lufs: number;
  true_peak_db: number;
  virus_scan_status: "pending" | "clean" | "failed";
  transcoding_status: "pending" | "processing" | "ready" | "failed";
  waveform_peaks: number[];
  /** Web-playable URL (e.g. /seed-audio/foo.mp3 in dev, or a signed CDN URL in prod). */
  playback_url?: string;
  created_at: string;
}

export interface Song {
  song_id: string;
  workspace_id: string;
  primary_room_id?: string;
  title: string;
  artist_display_name?: string;
  project_name?: string;
  status: string;
  current_version_id?: string;
  approved_version_id?: string;
  bpm?: number;
  song_key?: string;
  explicit_flag: boolean;
  genre_tags: string[];
  mood_tags: string[];
  instrument_tags: string[];
  lyric_theme_tags: string[];
  artwork_key?: string;
  artwork_url?: string;
  release_readiness_status: "ready" | "not_ready";
  deleted_at?: string;
  created_by: string;
  created_at: string;
  updated_at: string;
}

export interface Version {
  version_id: string;
  song_id: string;
  version_number: number;
  version_label: string;
  type: VersionType;
  parent_version_id?: string;
  is_current: boolean;
  is_approved: boolean;
  uploaded_by: string;
  file_asset_id: string;
  created_at: string;
}

export interface Note {
  note_id: string;
  song_id: string;
  anchor_version_id: string;
  room_id?: string;
  author_user_id?: string;
  author_guest_label?: string;
  body: string;
  voice_asset_id?: string;
  scope: NoteScope;
  visibility: NoteVisibility;
  timestamp_start_ms?: number;
  timestamp_end_ms?: number;
  timestamp_uncertain: boolean;
  assigned_to_user_id?: string;
  assigned_to_role?: MemberRole;
  priority: "low" | "normal" | "high";
  status: NoteStatus;
  resolved_by?: string;
  resolved_at?: string;
  resolved_on_version_id?: string;
  created_at: string;
  updated_at: string;
}

export interface VisibleNote extends Note {
  anchor_version_label: string;
  display_version_label: string;
  is_carried: boolean;
  is_collapsed: boolean;
  approximate_timestamp: boolean;
}

export interface Mention {
  mention_id: string;
  note_id: string;
  mentioned_user_id?: string;
  mentioned_role?: MemberRole;
  notification_status: string;
  created_at: string;
}

export interface Task {
  task_id: string;
  workspace_id: string;
  room_id?: string;
  song_id?: string;
  version_id?: string;
  source_note_id?: string;
  title: string;
  description?: string;
  assigned_to_user_id?: string;
  assigned_to_role?: MemberRole;
  due_date?: string;
  status: string;
  priority: string;
  created_by: string;
  created_at: string;
  updated_at: string;
}

export interface Approval {
  approval_id: string;
  version_id: string;
  actor_user_id?: string;
  actor_guest_label?: string;
  state: ApprovalState;
  note?: string;
  created_at: string;
}

export interface ShareLink {
  link_id: string;
  workspace_id: string;
  target_type: "song" | "room" | "playlist";
  target_id: string;
  token_hash: string;
  demo_token?: string;
  link_name?: string;
  access_mode: LinkAccess;
  password_hash?: string;
  expires_at?: string;
  download_policy: DownloadPolicy;
  version_policy: VersionPolicy;
  requires_identity: boolean;
  watermark_enabled: boolean;
  allow_comments: boolean;
  allow_approval: boolean;
  allow_forwarding: boolean;
  created_by?: string;
  revoked_at?: string;
  created_at: string;
}

export type ShareRecipientRole = "listen" | "comment" | "download";

export interface ShareRecipient {
  recipient_id: string;
  link_id: string;
  email: string;
  display_name?: string;
  role: ShareRecipientRole;
  invited_by: string;
  invited_at: string;
  last_sent_at?: string;
  accepted_at?: string;
  revoked_at?: string;
}

export interface ShareSession {
  share_session_id: string;
  workspace_id: string;
  artist_id?: string;
  artist_name?: string;
  song_id: string;
  room_id?: string;
  version_id?: string;
  sender_user_id: string;
  share_type: ShareSessionType;
  decision_request_type: DecisionRequestType;
  context_note?: string;
  voice_preface_storage_path?: string;
  token_hash: string;
  demo_token?: string;
  expires_at?: string;
  max_first_listens: number;
  replay_grants_count: number;
  status: ShareAccessState;
  created_at: string;
  updated_at: string;
}

export interface ShareSessionRecipient {
  recipient_id: string;
  share_session_id: string;
  recipient_user_id?: string;
  recipient_email?: string;
  recipient_phone?: string;
  display_name?: string;
  access_state: ShareAccessState;
  opened_at?: string;
  started_at?: string;
  completed_at?: string;
  expired_at?: string;
  replay_requested_at?: string;
  replay_granted_at?: string;
  last_position_ms?: number;
  created_at: string;
  updated_at: string;
}

export interface ListeningEvent {
  listening_event_id: string;
  share_session_id?: string;
  listening_room_id?: string;
  recipient_id?: string;
  participant_id?: string;
  song_id: string;
  version_id?: string;
  event_type: ListeningEventType;
  playback_position_ms?: number;
  percent_complete?: number;
  metadata: Record<string, unknown>;
  created_at: string;
}

export interface DecisionResponse {
  decision_response_id: string;
  share_session_id?: string;
  listening_room_id?: string;
  recipient_id?: string;
  participant_id?: string;
  song_id: string;
  version_id?: string;
  decision_request_type: DecisionRequestType;
  response_value: DecisionResponseValue;
  confidence?: number;
  text_note?: string;
  voice_note_storage_path?: string;
  transcript?: string;
  created_at: string;
  updated_at: string;
}

export interface TimestampedReaction {
  timestamped_reaction_id: string;
  share_session_id?: string;
  listening_room_id?: string;
  recipient_id?: string;
  participant_id?: string;
  song_id: string;
  version_id?: string;
  playback_position_ms: number;
  reaction_type: TimestampedReactionType;
  intensity?: number;
  note_text?: string;
  voice_note_storage_path?: string;
  transcript?: string;
  created_at: string;
}

export interface ListeningRoom {
  listening_room_id: string;
  workspace_id: string;
  host_user_id: string;
  artist_id?: string;
  artist_name?: string;
  room_id?: string;
  room_type: ListeningRoomType;
  title: string;
  context_note?: string;
  decision_request_type?: DecisionRequestType;
  scheduled_start_at?: string;
  started_at?: string;
  ended_at?: string;
  lifecycle_state: ListeningRoomLifecycleState;
  retention_policy: ListeningRoomRetentionPolicy;
  token_hash: string;
  demo_token?: string;
  created_at: string;
  updated_at: string;
}

export interface ListeningRoomTrack {
  listening_room_track_id: string;
  listening_room_id: string;
  song_id: string;
  version_id?: string;
  sort_order: number;
  created_at: string;
}

export interface ListeningRoomParticipant {
  participant_id: string;
  listening_room_id: string;
  user_id?: string;
  recipient_email?: string;
  recipient_phone?: string;
  display_name?: string;
  role_in_room: "host" | "listener";
  joined_at?: string;
  left_at?: string;
  completed_at?: string;
  first_take_submitted_at?: string;
  created_at: string;
  updated_at: string;
}

export interface ListeningRoomState {
  listening_room_id: string;
  current_track_id?: string;
  current_version_id?: string;
  playback_state: ListeningRoomPlaybackState;
  host_position_ms: number;
  host_started_at_server_time?: string;
  updated_at: string;
}

export interface ListeningReport {
  listening_report_id: string;
  report_type: ListeningReportType;
  share_session_id?: string;
  listening_room_id?: string;
  workspace_id: string;
  artist_id?: string;
  artist_name?: string;
  song_id?: string;
  room_id?: string;
  version_id?: string;
  summary_json: Record<string, unknown>;
  created_by: string;
  visibility: ListeningReportVisibility;
  expires_at?: string;
  created_at: string;
  updated_at: string;
}

export interface ActivityEvent {
  event_id: string;
  workspace_id: string;
  actor_user_id?: string;
  actor_recipient_label?: string;
  event_type: EventType;
  target_type?: string;
  target_id?: string;
  song_id?: string;
  version_id?: string;
  link_id?: string;
  metadata: Record<string, unknown>;
  ip_hash?: string;
  user_agent_hash?: string;
  created_at: string;
}

export interface NotificationItem {
  notification_id: string;
  user_id: string;
  type: string;
  payload: Record<string, unknown>;
  read_at?: string;
  created_at: string;
}

export interface SavedView {
  view_id: string;
  workspace_id: string;
  user_id?: string;
  name: string;
  filter: Record<string, unknown>;
  created_at: string;
}

export interface InboxItem {
  song: Song;
  room: Room;
  current_version: Version;
  asset: FileAsset;
  shared_by: string;
  new_since_last_listen: boolean;
  last_listened_at?: string;
  personal_note?: string;
}

export interface DeliverableStatus {
  ready: boolean;
  missing: string[];
  present: string[];
}

/**
 * Producer-curated ordered list of songs. Unlike a Room (which is
 * permissioned and purposeful — "Hudson Ingram LP · Approval run"), a
 * Playlist is ad-hoc and personal. Songs can live in multiple playlists,
 * playlists can cross rooms, and a playlist's purpose is just to be a
 * thing you can play through or share.
 */
export interface Playlist {
  playlist_id: string;
  workspace_id: string;
  /** Set when the playlist is private to one user; null = workspace-wide. */
  owner_user_id?: string;
  title: string;
  description?: string;
  /** Stable seed used to derive the cover gradient. Independent of title
   *  so renames don't change the visual identity. */
  cover_seed: string;
  is_pinned?: boolean;
  created_by: string;
  created_at: string;
  updated_at: string;
}

export interface PlaylistItem {
  playlist_item_id: string;
  playlist_id: string;
  song_id: string;
  /** Producer-defined ordering. Smaller = earlier in the list. */
  position: number;
  added_by: string;
  added_at: string;
  /** Optional per-item note ("send me this with the vocal pulled 1dB"). */
  note?: string;
}

/**
 * A share-link recipient (no account) asking the workspace owner for full
 * Playback access. Created from the public recipient player; surfaced in the
 * owner's Inbox where approving generates an invite link.
 */
export interface AccessRequest {
  request_id: string;
  workspace_id: string;
  name: string;
  email: string;
  /** The share-link token the request came through (demo/raw token). */
  source_token?: string;
  /** Title of the song/playlist/room the link exposed — gives the owner context. */
  source_song_title?: string;
  status: "pending" | "approved" | "dismissed";
  created_at: string;
}

/**
 * Server-side pin list per (user, workspace). Entries are "type:id" strings
 * matching the iOS PinRef encoding — e.g. "song:song-1", "playlist:pl-2",
 * "room:room-3". Last-write-wins replacement semantics.
 */
export interface UserPins {
  user_id: string;
  workspace_id: string;
  pins: string[];
  updated_at: string;
}

export interface WorkspaceSnapshot {
  workspaces: Workspace[];
  users: User[];
  memberships: Membership[];
  rooms: Room[];
  assets: FileAsset[];
  songs: Song[];
  versions: Version[];
  notes: Note[];
  mentions: Mention[];
  tasks: Task[];
  approvals: Approval[];
  shareLinks: ShareLink[];
  shareRecipients: ShareRecipient[];
  activityEvents: ActivityEvent[];
  notifications: NotificationItem[];
  savedViews: SavedView[];
  playlists: Playlist[];
  playlistItems: PlaylistItem[];
  shareSessions: ShareSession[];
  shareSessionRecipients: ShareSessionRecipient[];
  listeningEvents: ListeningEvent[];
  decisionResponses: DecisionResponse[];
  timestampedReactions: TimestampedReaction[];
  listeningRooms: ListeningRoom[];
  listeningRoomTracks: ListeningRoomTrack[];
  listeningRoomParticipants: ListeningRoomParticipant[];
  listeningRoomStates: ListeningRoomState[];
  listeningReports: ListeningReport[];
  accessRequests: AccessRequest[];
  userPins: UserPins[];
}
