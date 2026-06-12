import { describe, expect, it } from "vitest";
import {
  isLiveStemJob,
  isStemsWorkerOfflineError,
  stemControlView,
  stemSplitPct,
  type StemJob,
} from "../stems";

function job(state: StemJob["state"], progress = 0.43): StemJob {
  return {
    id: "stj-1",
    song_id: "song-x",
    version_id: "ver-x",
    asset_id: "asset-x",
    state,
    progress,
    started_at: "2026-06-11T00:00:00.000Z",
  };
}

describe("stemSplitPct", () => {
  it("rounds 0–1 progress to a percent", () => {
    expect(stemSplitPct(0.43)).toBe(43);
    expect(stemSplitPct(0)).toBe(0);
  });
  it("clamps live display at 99 and handles out-of-range", () => {
    expect(stemSplitPct(1)).toBe(99);
    expect(stemSplitPct(1.5)).toBe(99);
    expect(stemSplitPct(-0.2)).toBe(0);
  });
});

describe("stemControlView", () => {
  it("idle when no stems, no job, worker reachable", () => {
    expect(stemControlView({ hasStems: false, job: null, workerOffline: false }))
      .toEqual({ kind: "idle", label: "SPLIT STEMS" });
  });

  it("live with a SPLITTING · pct label for queued/processing/uploading", () => {
    for (const state of ["queued", "processing", "uploading"] as const) {
      const view = stemControlView({ hasStems: false, job: job(state, 0.43), workerOffline: false });
      expect(view).toEqual({ kind: "live", label: "SPLITTING · 43%", pct: 43 });
      expect(isLiveStemJob(state)).toBe(true);
    }
  });

  it("ready when the asset already has stems — even with a stale failed job", () => {
    expect(stemControlView({ hasStems: true, job: job("failed"), workerOffline: false }).kind).toBe("ready");
  });

  it("ready as soon as the job reports done (before the asset refreshes)", () => {
    expect(stemControlView({ hasStems: false, job: job("done", 1), workerOffline: false }).kind).toBe("ready");
  });

  it("failed shows the redline retry", () => {
    expect(stemControlView({ hasStems: false, job: job("failed"), workerOffline: false }))
      .toEqual({ kind: "failed", label: "SPLIT FAILED — RETRY" });
  });

  it("offline (prod 503) disables the control quietly", () => {
    expect(stemControlView({ hasStems: false, job: null, workerOffline: true }))
      .toEqual({ kind: "offline", label: "STEMS WORKER OFFLINE" });
  });
});

describe("isStemsWorkerOfflineError", () => {
  it("matches the API's 503 message", () => {
    expect(isStemsWorkerOfflineError(new Error("stems worker unavailable on this deployment"))).toBe(true);
  });
  it("does not match other failures", () => {
    expect(isStemsWorkerOfflineError(new Error("Version not found"))).toBe(false);
    expect(isStemsWorkerOfflineError(undefined)).toBe(false);
  });
});
