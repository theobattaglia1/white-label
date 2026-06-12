/**
 * Stem-splitting — pure client-side helpers for the versions-panel control.
 * Mirrors the API's StemJob shape (apps/api/src/stems.ts); kept logic-only so
 * it's unit-testable without React.
 */

export type StemJobState = "queued" | "processing" | "uploading" | "done" | "failed";

export type StemJob = {
  id: string;
  song_id: string;
  version_id: string;
  asset_id: string;
  state: StemJobState;
  progress: number; // 0–1
  error?: string;
  started_at: string;
  finished_at?: string;
  stems_key?: string;
};

export function isLiveStemJob(state: StemJobState): boolean {
  return state === "queued" || state === "processing" || state === "uploading";
}

/** Round a 0–1 job progress to a display percent, clamped to 0–99 while live
 *  (100 is reserved for the done state so the label never lies). */
export function stemSplitPct(progress: number): number {
  const pct = Math.round(Math.max(0, Math.min(1, progress)) * 100);
  return Math.min(pct, 99);
}

export type StemControlView =
  | { kind: "ready"; label: "STEMS ✓" }
  | { kind: "live"; label: string; pct: number }
  | { kind: "failed"; label: "SPLIT FAILED — RETRY" }
  | { kind: "offline"; label: "STEMS WORKER OFFLINE" }
  | { kind: "idle"; label: "SPLIT STEMS" };

/** Single source of truth for which control the version row shows. */
export function stemControlView(input: {
  hasStems: boolean;
  job: StemJob | null;
  workerOffline: boolean;
}): StemControlView {
  if (input.hasStems || input.job?.state === "done") return { kind: "ready", label: "STEMS ✓" };
  if (input.job && isLiveStemJob(input.job.state)) {
    const pct = stemSplitPct(input.job.progress);
    return { kind: "live", label: `SPLITTING · ${pct}%`, pct };
  }
  if (input.job?.state === "failed") return { kind: "failed", label: "SPLIT FAILED — RETRY" };
  if (input.workerOffline) return { kind: "offline", label: "STEMS WORKER OFFLINE" };
  return { kind: "idle", label: "SPLIT STEMS" };
}

/** The API's honest prod degradation: 503 {error:"stems worker unavailable…"}. */
export function isStemsWorkerOfflineError(err: unknown): boolean {
  const message = err instanceof Error ? err.message : String(err ?? "");
  return /stems worker unavailable/i.test(message);
}
