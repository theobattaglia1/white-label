import type { Note, ShareLink, ShareRecipient, Song } from "@pmw/shared";
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
