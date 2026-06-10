import type {
  DecisionResponse,
  ListeningEvent,
  ListeningReport,
  ListeningRoom,
  ListeningRoomParticipant,
  ListeningRoomState,
  ListeningRoomTrack,
  Note,
  ShareLink,
  ShareRecipient,
  ShareSession,
  ShareSessionRecipient,
  Song,
  TimestampedReaction,
} from "@pmw/shared";
import { getSupabase } from "./supabase";

/**
 * Best-effort write-through to Supabase. The store's mutations call these
 * so user-created data survives API restarts. Failures are logged but
 * don't break the in-memory mutation — that's the design tradeoff: the
 * client always sees its action succeed locally; sync issues become
 * server-side warnings to investigate.
 *
 * The string IDs the rest of the codebase uses are translated to the
 * Supabase UUIDs via the `external_id` columns. Lookups are done on
 * external_id so the call sites don't need to know about UUIDs.
 */

async function uuidFor(table: string, idColumn: string, externalId: string): Promise<string | null> {
  const supabase = getSupabase();
  if (!supabase) return null;
  const { data, error } = await supabase
    .from(table)
    .select(idColumn)
    .eq("external_id", externalId)
    .maybeSingle();
  if (error || !data) return null;
  return (data as any)[idColumn] as string;
}

async function targetUuidFor(targetType: ShareLink["target_type"], externalId: string): Promise<string | null> {
  if (targetType === "song") return uuidFor("songs", "song_id", externalId);
  if (targetType === "room") return uuidFor("rooms", "room_id", externalId);
  return uuidFor("playlists", "playlist_id", externalId);
}

/** Persist a note created in-memory to Supabase. */
export async function persistNote(note: Note): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;

  const songUuid = await uuidFor("songs", "song_id", note.song_id);
  const versionUuid = await uuidFor("versions", "version_id", note.anchor_version_id);
  if (!songUuid || !versionUuid) {
    console.warn("[supabase-persist] note skipped — couldn't resolve song/version", note.song_id, note.anchor_version_id);
    return;
  }

  const authorUuid = note.author_user_id
    ? await uuidFor("users", "user_id", note.author_user_id)
    : null;
  const roomUuid = note.room_id
    ? await uuidFor("rooms", "room_id", note.room_id)
    : null;

  const { error } = await supabase.from("notes").insert({
    external_id: note.note_id,
    song_id: songUuid,
    anchor_version_id: versionUuid,
    room_id: roomUuid,
    author_user_id: authorUuid,
    author_guest_label: note.author_guest_label ?? null,
    body: note.body,
    scope: note.scope,
    visibility: note.visibility,
    timestamp_start_ms: note.timestamp_start_ms ?? null,
    timestamp_end_ms: note.timestamp_end_ms ?? null,
    timestamp_uncertain: !!note.timestamp_uncertain,
    priority: note.priority,
    status: note.status,
  });

  if (error) {
    console.warn("[supabase-persist] note insert failed:", error.message);
  }
}

/** Mark a note resolved in Supabase. */
export async function persistNoteResolution(
  noteExternalId: string,
  resolvedByExternalId: string,
  resolvedOnVersionExternalId: string
): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const resolvedByUuid = await uuidFor("users", "user_id", resolvedByExternalId);
  const onVersionUuid = await uuidFor("versions", "version_id", resolvedOnVersionExternalId);
  const { error } = await supabase
    .from("notes")
    .update({
      status: "resolved",
      resolved_by: resolvedByUuid,
      resolved_on_version_id: onVersionUuid,
      resolved_at: new Date().toISOString(),
    })
    .eq("external_id", noteExternalId);
  if (error) console.warn("[supabase-persist] note resolve failed:", error.message);
}

/**
 * Persist a share-link revocation (or un-revocation) to Supabase.
 *
 * Keyed on `token_hash` — the one column that is unique, NOT NULL, and present
 * on every link regardless of whether it was seeded, hydrated from the DB, or
 * created at runtime (link_id / external_id differ across those paths; token_hash
 * does not). Without this, revocation lives only in the in-memory snapshot and a
 * server restart re-hydrates `revoked_at: null` — silently bringing a revoked
 * link, and the unreleased audio behind it, back to life.
 */
export async function persistLinkRevocation(
  tokenHash: string,
  revokedAt: string | null
): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const { error } = await supabase
    .from("share_links")
    .update({ revoked_at: revokedAt })
    .eq("token_hash", tokenHash);
  if (error) console.warn("[supabase-persist] link revoke failed:", error.message);
}

