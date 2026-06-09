#!/usr/bin/env npx tsx
/**
 * upload-artist-audio.ts
 *
 * Second-pass audio uploader. The populate script created all Song + Version
 * records as stubs (no playback_url). This script:
 *   1. Finds all file_assets with transcoding_status = "pending" (no audio yet)
 *   2. Matches them back to their source files on the B2/Mountain Duck mount
 *   3. Forces Mountain Duck to download each file (reads it fully)
 *   4. Uploads to Supabase Storage wl-audio bucket
 *   5. Updates the file_asset row with playback_url + duration_ms
 *
 * Runs one file at a time to be gentle on Mountain Duck bandwidth.
 *
 * Usage:
 *   npx tsx scripts/upload-artist-audio.ts               # all pending
 *   npx tsx scripts/upload-artist-audio.ts --artist "Hudson Ingram"
 *   npx tsx scripts/upload-artist-audio.ts --limit 20    # first N only
 */

import { createClient } from "@supabase/supabase-js";
import ws from "ws";
import * as fs from "fs";
import * as fsP from "fs/promises";
import * as path from "path";
import * as https from "https";
import * as http from "http";
import { randomUUID } from "crypto";

// ── Config ────────────────────────────────────────────────────────────────

const ARTISTS_BASE = path.join(
  process.env.HOME!,
  "Library/CloudStorage/MountainDuck-AMFCloud(B2)/Shared Drive/All My Friends Inc/Artists"
);
const BUCKET = "wl-audio";
const WORKSPACE_EXTERNAL_ID = "wsp-amf-private";

const ARTIST_FILTER = process.argv.find((_, i) => process.argv[i - 1] === "--artist");
const LIMIT = parseInt(process.argv.find((_, i) => process.argv[i - 1] === "--limit") ?? "9999");
const AUDIO_EXT = new Set([".mp3", ".m4a", ".wav", ".aiff", ".aif", ".flac"]);

// ── Supabase ──────────────────────────────────────────────────────────────

const envPath = path.join(process.cwd(), ".env");
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, "utf8").split("\n")) {
    const m = line.match(/^([A-Z_]+)=(.+)$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].trim();
  }
}
const sb = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
  auth: { autoRefreshToken: false, persistSession: false },
  realtime: { transport: ws } as any,
});

// ── Walk source files ─────────────────────────────────────────────────────

async function buildFileIndex(): Promise<Map<string, string>> {
  const index = new Map<string, string>(); // normalized_filename → full path

  async function walk(dir: string) {
    let entries: fs.Dirent[];
    try { entries = await fsP.readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) await walk(full);
      else if (e.isFile() && AUDIO_EXT.has(path.extname(e.name).toLowerCase())) {
        // Index by both original name and lowercase-normalized form
        index.set(e.name, full);
        index.set(e.name.toLowerCase().replace(/\s+/g, "-"), full);
        index.set(e.name.toLowerCase(), full);
      }
    }
  }

  const artists = await fsP.readdir(ARTISTS_BASE, { withFileTypes: true });
  for (const a of artists) {
    if (!a.isDirectory() || a.name.startsWith("_")) continue;
    if (ARTIST_FILTER && !a.name.toLowerCase().includes(ARTIST_FILTER.toLowerCase())) continue;
    await walk(path.join(ARTISTS_BASE, a.name, "Music"));
  }

  return index;
}

// ── Upload ────────────────────────────────────────────────────────────────

function mimeFor(filename: string): string {
  const map: Record<string, string> = {
    ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".wav": "audio/wav",
    ".aiff": "audio/aiff", ".aif": "audio/aiff", ".flac": "audio/flac",
  };
  return map[path.extname(filename).toLowerCase()] ?? "audio/mpeg";
}

async function getDurationMs(buffer: Buffer, filename: string): Promise<number | null> {
  // Try to decode with Web Audio API equivalent — not available in Node.
  // Estimate from file size as rough fallback for non-WAV formats.
  const ext = path.extname(filename).toLowerCase();
  if (ext === ".wav") {
    // WAV: bytes 28-31 = byte rate, bytes 4-7 = chunk size
    if (buffer.length > 44) {
      const byteRate = buffer.readUInt32LE(28);
      const dataSize = buffer.length - 44;
      if (byteRate > 0) return Math.round((dataSize / byteRate) * 1000);
    }
  }
  return null;
}

