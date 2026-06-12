/**
 * Stem-splitting — pure helpers + job model. No I/O in this module so the
 * whole thing is unit-testable without ever spawning demucs. The side-effectful
 * pipeline lives in stems-worker.ts.
 */

export type StemJobState = "queued" | "processing" | "uploading" | "done" | "failed";

export interface StemJob {
  id: string;
  song_id: string;
  version_id: string;
  asset_id: string;
  state: StemJobState;
  /** 0–1. Demucs model passes map to 0.05–0.85; upload takes it to ~0.95. */
  progress: number;
  error?: string;
  started_at: string;
  finished_at?: string;
  stems_key?: string;
}

/** A job still occupying the queue/worker — i.e. blocks a duplicate POST. */
export function isLiveStemJobState(state: StemJobState): boolean {
  return state === "queued" || state === "processing" || state === "uploading";
}

/**
 * Parse a chunk of demucs stderr into the latest model-pass fraction (0–1).
 * Demucs prints tqdm bars like:
 *
 *   "  5%|▌         | 3.6/70.2 [00:02<00:39,  1.70seconds/s]"
 *
 * separated by \r on a live tty. Returns the LAST percentage found in the
 * chunk, or null when the chunk carries no progress info.
 */
export function parseDemucsProgress(chunk: string): number | null {
  let latest: number | null = null;
  const re = /(\d{1,3}(?:\.\d+)?)%\|/g;
  for (const line of chunk.split(/[\r\n]+/)) {
    let m: RegExpExecArray | null;
    while ((m = re.exec(line)) !== null) {
      const pct = Number(m[1]);
      if (Number.isFinite(pct) && pct >= 0 && pct <= 100) latest = pct / 100;
    }
    re.lastIndex = 0;
  }
  return latest;
}

/** Map a demucs model-pass fraction (0–1) into the job's 0.05–0.85 window. */
export function mapDemucsProgress(frac: number): number {
  const clamped = Math.max(0, Math.min(1, frac));
  return Number((0.05 + clamped * 0.8).toFixed(4));
}

/** Storage key convention for a version's stems zip (mirrors wl-audio paths). */
export function stemsZipKey(songExternalId: string, versionId: string): string {
  const song = songExternalId.replace(/[^\w-]+/g, "_");
  const version = versionId.replace(/[^\w.-]+/g, "_");
  return `stems/${song}/${version}.zip`;
}

/** The four htdemucs stem names, in zip order. */
export const STEM_NAMES = ["vocals", "drums", "bass", "other"] as const;