/** Persist a newly-created share link to Supabase. */
export async function persistShareLink(link: ShareLink): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;

  const workspaceUuid = await uuidFor("workspaces", "workspace_id", link.workspace_id);
  const targetUuid = await targetUuidFor(link.target_type, link.target_id);
  const createdByUuid = link.created_by ? await uuidFor("users", "user_id", link.created_by) : null;
  if (!workspaceUuid || !targetUuid) {
    console.warn("[supabase-persist] link skipped — couldn't resolve workspace/target", link.workspace_id, link.target_id);
    return;
  }

  const { error } = await supabase.from("share_links").insert({
    external_id: link.link_id,
    workspace_id: workspaceUuid,
    target_type: link.target_type,
    target_id: targetUuid,
    token_hash: link.token_hash,
    link_name: link.link_name ?? null,
    access_mode: link.access_mode,
    password_hash: link.password_hash ?? null,
    expires_at: link.expires_at ?? null,
    download_policy: link.download_policy,
    version_policy: link.version_policy,
    requires_identity: link.requires_identity,
    watermark_enabled: link.watermark_enabled,
    allow_comments: link.allow_comments,
    allow_approval: link.allow_approval,
    allow_forwarding: link.allow_forwarding,
    created_by: createdByUuid,
    revoked_at: link.revoked_at ?? null,
    created_at: link.created_at,
  });
  if (error) console.warn("[supabase-persist] link insert failed:", error.message);
}

/** Persist invited recipients for a share link. */
export async function persistShareRecipients(recipients: ShareRecipient[]): Promise<void> {
  const supabase = getSupabase();
  if (!supabase || recipients.length === 0) return;

  const rows = [];
  for (const recipient of recipients) {
    const linkUuid = await uuidFor("share_links", "link_id", recipient.link_id);
    const invitedByUuid = await uuidFor("users", "user_id", recipient.invited_by);
    if (!linkUuid) {
      console.warn("[supabase-persist] recipient skipped — couldn't resolve link", recipient.link_id);
      continue;
    }
    rows.push({
      external_id: recipient.recipient_id,
      link_id: linkUuid,
      email: recipient.email,
      display_name: recipient.display_name ?? null,
      role: recipient.role,
      invited_by: invitedByUuid,
      invited_at: recipient.invited_at,
      last_sent_at: recipient.last_sent_at ?? recipient.invited_at,
      accepted_at: recipient.accepted_at ?? null,
      revoked_at: recipient.revoked_at ?? null,
    });
  }

  if (rows.length === 0) return;
  const { error } = await supabase.from("share_recipients").upsert(rows, { onConflict: "external_id" });
  if (error) console.warn("[supabase-persist] recipient upsert failed:", error.message);
}

export async function persistShareRecipientPatch(recipient: ShareRecipient): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const { error } = await supabase
    .from("share_recipients")
    .update({
      display_name: recipient.display_name ?? null,
      role: recipient.role,
      last_sent_at: recipient.last_sent_at ?? null,
      accepted_at: recipient.accepted_at ?? null,
      revoked_at: recipient.revoked_at ?? null,
    })
    .eq("external_id", recipient.recipient_id);
  if (error) console.warn("[supabase-persist] recipient patch failed:", error.message);
}

export async function persistSongPatch(
  songExternalId: string,
  patch: Partial<Pick<
    Song,
    | "title"
    | "primary_room_id"
    | "status"
    | "artist_display_name"
    | "project_name"
    | "bpm"
    | "song_key"
    | "explicit_flag"
    | "genre_tags"
    | "mood_tags"
    | "instrument_tags"
    | "lyric_theme_tags"
    | "artwork_key"
    | "artwork_url"
    | "release_readiness_status"
  >>
): Promise<void> {
  const supabase = getSupabase();
  if (!supabase || Object.keys(patch).length === 0) return;
  const { error } = await supabase
    .from("songs")
    .update(patch)
    .eq("external_id", songExternalId);
  if (error) console.warn("[supabase-persist] song patch failed:", error.message);
}

export async function persistVersionPatch(
  versionExternalId: string,
  patch: { version_label?: string; type?: string }
): Promise<void> {
  const supabase = getSupabase();
  if (!supabase || Object.keys(patch).length === 0) return;
  const { error } = await supabase
    .from("versions")
    .update(patch)
    .eq("external_id", versionExternalId);
  if (error) console.warn("[supabase-persist] version patch failed:", error.message);
}