function putBuffer(url: string, body: Buffer, contentType: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith("https") ? https : http;
    const req = mod.request(url, {
      method: "PUT",
      headers: { "content-type": contentType, "content-length": String(body.length), "x-upsert": "true" },
    }, (res) => { res.resume(); res.statusCode && res.statusCode >= 200 && res.statusCode < 300 ? resolve() : reject(new Error(`PUT ${res.statusCode}`)); });
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

async function uploadAsset(assetId: string, assetExtId: string, filePath: string, songExtId: string): Promise<boolean> {
  const filename = path.basename(filePath);
  const ext = path.extname(filename);
  const mime = mimeFor(filename);
  const storagePath = `${WORKSPACE_EXTERNAL_ID}/${songExtId}/${randomUUID()}${ext}`;

  // 1. Sign upload URL
  const { data: signed, error: signErr } = await sb.storage.from(BUCKET).createSignedUploadUrl(storagePath);
  if (signErr || !signed) { console.error(`    sign failed: ${signErr?.message}`); return false; }

  // 2. Download from Mountain Duck (this blocks until the file is local)
  let buffer: Buffer;
  try {
    buffer = await fsP.readFile(filePath);
  } catch (err) {
    console.error(`    read failed: ${err instanceof Error ? err.message : err}`);
    return false;
  }

  // 3. PUT to Supabase Storage
  try {
    await putBuffer(signed.signedUrl, buffer, mime);
  } catch (err) {
    console.error(`    upload failed: ${err instanceof Error ? err.message : err}`);
    return false;
  }

  const { data: pub } = sb.storage.from(BUCKET).getPublicUrl(storagePath);
  const durationMs = await getDurationMs(buffer, filename);

  // 4. Update the file_asset row
  const update: Record<string, unknown> = {
    key_original: storagePath,
    playback_url: pub.publicUrl,
    transcoding_status: "ready",
    file_size_bytes: buffer.length,
  };
  if (durationMs !== null) update.duration_ms = durationMs;

  const { error: updateErr } = await sb.from("file_assets").update(update).eq("asset_id", assetId);
  if (updateErr) { console.error(`    db update failed: ${updateErr.message}`); return false; }

  return true;
}

// ── Main ──────────────────────────────────────────────────────────────────

async function main() {
  console.log(`\n🎵 Audio uploader — second pass`);
  if (ARTIST_FILTER) console.log(`   Artist filter: ${ARTIST_FILTER}`);
  if (LIMIT < 9999) console.log(`   Limit: ${LIMIT}`);
  console.log();

  // Resolve workspace
  const wsRes = await sb.from("workspaces").select("workspace_id").eq("external_id", WORKSPACE_EXTERNAL_ID).single();
  if (wsRes.error || !wsRes.data) { console.error("Workspace not found"); process.exit(1); }

  // Find all pending stubs
  console.log("Scanning Supabase for pending stubs…");
  const { data: pendingAssets, error: fetchErr } = await sb
    .from("file_assets")
    .select("asset_id, external_id, original_filename, normalized_filename")
    .eq("transcoding_status", "pending")
    .like("external_id", "asset-stub-%")
    .limit(LIMIT + 100);

  if (fetchErr) { console.error("Fetch failed:", fetchErr.message); process.exit(1); }
  const stubs = (pendingAssets ?? []).slice(0, LIMIT);
  console.log(`Found ${stubs.length} pending stubs\n`);

  // Build file index from Mountain Duck
  console.log("Indexing source files from Mountain Duck…");
  const fileIndex = await buildFileIndex();
  console.log(`Indexed ${fileIndex.size} source files\n`);

  // Match stubs to source files
  type Stub = { asset_id: string; external_id: string; original_filename: string; normalized_filename?: string };

  let matched = 0, uploaded = 0, skipped = 0;

  for (const stub of stubs as Stub[]) {
    const origName = stub.original_filename;
    const normName = stub.normalized_filename ?? "";

    // Extract song external_id from asset external_id: asset-stub-{song-slug}-v{n}-{timestamp}
    const songSlugMatch = stub.external_id.match(/^asset-stub-(.+)-v\d+-\d+$/);
    const songExtId = songSlugMatch?.[1] ?? "unknown";

    // Find the source file
    const filePath = fileIndex.get(origName)
      ?? fileIndex.get(origName.toLowerCase())
      ?? fileIndex.get(normName)
      ?? fileIndex.get(normName.toLowerCase());

    if (!filePath) {
      skipped++;
      continue;
    }
    matched++;

    process.stdout.write(`  ↑ ${origName.slice(0, 60).padEnd(60)} `);
    const ok = await uploadAsset(stub.asset_id, stub.external_id, filePath, songExtId);
    if (ok) {
      uploaded++;
      console.log("✓");
    } else {
      console.log("✗");
    }
  }

  console.log(`\n✓ Done. ${uploaded}/${matched} uploaded, ${skipped} no source match.`);
}

main().catch((err) => { console.error("\n✗ Fatal:", err); process.exit(1); });
