import type {
  ActivityEvent,
  Approval,
  FileAsset,
  Membership,
  Mention,
  Note,
  NotificationItem,
  Room,
  SavedView,
  ShareLink,
  Song,
  Task,
  User,
  Version,
  Workspace,
  WorkspaceSnapshot,
} from "@pmw/shared";
import { getSupabase } from "./supabase";

/**
 * Pulls the full workspace snapshot from Supabase and shapes it to match
 * the in-memory snapshot the rest of the API expects. The string IDs the
 * existing code uses (`song-midnight`, `room-secret-album`…) come from
 * the `external_id` columns we added to the schema, so existing find/filter
 * logic against `*_id` fields keeps working.
 *
 * Returns null if Supabase isn't configured.
 */
export async function loadSnapshotFromSupabase(): Promise<WorkspaceSnapshot | null> {
  const supabase = getSupabase();
  if (!supabase) return null;

  // Fetch every table in parallel
  const [
    usersR,
    workspacesR,
    membershipsR,
    roomsR,
    assetsR,
    songsR,
    versionsR,
    notesR,
    mentionsR,
    tasksR,
    approvalsR,
    linksR,
    activityR,
    notificationsR,
    viewsR,
  ] = await Promise.all([
    supabase.from("users").select("*"),
    supabase.from("workspaces").select("*"),
    supabase.from("memberships").select("*"),
    supabase.from("rooms").select("*"),
    supabase.from("file_assets").select("*"),
    supabase.from("songs").select("*"),
    supabase.from("versions").select("*"),
    supabase.from("notes").select("*"),
    supabase.from("mentions").select("*"),
    supabase.from("tasks").select("*"),
    supabase.from("approvals").select("*"),
    supabase.from("share_links").select("*"),
    supabase.from("activity_events").select("*"),
    supabase.from("notifications").select("*"),
    supabase.from("saved_views").select("*"),
  ]);

  for (const r of [usersR, workspacesR, membershipsR, roomsR, assetsR, songsR, versionsR, notesR, mentionsR, tasksR, approvalsR, linksR, activityR, notificationsR, viewsR]) {
    if (r.error) {
      console.error("[supabase-loader]", r.error);
      throw new Error(`Supabase query failed: ${r.error.message}`);
    }
  }

  // Build lookups from uuid → external_id so we can substitute friendly IDs
  const uuidToExt = new Map<string, string>();
  function track(rows: any[] | null) {
    rows?.forEach((row) => {
      if (row.external_id) {
        const idKey = Object.keys(row).find((k) => k.endsWith("_id") && k !== "external_id");
        if (idKey) uuidToExt.set(row[idKey], row.external_id);
      }
      // also for assets/share_links etc, which always have one *_id PK
    });
  }
  track(usersR.data);
  track(workspacesR.data);
  track(membershipsR.data);
  track(roomsR.data);
  track(assetsR.data);
  track(songsR.data);
  track(versionsR.data);
  track(notesR.data);
  track(linksR.data);

  function ext(uuid: string | null | undefined): string {
    if (!uuid) return "";
    return uuidToExt.get(uuid) ?? uuid;
  }

  const snapshot: WorkspaceSnapshot = {
    users: (usersR.data ?? []).map((u: any): User => ({
      user_id: u.external_id ?? u.user_id,
      email: u.email,
      display_name: u.display_name ?? "",
      avatar_url: u.avatar_url ?? undefined,
      auth_provider: u.auth_provider ?? undefined,
      two_factor_enabled: !!u.two_factor_enabled,
      notification_preferences: u.notification_preferences ?? {},
      created_at: u.created_at,
      updated_at: u.updated_at,
    })),
    workspaces: (workspacesR.data ?? []).map((w: any): Workspace => ({
      workspace_id: w.external_id ?? w.workspace_id,
      name: w.name,
      owner_user_id: ext(w.owner_user_id),
      plan_type: w.plan_type,
      storage_quota_bytes: Number(w.storage_quota_bytes),
      used_storage_bytes: Number(w.used_storage_bytes),
      billing_status: w.billing_status,
      default_link_policy: w.default_link_policy ?? undefined,
      default_naming_convention: w.default_naming_convention ?? undefined,
      created_at: w.created_at,
      updated_at: w.updated_at,
    })),
    memberships: (membershipsR.data ?? []).map((m: any): Membership => ({
      membership_id: m.membership_id,
      workspace_id: ext(m.workspace_id),
      user_id: ext(m.user_id),
      role: m.role,
      created_at: m.created_at,
    })),
    rooms: (roomsR.data ?? []).map((r: any): Room => ({
      room_id: r.external_id ?? r.room_id,
      workspace_id: ext(r.workspace_id),
      type: r.type,
      title: r.title,
      description: r.description ?? undefined,
      visibility: r.visibility,
      status: r.status,
      default_version_visibility: r.default_version_visibility,
      default_download_policy: r.default_download_policy,
      due_date: r.due_date ?? undefined,
      created_by: ext(r.created_by),
      created_at: r.created_at,
      updated_at: r.updated_at,
    })),
    assets: (assetsR.data ?? []).map((a: any): FileAsset => ({
      asset_id: a.external_id ?? a.asset_id,
      workspace_id: ext(a.workspace_id),
      original_filename: a.original_filename,
      normalized_filename: a.normalized_filename ?? undefined,
      key_original: a.key_original,
      key_flac: a.key_flac ?? undefined,
      key_aac_256: a.key_aac_256 ?? undefined,
      key_aac_128: a.key_aac_128 ?? undefined,
      key_waveform_json: a.key_waveform_json ?? undefined,
      key_stems_zip: a.key_stems_zip ?? undefined,
      mime_type: a.mime_type ?? undefined,
      file_size_bytes: Number(a.file_size_bytes ?? 0),
      checksum_sha256: a.checksum_sha256 ?? "",
      duration_ms: a.duration_ms ?? 0,
      sample_rate: a.sample_rate ?? 0,
      bit_depth: a.bit_depth ?? 0,
      loudness_lufs: Number(a.loudness_lufs ?? -14),
      true_peak_db: Number(a.true_peak_db ?? -1.2),
      virus_scan_status: a.virus_scan_status,
      transcoding_status: a.transcoding_status,
      waveform_peaks: deterministicWaveform(a.external_id ?? a.asset_id),
      playback_url: a.playback_url ?? undefined,
      created_at: a.created_at,
    })),
    songs: (songsR.data ?? []).map((s: any): Song => ({
      song_id: s.external_id ?? s.song_id,
      workspace_id: ext(s.workspace_id),
      primary_room_id: ext(s.primary_room_id) || undefined,
      title: s.title,
      artist_display_name: s.artist_display_name ?? undefined,
      project_name: s.project_name ?? undefined,
      status: s.status,
      current_version_id: ext(s.current_version_id) || undefined,
      approved_version_id: ext(s.approved_version_id) || undefined,
      bpm: s.bpm ?? undefined,
      song_key: s.song_key ?? undefined,
      explicit_flag: !!s.explicit_flag,
      genre_tags: s.genre_tags ?? [],
      mood_tags: s.mood_tags ?? [],
      instrument_tags: s.instrument_tags ?? [],
      lyric_theme_tags: s.lyric_theme_tags ?? [],
      release_readiness_status: s.release_readiness_status ?? "not_ready",
      created_by: ext(s.created_by),
      created_at: s.created_at,
      updated_at: s.updated_at,
    })),
    versions: (versionsR.data ?? []).map((v: any): Version => ({
      version_id: v.external_id ?? v.version_id,
      song_id: ext(v.song_id),
      version_number: v.version_number,
      version_label: v.version_label ?? `v${v.version_number}`,
      type: v.type,
      parent_version_id: ext(v.parent_version_id) || undefined,
      is_current: !!v.is_current,
      is_approved: !!v.is_approved,
      uploaded_by: ext(v.uploaded_by),
      file_asset_id: ext(v.file_asset_id),
      created_at: v.created_at,
    })),
    notes: (notesR.data ?? []).map((n: any): Note => ({
      note_id: n.external_id ?? n.note_id,
      song_id: ext(n.song_id),
      anchor_version_id: ext(n.anchor_version_id),
      room_id: ext(n.room_id) || undefined,
      author_user_id: ext(n.author_user_id) || undefined,
      author_guest_label: n.author_guest_label ?? undefined,
      body: n.body ?? "",
      voice_asset_id: ext(n.voice_asset_id) || undefined,
      scope: n.scope,
      visibility: n.visibility,
      timestamp_start_ms: n.timestamp_start_ms ?? undefined,
      timestamp_end_ms: n.timestamp_end_ms ?? undefined,
      timestamp_uncertain: !!n.timestamp_uncertain,
      assigned_to_user_id: ext(n.assigned_to_user_id) || undefined,
      assigned_to_role: n.assigned_to_role ?? undefined,
      priority: n.priority ?? "normal",
      status: n.status,
      resolved_by: ext(n.resolved_by) || undefined,
      resolved_at: n.resolved_at ?? undefined,
      resolved_on_version_id: ext(n.resolved_on_version_id) || undefined,
      created_at: n.created_at,
      updated_at: n.updated_at,
    })),
    mentions: (mentionsR.data ?? []).map((m: any): Mention => ({
      mention_id: m.mention_id,
      note_id: ext(m.note_id),
      mentioned_user_id: ext(m.mentioned_user_id) || undefined,
      mentioned_role: m.mentioned_role ?? undefined,
      notification_status: m.notification_status,
      created_at: m.created_at,
    })),
    tasks: (tasksR.data ?? []).map((t: any): Task => ({
      task_id: t.task_id,
      workspace_id: ext(t.workspace_id),
      room_id: ext(t.room_id) || undefined,
      song_id: ext(t.song_id) || undefined,
      version_id: ext(t.version_id) || undefined,
      source_note_id: ext(t.source_note_id) || undefined,
      title: t.title,
      description: t.description ?? undefined,
      assigned_to_user_id: ext(t.assigned_to_user_id) || undefined,
      assigned_to_role: t.assigned_to_role ?? undefined,
      due_date: t.due_date ?? undefined,
      status: t.status,
      priority: t.priority ?? "normal",
      created_by: ext(t.created_by),
      created_at: t.created_at,
      updated_at: t.updated_at,
    })),
    approvals: (approvalsR.data ?? []).map((a: any): Approval => ({
      approval_id: a.approval_id,
      version_id: ext(a.version_id),
      actor_user_id: ext(a.actor_user_id) || undefined,
      actor_guest_label: a.actor_guest_label ?? undefined,
      state: a.state,
      note: a.note ?? undefined,
      created_at: a.created_at,
    })),
    shareLinks: (linksR.data ?? []).map((l: any): ShareLink => ({
      link_id: l.external_id ?? l.link_id,
      workspace_id: ext(l.workspace_id),
      target_type: l.target_type,
      target_id: ext(l.target_id) || l.target_id,
      token_hash: l.token_hash,
      link_name: l.link_name ?? undefined,
      access_mode: l.access_mode,
      password_hash: l.password_hash ?? undefined,
      expires_at: l.expires_at ?? undefined,
      download_policy: l.download_policy,
      version_policy: l.version_policy,
      requires_identity: !!l.requires_identity,
      watermark_enabled: !!l.watermark_enabled,
      allow_comments: !!l.allow_comments,
      allow_approval: !!l.allow_approval,
      allow_forwarding: !!l.allow_forwarding,
      created_by: ext(l.created_by) || undefined,
      revoked_at: l.revoked_at ?? undefined,
      created_at: l.created_at,
    })),
    activityEvents: (activityR.data ?? []).map((e: any): ActivityEvent => ({
      event_id: e.event_id,
      workspace_id: ext(e.workspace_id),
      actor_user_id: ext(e.actor_user_id) || undefined,
      actor_recipient_label: e.actor_recipient_label ?? undefined,
      event_type: e.event_type,
      target_type: e.target_type ?? undefined,
      target_id: e.target_id ?? undefined,
      song_id: ext(e.song_id) || undefined,
      version_id: ext(e.version_id) || undefined,
      link_id: ext(e.link_id) || undefined,
      metadata: e.metadata ?? {},
      ip_hash: e.ip_hash ?? undefined,
      user_agent_hash: e.user_agent_hash ?? undefined,
      created_at: e.created_at,
    })),
    notifications: (notificationsR.data ?? []).map((n: any): NotificationItem => ({
      notification_id: n.notification_id,
      user_id: ext(n.user_id),
      type: n.type,
      payload: n.payload ?? {},
      read_at: n.read_at ?? undefined,
      created_at: n.created_at,
    })),
    savedViews: (viewsR.data ?? []).map((v: any): SavedView => ({
      view_id: v.view_id,
      workspace_id: ext(v.workspace_id),
      user_id: ext(v.user_id) || undefined,
      name: v.name,
      filter: v.filter,
      created_at: v.created_at,
    })),
  };

  console.log(`[supabase-loader] hydrated: ${snapshot.songs.length} songs, ${snapshot.versions.length} versions, ${snapshot.notes.length} notes, ${snapshot.shareLinks.length} links`);
  return snapshot;
}

/** Deterministic waveform peaks for an asset, matching the seed shape
 *  the in-memory data uses, so the UI keeps rendering bars when audio
 *  metadata isn't yet pre-computed in the DB. */
function deterministicWaveform(seedKey: string): number[] {
  let h = 0;
  for (let i = 0; i < seedKey.length; i++) h = (h * 31 + seedKey.charCodeAt(i)) | 0;
  return Array.from({ length: 72 }, (_, i) => {
    const v = Math.sin((i + h) * 0.42) * 0.36 + Math.sin((i + h) * 0.11) * 0.24 + 0.48;
    return Number(Math.max(0.08, Math.min(0.98, v)).toFixed(2));
  });
}
