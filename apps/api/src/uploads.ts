import { randomUUID } from "node:crypto";
import { getSupabase } from "./supabase";

const BUCKET = "wl-audio";
const SIGN_TTL_SECONDS = 60 * 30; // 30 minutes to complete the upload

export type SignUploadInput = {
  filename: string;
  contentType?: string;
  songExternalId?: string;     // when uploading a new version of an existing song
  workspaceExternalId?: string; // defaults to wsp-amf-private
};

export type SignUploadResult = {
  uploadUrl: string;
  token: string;
  storagePath: string;
  publicUrl: string;
  expiresInSeconds: number;
};

/**
 * Mint a signed upload URL for Supabase Storage. The client PUTs the audio
 * file directly to that URL (no proxying through this API).
 *
 * Path convention: `{workspace}/{song}/{uuid}.{ext}`
 * Once the upload finishes, the client calls /uploads/finalize to create
 * the file_assets + versions rows.
 */
export async function signUpload(input: SignUploadInput): Promise<SignUploadResult> {
  const supabase = getSupabase();
  if (!supabase) throw new Error("Supabase not configured");

  const safeName = input.filename.replace(/[^\w.\-]+/g, "_");
  const ext = safeName.includes(".") ? safeName.slice(safeName.lastIndexOf(".")) : "";
  const id = randomUUID();
  const workspace = (input.workspaceExternalId ?? "wsp-amf-private").replace(/[^\w-]+/g, "_");
  const song = (input.songExternalId ?? "uncategorized").replace(/[^\w-]+/g, "_");
  const storagePath = `${workspace}/${song}/${id}${ext}`;

  const { data, error } = await supabase.storage
    .from(BUCKET)
    .createSignedUploadUrl(storagePath);

  if (error) throw new Error(`signed upload url failed: ${error.message}`);

  const { data: pub } = supabase.storage.from(BUCKET).getPublicUrl(storagePath);

  return {
    uploadUrl: data.signedUrl,
    token: data.token,
    storagePath,
    publicUrl: pub.publicUrl,
    expiresInSeconds: SIGN_TTL_SECONDS,
  };
}

/**
 * Mint a short-lived signed URL to STREAM an already-uploaded object. Unlike
 * getPublicUrl() (which returns a permanent, unauthenticated URL that outlives
 * any link revocation), a signed URL expires and is minted per-request — so the
 * caller can re-check authorization (link still live, not revoked/expired) every
 * time audio loads. This is the read-path counterpart to the upload signing
 * above and the mechanism that makes "revoke a link" actually stop the audio.
 */
export async function signPlaybackUrl(storagePath: string, ttlSeconds = 3600): Promise<string> {
  const supabase = getSupabase();
  if (!supabase) throw new Error("Supabase not configured");
  const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(storagePath, ttlSeconds);
  if (error || !data?.signedUrl) {
    throw new Error(`could not sign playback url: ${error?.message ?? "unknown"}`);
  }
  return data.signedUrl;
}

export type FinalizeUploadInput = {
  storagePath: string;
  publicUrl: string;
  filename: string;
  contentType?: string;
  fileSizeBytes: number;
  durationMs?: number;
  sampleRate?: number;
  bitDepth?: number;
  loudnessLufs?: number;
  songExternalId: string;
  versionLabel?: string;
  versionType?: string;
  workspaceExternalId?: string;
  uploadedBy?: string; // external_id of user
};

export type FinalizeUploadResult = {
  assetId: string;
  assetExternalId: string;
  versionId: string;
  versionExternalId: string;
  versionNumber: number;
};

/**
 * After the client PUT completes, persist the file_asset + version rows in
 * Supabase. Returns the new IDs so the UI can refresh.
 */