/** Mark a note reopened in Supabase. */
export async function persistNoteReopen(noteExternalId: string): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const { error } = await supabase
    .from("notes")
    .update({
      status: "open",
      resolved_by: null,
      resolved_on_version_id: null,
      resolved_at: null,
    })
    .eq("external_id", noteExternalId);
  if (error) console.warn("[supabase-persist] note reopen failed:", error.message);
}

export async function persistShareSession(session: ShareSession): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const workspaceUuid = await uuidFor("workspaces", "workspace_id", session.workspace_id);
  const songUuid = await uuidFor("songs", "song_id", session.song_id);
  const roomUuid = session.room_id ? await uuidFor("rooms", "room_id", session.room_id) : null;
  const versionUuid = session.version_id ? await uuidFor("versions", "version_id", session.version_id) : null;
  const senderUuid = await uuidFor("users", "user_id", session.sender_user_id);
  if (!workspaceUuid || !songUuid) return;
  const { error } = await supabase.from("share_sessions").upsert({
    external_id: session.share_session_id,
    workspace_id: workspaceUuid,
    artist_name: session.artist_name ?? null,
    song_id: songUuid,
    room_id: roomUuid,
    version_id: versionUuid,
    sender_user_id: senderUuid,
    share_type: session.share_type,
    decision_request_type: session.decision_request_type,
    context_note: session.context_note ?? null,
    voice_preface_storage_path: session.voice_preface_storage_path ?? null,
    token_hash: session.token_hash,
    expires_at: session.expires_at ?? null,
    max_first_listens: session.max_first_listens,
    replay_grants_count: session.replay_grants_count,
    status: session.status,
    created_at: session.created_at,
    updated_at: session.updated_at,
  }, { onConflict: "external_id" });
  if (error) console.warn("[supabase-persist] share session upsert failed:", error.message);
}

export async function persistShareSessionRecipient(recipient: ShareSessionRecipient): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const sessionUuid = await uuidFor("share_sessions", "share_session_id", recipient.share_session_id);
  const userUuid = recipient.recipient_user_id ? await uuidFor("users", "user_id", recipient.recipient_user_id) : null;
  if (!sessionUuid) return;
  const { error } = await supabase.from("share_session_recipients").upsert({
    external_id: recipient.recipient_id,
    share_session_id: sessionUuid,
    recipient_user_id: userUuid,
    recipient_email: recipient.recipient_email ?? null,
    recipient_phone: recipient.recipient_phone ?? null,
    display_name: recipient.display_name ?? null,
    access_state: recipient.access_state,
    opened_at: recipient.opened_at ?? null,
    started_at: recipient.started_at ?? null,
    completed_at: recipient.completed_at ?? null,
    expired_at: recipient.expired_at ?? null,
    replay_requested_at: recipient.replay_requested_at ?? null,
    replay_granted_at: recipient.replay_granted_at ?? null,
    last_position_ms: recipient.last_position_ms ?? null,
    created_at: recipient.created_at,
    updated_at: recipient.updated_at,
  }, { onConflict: "external_id" });
  if (error) console.warn("[supabase-persist] share session recipient upsert failed:", error.message);
}

export async function persistListeningRoomBundle(
  room: ListeningRoom,
  track: ListeningRoomTrack,
  host: ListeningRoomParticipant,
  state: ListeningRoomState,
): Promise<void> {
  await persistListeningRoom(room);
  await persistListeningRoomTrack(track);
  await persistListeningRoomParticipant(host);
  await persistListeningRoomState(state);
}

export async function persistListeningRoom(room: ListeningRoom): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const workspaceUuid = await uuidFor("workspaces", "workspace_id", room.workspace_id);
  const hostUuid = await uuidFor("users", "user_id", room.host_user_id);
  const projectUuid = room.room_id ? await uuidFor("rooms", "room_id", room.room_id) : null;
  if (!workspaceUuid) return;
  const { error } = await supabase.from("listening_rooms").upsert({
    external_id: room.listening_room_id,
    workspace_id: workspaceUuid,
    host_user_id: hostUuid,
    artist_name: room.artist_name ?? null,
    room_id: projectUuid,
    room_type: room.room_type,
    title: room.title,
    context_note: room.context_note ?? null,
    decision_request_type: room.decision_request_type ?? null,
    scheduled_start_at: room.scheduled_start_at ?? null,
    started_at: room.started_at ?? null,
    ended_at: room.ended_at ?? null,
    lifecycle_state: room.lifecycle_state,
    retention_policy: room.retention_policy,
    token_hash: room.token_hash,
    created_at: room.created_at,
    updated_at: room.updated_at,
  }, { onConflict: "external_id" });
  if (error) console.warn("[supabase-persist] listening room upsert failed:", error.message);
}

