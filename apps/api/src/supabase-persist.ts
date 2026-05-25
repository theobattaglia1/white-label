import type { Note } from "@pmw/shared";
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
