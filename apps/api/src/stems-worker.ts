import { spawn, execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import type { FileAsset, Song, Version } from "@pmw/shared";
import {
  STEM_NAMES,
  isLiveStemJobState,
  mapDemucsProgress,
  parseDemucsProgress,
  stemsZipKey,
  type StemJob,
} from "./stems";
import { store } from "./store";
import { getSupabase } from "./supabase";
import { signPlaybackUrl } from "./uploads";

/**
 * Demucs stem-splitting worker. Local-only by design: the deployed Render box
 * can't run demucs, so everything here is gated behind STEMS_ENABLED=1 and the
 * split endpoint degrades to 503 when the gate is closed.
 *
 * Pipeline per job (concurrency 1, FIFO):
 *   download source → demucs (htdemucs, 4 stems, mp3) → zip via `zip` CLI →
 *   upload zip to the existing wl-audio bucket → persist key_stems_zip on the
 *   file_assets row → done. Tmp dir is removed on success AND failure.
 */

const BUCKET = "wl-audio";
const JOB_TIMEOUT_MS = 20 * 60 * 1000; // 20 minutes per job

export function isStemsWorkerEnabled(): boolean {
  return process.env.STEMS_ENABLED === "1";
}

function demucsPython(): string {
  return process.env.DEMUCS_PYTHON ?? "python3";
}

const queue: StemJob[] = [];
let running = false;

export function enqueueStemJob(input: { song: Song; version: Version; asset: FileAsset }): StemJob {
  const job: StemJob = {
    id: `stj-${randomUUID()}`,
    song_id: input.song.song_id,
    version_id: input.version.version_id,
    asset_id: input.asset.asset_id,
    state: "queued",
    progress: 0,
    started_at: new Date().toISOString(),
  };
  store.stemJobs.set(job.id, job);
  queue.push(job);
  void pump();
  return job;
}

export function liveStemJobForVersionOrAsset(versionID: string, assetID: string): StemJob | undefined {
  for (const job of store.stemJobs.values()) {
    if (!isLiveStemJobState(job.state)) continue;
    if (job.version_id === versionID || job.asset_id === assetID) return job;
  }
  return undefined;
}

export function latestStemJobForVersion(versionID: string): StemJob | undefined {
  let latest: StemJob | undefined;
  for (const job of store.stemJobs.values()) {
    if (job.version_id !== versionID) continue;
    if (!latest || job.started_at >= latest.started_at) latest = job;
  }
  return latest;
}

async function pump(): Promise<void> {
  if (running) return;
  const job = queue.shift();
  if (!job) return;
  running = true;
  try {
    await runJob(job);
  } finally {
    running = false;
    void pump();
  }
}

function fail(job: StemJob, message: string): void {
  job.state = "failed";
  job.error = message;
  job.finished_at = new Date().toISOString();
  console.warn(`[stems] job ${job.id} failed: ${message}`);
}

async function runJob(job: StemJob): Promise<void> {
  const deadline = Date.now() + JOB_TIMEOUT_MS;
  let tmp: string | null = null;
  try {
    job.state = "processing";
    job.progress = 0.01;

    const asset = store.data.assets.find((a) => a.asset_id === job.asset_id);
    if (!asset) return fail(job, "asset not found");

    // Resolve the source audio URL the same way playback does: a real
    // storage object either carries an absolute public playback_url or is
    // signed from key_original. Seed-relative paths (/seed-audio/…) aren't
    // reachable from the API process — refuse those honestly.
    let sourceUrl: string;
    if (asset.playback_url && /^https?:\/\//i.test(asset.playback_url)) {
      sourceUrl = asset.playback_url;
    } else if (asset.key_original && !asset.key_original.startsWith("originals/")) {
      sourceUrl = await signPlaybackUrl(asset.key_original);
    } else {
      return fail(job, "source audio is not in storage (seed-only asset)");
    }

    tmp = await mkdtemp(join(tmpdir(), "stems-"));
    const ext = extensionFor(asset, sourceUrl);
    const inputPath = join(tmp, `input${ext}`);
    await downloadTo(sourceUrl, inputPath);
    job.progress = 0.05;

    // demucs htdemucs → 4 mp3 stems under <tmp>/out/htdemucs/input/
    await runDemucs(job, inputPath, join(tmp, "out"), deadline);
    job.progress = 0.85;

    const stemsDir = join(tmp, "out", "htdemucs", "input");
    const produced = await readdir(stemsDir);
    const stems = STEM_NAMES.map((n) => `${n}.mp3`).filter((f) => produced.includes(f));
    if (stems.length !== STEM_NAMES.length) {
      return fail(job, `demucs produced ${stems.length}/4 stems (${produced.join(", ")})`);
    }

    // zip CLI ships with macOS and the Render Linux base image — zero new deps.
    const zipPath = join(tmp, "stems.zip");
    await execFileAsync("zip", ["-j", "-q", zipPath, ...stems.map((f) => join(stemsDir, f))]);

    job.state = "uploading";
    job.progress = 0.9;
    const song = store.data.songs.find((s) => s.song_id === job.song_id);
    const key = stemsZipKey(song?.song_id ?? job.song_id, job.version_id);
    await uploadZip(zipPath, key);
    job.progress = 0.95;

    await persistStemsKey(asset.asset_id, key);
    store.setAssetStemsKey(asset.asset_id, key);

    job.stems_key = key;
    job.state = "done";
    job.progress = 1;
    job.finished_at = new Date().toISOString();
    console.log(`[stems] job ${job.id} done → ${key}`);
  } catch (err) {
    fail(job, err instanceof Error ? err.message : String(err));
  } finally {
    if (tmp) await rm(tmp, { recursive: true, force: true }).catch(() => undefined);
  }
}

function extensionFor(asset: FileAsset, sourceUrl: string): string {
  const fromKey = asset.key_original?.match(/(\.[A-Za-z0-9]{2,5})$/)?.[1];
  if (fromKey) return fromKey.toLowerCase();
  const fromUrl = sourceUrl.split("?")[0].match(/(\.[A-Za-z0-9]{2,5})$/)?.[1];
  if (fromUrl) return fromUrl.toLowerCase();
  if (asset.mime_type?.includes("wav")) return ".wav";
  if (asset.mime_type?.includes("flac")) return ".flac";
  if (asset.mime_type?.includes("mp4") || asset.mime_type?.includes("m4a")) return ".m4a";
  return ".mp3";
}

async function downloadTo(url: string, destination: string): Promise<void> {
  const res = await fetch(url);
  if (!res.ok || !res.body) throw new Error(`source download failed (${res.status})`);
  await pipeline(Readable.fromWeb(res.body as never), createWriteStream(destination));
}

function execFileAsync(cmd: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, (err, _stdout, stderr) => {
      if (err) reject(new Error(`${cmd} failed: ${stderr || err.message}`));
      else resolve();
    });
  });
}