export async function persistListeningRoomTrack(track: ListeningRoomTrack): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const roomUuid = await uuidFor("listening_rooms", "listening_room_id", track.listening_room_id);
  const songUuid = await uuidFor("songs", "song_id", track.song_id);
  const versionUuid = track.version_id ? await uuidFor("versions", "version_id", track.version_id) : null;
  if (!roomUuid || !songUuid) return;
  const { error } = await supabase.from("listening_room_tracks").upsert({
    external_id: track.listening_room_track_id,
    listening_room_id: roomUuid,
    song_id: songUuid,
    version_id: versionUuid,
    sort_order: track.sort_order,
    created_at: track.created_at,
  }, { onConflict: "external_id" });
  if (error) console.warn("[supabase-persist] listening room track upsert failed:", error.message);
}

export async function persistListeningRoomParticipant(participant: ListeningRoomParticipant): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const roomUuid = await uuidFor("listening_rooms", "listening_room_id", participant.listening_room_id);
  const userUuid = participant.user_id ? await uuidFor("users", "user_id", participant.user_id) : null;
  if (!roomUuid) return;
  const { error } = await supabase.from("listening_room_participants").upsert({
    external_id: participant.participant_id,
    listening_room_id: roomUuid,
    user_id: userUuid,
    recipient_email: participant.recipient_email ?? null,
    recipient_phone: participant.recipient_phone ?? null,
    display_name: participant.display_name ?? null,
    role_in_room: participant.role_in_room,
    joined_at: participant.joined_at ?? null,
    left_at: participant.left_at ?? null,
    completed_at: participant.completed_at ?? null,
    first_take_submitted_at: participant.first_take_submitted_at ?? null,
    created_at: participant.created_at,
    updated_at: participant.updated_at,
  }, { onConflict: "external_id" });
  if (error) console.warn("[supabase-persist] listening room participant upsert failed:", error.message);
}

export async function persistListeningRoomState(state: ListeningRoomState): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const roomUuid = await uuidFor("listening_rooms", "listening_room_id", state.listening_room_id);
  const songUuid = state.current_track_id ? await uuidFor("songs", "song_id", state.current_track_id) : null;
  const versionUuid = state.current_version_id ? await uuidFor("versions", "version_id", state.current_version_id) : null;
  if (!roomUuid) return;
  const { error } = await supabase.from("listening_room_state").upsert({
    listening_room_id: roomUuid,
    current_track_id: songUuid,
    current_version_id: versionUuid,
    playback_state: state.playback_state,
    host_position_ms: state.host_position_ms,
    host_started_at_server_time: state.host_started_at_server_time ?? null,
    updated_at: state.updated_at,
  }, { onConflict: "listening_room_id" });
  if (error) console.warn("[supabase-persist] listening room state upsert failed:", error.message);
}

export async function persistListeningEvent(event: ListeningEvent): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const shareUuid = event.share_session_id ? await uuidFor("share_sessions", "share_session_id", event.share_session_id) : null;
  const roomUuid = event.listening_room_id ? await uuidFor("listening_rooms", "listening_room_id", event.listening_room_id) : null;
  const recipientUuid = event.recipient_id ? await uuidFor("share_session_recipients", "recipient_id", event.recipient_id) : null;
  const participantUuid = event.participant_id ? await uuidFor("listening_room_participants", "participant_id", event.participant_id) : null;
  const songUuid = await uuidFor("songs", "song_id", event.song_id);
  const versionUuid = event.version_id ? await uuidFor("versions", "version_id", event.version_id) : null;
  if (!songUuid || (!shareUuid && !roomUuid)) return;
  const { error } = await supabase.from("listening_events").insert({
    external_id: event.listening_event_id,
    share_session_id: shareUuid,
    listening_room_id: roomUuid,
    recipient_id: recipientUuid,
    participant_id: participantUuid,
    song_id: songUuid,
    version_id: versionUuid,
    event_type: event.event_type,
    playback_position_ms: event.playback_position_ms ?? null,
    percent_complete: event.percent_complete ?? null,
    metadata: event.metadata,
    created_at: event.created_at,
  });
  if (error) console.warn("[supabase-persist] listening event insert failed:", error.message);
}