export async function finalizeUpload(input: FinalizeUploadInput): Promise<FinalizeUploadResult> {
  const supabase = getSupabase();
  if (!supabase) throw new Error("Supabase not configured");

  // Resolve workspace UUID
  const workspaceExternal = input.workspaceExternalId ?? "wsp-amf-private";
  const wsRes = await supabase.from("workspaces").select("workspace_id").eq("external_id", workspaceExternal).maybeSingle();
  if (wsRes.error || !wsRes.data) throw new Error(`workspace not found: ${workspaceExternal}`);
  const workspaceUuid = (wsRes.data as { workspace_id: string }).workspace_id;

  // Resolve song UUID + workspace
  const songRes = await supabase.from("songs").select("song_id, workspace_id").eq("external_id", input.songExternalId).maybeSingle();
  if (songRes.error || !songRes.data) throw new Error(`song not found: ${input.songExternalId}`);
  const songUuid = (songRes.data as { song_id: string }).song_id;

  // Resolve uploader UUID (default to usr-theo)
  const uploaderExternal = input.uploadedBy ?? "usr-theo";
  const usrRes = await supabase.from("users").select("user_id").eq("external_id", uploaderExternal).maybeSingle();
  if (usrRes.error || !usrRes.data) throw new Error(`uploader not found: ${uploaderExternal}`);
  const uploaderUuid = (usrRes.data as { user_id: string }).user_id;

  // Next version number for this song
  const verCountRes = await supabase
    .from("versions")
    .select("version_number")
    .eq("song_id", songUuid)
    .order("version_number", { ascending: false })
    .limit(1);
  if (verCountRes.error) throw new Error(`could not count versions: ${verCountRes.error.message}`);
  const nextNumber = ((verCountRes.data?.[0] as { version_number: number } | undefined)?.version_number ?? 0) + 1;

  const assetExternalId = `asset-${input.songExternalId}-v${nextNumber}-${Date.now()}`;
  const versionExternalId = `ver-${input.songExternalId}-v${nextNumber}-${Date.now()}`;

  // Insert file_asset
  const assetInsert = await supabase
    .from("file_assets")
    .insert({
      external_id: assetExternalId,
      workspace_id: workspaceUuid,
      original_filename: input.filename,
      key_original: input.storagePath,
      mime_type: input.contentType ?? "audio/mpeg",
      file_size_bytes: input.fileSizeBytes,
      duration_ms: input.durationMs ?? null,
      sample_rate: input.sampleRate ?? null,
      bit_depth: input.bitDepth ?? null,
      loudness_lufs: input.loudnessLufs ?? null,
      virus_scan_status: "clean",
      transcoding_status: "ready",
      playback_url: input.publicUrl,
    })
    .select("asset_id")
    .single();
  if (assetInsert.error || !assetInsert.data) throw new Error(`asset insert failed: ${assetInsert.error?.message}`);
  const assetUuid = (assetInsert.data as { asset_id: string }).asset_id;

  // De-current other versions on this song
  const flipCurrent = await supabase
    .from("versions")
    .update({ is_current: false })
    .eq("song_id", songUuid);
  if (flipCurrent.error) throw new Error(`could not flip is_current: ${flipCurrent.error.message}`);

  // Insert the new version, mark current
  const versionInsert = await supabase
    .from("versions")
    .insert({
      external_id: versionExternalId,
      song_id: songUuid,
      version_number: nextNumber,
      version_label: input.versionLabel ?? `Mix v${nextNumber}`,
      type: input.versionType ?? "mix",
      is_current: true,
      is_approved: false,
      uploaded_by: uploaderUuid,
      file_asset_id: assetUuid,
    })
    .select("version_id")
    .single();
  if (versionInsert.error || !versionInsert.data) throw new Error(`version insert failed: ${versionInsert.error?.message}`);
  const versionUuid = (versionInsert.data as { version_id: string }).version_id;

  // Point song.current_version_id at it
  const songUpdate = await supabase
    .from("songs")
    .update({ current_version_id: versionUuid, status: "in_review", updated_at: new Date().toISOString() })
    .eq("song_id", songUuid);
  if (songUpdate.error) throw new Error(`song update failed: ${songUpdate.error.message}`);

  return {
    assetId: assetUuid,
    assetExternalId,
    versionId: versionUuid,
    versionExternalId,
    versionNumber: nextNumber,
  };
}