/** Spawn demucs and stream tqdm stderr into job.progress (0.05–0.85). */
function runDemucs(job: StemJob, inputPath: string, outDir: string, deadline: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(
      demucsPython(),
      ["-m", "demucs", "--mp3", "-n", "htdemucs", "-o", outDir, inputPath],
      { stdio: ["ignore", "pipe", "pipe"] },
    );
    let stderrTail = "";
    let settled = false;
    const timer = setInterval(() => {
      if (Date.now() > deadline && !settled) {
        settled = true;
        clearInterval(timer);
        child.kill("SIGKILL");
        reject(new Error("demucs timed out (20 min limit)"));
      }
    }, 5_000);
    child.stderr.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8");
      stderrTail = (stderrTail + text).slice(-2000);
      const frac = parseDemucsProgress(text);
      if (frac !== null) {
        const next = mapDemucsProgress(frac);
        if (next > job.progress) job.progress = next;
      }
    });
    child.on("error", (err) => {
      if (settled) return;
      settled = true;
      clearInterval(timer);
      reject(new Error(`could not spawn demucs (${demucsPython()}): ${err.message}`));
    });
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      clearInterval(timer);
      if (code === 0) resolve();
      else reject(new Error(`demucs exited ${code}: ${stderrTail.split("\n").slice(-4).join(" ").slice(-300)}`));
    });
  });
}

async function uploadZip(zipPath: string, key: string): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) throw new Error("Supabase not configured");
  const body = await readFile(zipPath);
  const { error } = await supabase.storage
    .from(BUCKET)
    .upload(key, body, { contentType: "application/zip", upsert: true });
  if (error) throw new Error(`stems zip upload failed: ${error.message}`);
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Persist key_stems_zip to Supabase. Assets hydrated from the DB use the
 * file_assets.external_id as their in-memory asset_id (falling back to the
 * row uuid when external_id is null) — try external_id first, then the uuid.
 */
async function persistStemsKey(assetID: string, key: string): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) throw new Error("Supabase not configured");
  const byExternal = await supabase
    .from("file_assets")
    .update({ key_stems_zip: key })
    .eq("external_id", assetID)
    .select("asset_id");
  if (!byExternal.error && (byExternal.data?.length ?? 0) > 0) return;
  if (UUID_RE.test(assetID)) {
    const byUuid = await supabase
      .from("file_assets")
      .update({ key_stems_zip: key })
      .eq("asset_id", assetID)
      .select("asset_id");
    if (!byUuid.error && (byUuid.data?.length ?? 0) > 0) return;
    if (byUuid.error) throw new Error(`key_stems_zip persist failed: ${byUuid.error.message}`);
  }
  if (byExternal.error) throw new Error(`key_stems_zip persist failed: ${byExternal.error.message}`);
  throw new Error(`key_stems_zip persist failed: no file_assets row matched ${assetID}`);
}