export async function persistDecisionResponse(response: DecisionResponse): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const shareUuid = response.share_session_id ? await uuidFor("share_sessions", "share_session_id", response.share_session_id) : null;
  const roomUuid = response.listening_room_id ? await uuidFor("listening_rooms", "listening_room_id", response.listening_room_id) : null;
  const recipientUuid = response.recipient_id ? await uuidFor("share_session_recipients", "recipient_id", response.recipient_id) : null;
  const participantUuid = response.participant_id ? await uuidFor("listening_room_participants", "participant_id", response.participant_id) : null;
  const songUuid = await uuidFor("songs", "song_id", response.song_id);
  const versionUuid = response.version_id ? await uuidFor("versions", "version_id", response.version_id) : null;
  if (!songUuid || (!shareUuid && !roomUuid)) return;
  const { error } = await supabase.from("decision_responses").upsert({
    external_id: response.decision_response_id,
    share_session_id: shareUuid,
    listening_room_id: roomUuid,
    recipient_id: recipientUuid,
    participant_id: participantUuid,
    song_id: songUuid,
    version_id: versionUuid,
    decision_request_type: response.decision_request_type,
    response_value: response.response_value,
    confidence: response.confidence ?? null,
    text_note: response.text_note ?? null,
    voice_note_storage_path: response.voice_note_storage_path ?? null,
    transcript: response.transcript ?? null,
    created_at: response.created_at,
    updated_at: response.updated_at,
  }, { onConflict: "external_id" });
  if (error) console.warn("[supabase-persist] decision response upsert failed:", error.message);
}

export async function persistTimestampedReaction(reaction: TimestampedReaction): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const shareUuid = reaction.share_session_id ? await uuidFor("share_sessions", "share_session_id", reaction.share_session_id) : null;
  const roomUuid = reaction.listening_room_id ? await uuidFor("listening_rooms", "listening_room_id", reaction.listening_room_id) : null;
  const recipientUuid = reaction.recipient_id ? await uuidFor("share_session_recipients", "recipient_id", reaction.recipient_id) : null;
  const participantUuid = reaction.participant_id ? await uuidFor("listening_room_participants", "participant_id", reaction.participant_id) : null;
  const songUuid = await uuidFor("songs", "song_id", reaction.song_id);
  const versionUuid = reaction.version_id ? await uuidFor("versions", "version_id", reaction.version_id) : null;
  if (!songUuid || (!shareUuid && !roomUuid)) return;
  const { error } = await supabase.from("timestamped_reactions").upsert({
    external_id: reaction.timestamped_reaction_id,
    share_session_id: shareUuid,
    listening_room_id: roomUuid,
    recipient_id: recipientUuid,
    participant_id: participantUuid,
    song_id: songUuid,
    version_id: versionUuid,
    playback_position_ms: reaction.playback_position_ms,
    reaction_type: reaction.reaction_type,
    intensity: reaction.intensity ?? null,
    note_text: reaction.note_text ?? null,
    voice_note_storage_path: reaction.voice_note_storage_path ?? null,
    transcript: reaction.transcript ?? null,
    created_at: reaction.created_at,
  }, { onConflict: "external_id" });
  if (error) console.warn("[supabase-persist] timestamped reaction upsert failed:", error.message);
}

export async function persistListeningReport(report: ListeningReport): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;
  const shareUuid = report.share_session_id ? await uuidFor("share_sessions", "share_session_id", report.share_session_id) : null;
  const roomUuid = report.listening_room_id ? await uuidFor("listening_rooms", "listening_room_id", report.listening_room_id) : null;
  const workspaceUuid = await uuidFor("workspaces", "workspace_id", report.workspace_id);
  const songUuid = report.song_id ? await uuidFor("songs", "song_id", report.song_id) : null;
  const projectUuid = report.room_id ? await uuidFor("rooms", "room_id", report.room_id) : null;
  const versionUuid = report.version_id ? await uuidFor("versions", "version_id", report.version_id) : null;
  const creatorUuid = await uuidFor("users", "user_id", report.created_by);
  if (!workspaceUuid) return;
  const { error } = await supabase.from("listening_reports").upsert({
    external_id: report.listening_report_id,
    report_type: report.report_type,
    share_session_id: shareUuid,
    listening_room_id: roomUuid,
    workspace_id: workspaceUuid,
    artist_name: report.artist_name ?? null,
    song_id: songUuid,
    room_id: projectUuid,
    version_id: versionUuid,
    summary_json: report.summary_json,
    created_by: creatorUuid,
    visibility: report.visibility,
    expires_at: report.expires_at ?? null,
    created_at: report.created_at,
    updated_at: report.updated_at,
  }, { onConflict: "external_id" });
  if (error) console.warn("[supabase-persist] listening report upsert failed:", error.message);
}
