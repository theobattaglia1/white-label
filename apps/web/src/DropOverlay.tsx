/**
 * DropZone (DropOverlay.tsx — named to dodge a case-insensitive-FS clash
 * with dropzone.ts) — window-wide drag-and-drop upload with the ambient
 * dot-field overlay. Thin React shell over the pure logic in dropzone.ts:
 *
 *   drag files over the window → full-viewport #0c0907 overlay with the
 *   iOS AmbientDotField ported to <canvas> (cream dots, slow traveling
 *   pressure wave that breathes faster while files hover) → on drop, a
 *   radial pulse emanates from the drop point through the grid, then the
 *   overlay collapses into a quiet bottom progress strip. Never a modal,
 *   never blocks the app.
 *
 * Dev hook (import.meta.env.DEV only):
 *   window.__pbSimulateDrop(files: File[], folderName?: string)
 *   → Promise<BatchOutcome> — runs the exact same ingestion path end-to-end
 *   (overlay, pulse, uploads, refresh, closing notice) from the console.
 */
import { useEffect, useRef, useState } from "react";
import { api, uploadNewSong } from "./api";
import {
  cleanSongTitle,
  collectAudioEntries,
  describeDragItems,
  isAudioFile,
  planIngestion,
  runWithConcurrency,
  shouldReactToDrag,
  summarizeBatch,
  type BatchOutcome,
  type DroppedEntry,
  type IngestionPlan,
} from "./dropzone";

// --- Dot-field constants (ported from apps/ios .../AmbientDotField.swift) ---
const SPACING = 22;        // px between dot centres
const BASE_RADIUS = 1.4;
const PEAK_RADIUS = 3.2;
const PEAK_OPACITY = 0.34; // hotter than the iOS backdrop (0.16) — this is the hero
const DOT_RGB = "243, 236, 222"; // cream (#F3ECDE-ish, matches iOS 0.953/0.925/0.871)
const PULSE_SPEED = 850;   // px/s radial wavefront
const PULSE_SECONDS = 1.4;
const PULSE_SIGMA = 64;    // wavefront thickness

type Phase = "idle" | "hover" | "pulse" | "uploading";

type StripState = {
  done: number;
  total: number;
  current: string;
  pct: number; // 0-100 overall
};

function prefersReducedMotion(): boolean {
  return typeof window.matchMedia === "function"
    && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

export function DropZone({ onBatchComplete }: { onBatchComplete?: () => void }) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [dragLine, setDragLine] = useState<string | null>(null);
  const [emptyNotice, setEmptyNotice] = useState(false);
  const [strip, setStrip] = useState<StripState | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const phaseRef = useRef<Phase>("idle");
  phaseRef.current = phase;

  // Animation state lives in refs so the rAF loop survives re-renders and
  // phase transitions without losing wave continuity.
  const wave1Ref = useRef(Math.random() * 20);
  const wave2Ref = useRef(Math.random() * 20);
  const excitementRef = useRef(0);
  const pulseRef = useRef<{ x: number; y: number; start: number } | null>(null);
  const pctByFileRef = useRef<Map<string, number>>(new Map());
  const noticeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const busyRef = useRef(false);

  const overlayVisible = phase === "hover" || phase === "pulse" || emptyNotice;

  // ---------------------------------------------------------------------
  // Ingestion pipeline — shared by real drops and __pbSimulateDrop
  // ---------------------------------------------------------------------
  async function runIngestion(
    entries: DroppedEntry[],
    skipped: number,
    point: { x: number; y: number },
  ): Promise<BatchOutcome> {
    const reduce = prefersReducedMotion();

    if (entries.length === 0) {
      // Zero audio — quiet, charming, gone.
      setEmptyNotice(true);
      setPhase("idle");
      await new Promise((r) => setTimeout(r, 1700));
      setEmptyNotice(false);
      return { added: 0, playlists: [], skipped, failed: [] };
    }

    // Radial pulse from the actual drop coordinates, then collapse to strip.
    pulseRef.current = { x: point.x, y: point.y, start: performance.now() };
    setPhase("pulse");
    const collapseMs = reduce ? 120 : 1300;
    const collapse = setTimeout(() => {
      setPhase((p) => (p === "pulse" ? "uploading" : p));
    }, collapseMs);

    const plan = planIngestion(entries);
    const outcome = await executePlan(plan, skipped);

    clearTimeout(collapse);
    setPhase("idle");
    setStrip(null);
    pulseRef.current = null;

    setNotice(summarizeBatch(outcome));
    if (noticeTimerRef.current) clearTimeout(noticeTimerRef.current);
    noticeTimerRef.current = setTimeout(() => setNotice(null), 4200);

    onBatchComplete?.();
    return outcome;
  }

  async function executePlan(plan: IngestionPlan, skipped: number): Promise<BatchOutcome> {
    type Job = { file: File; playlist: string | null };
    const jobs: Job[] = [
      ...plan.libraryAdds.map((file) => ({ file, playlist: null })),
      ...plan.playlists.flatMap((pl) => pl.files.map((file) => ({ file, playlist: pl.name }))),
    ];
    const total = jobs.length;
    const failed: string[] = [];
    let done = 0;
    pctByFileRef.current = new Map();

    const updateStrip = (current: string) => {
      let sum = 0;
      pctByFileRef.current.forEach((v) => { sum += v; });
      setStrip({
        done,
        total,
        current,
        pct: total === 0 ? 100 : Math.min(100, sum / total),
      });
    };

    // Concurrency-limited uploads (2 at a time); order preserved.
    const songIDs = await runWithConcurrency(jobs, 2, async (job) => {
      updateStrip(job.file.name);
      try {
        const res = await uploadNewSong(
          job.file,
          { title: cleanSongTitle(job.file.name) },
          (pct) => {
            pctByFileRef.current.set(job.file.name, pct);
            updateStrip(job.file.name);
          },
        );
        return res.songExternalId;
      } catch (err) {
        console.error("Drop upload failed:", job.file.name, err);
        failed.push(job.file.name);
        pctByFileRef.current.set(job.file.name, 100);
        return null;
      } finally {
        done += 1;
        updateStrip(job.file.name);
      }
    });

    // One dropped folder → one playlist, songs added in filename order.
    const playlistsCreated: string[] = [];
    for (const pl of plan.playlists) {
      const ids = jobs
        .map((job, i) => (job.playlist === pl.name ? songIDs[i] : null))
        .filter((id): id is string => id !== null);
      if (ids.length === 0) continue;
      try {
        const created = await api.createPlaylist({ workspace_id: "wsp-amf-private", title: pl.name });
        for (const songID of ids) {
          await api.addToPlaylist(created.playlist_id, { song_id: songID });
        }
        playlistsCreated.push(pl.name);
      } catch (err) {
        console.error("Playlist creation failed:", pl.name, err);
      }
    }

    return {
      added: songIDs.filter((id) => id !== null).length,
      playlists: playlistsCreated,
      skipped,
      failed,
    };
  }

  // ---------------------------------------------------------------------
  // Window-level drag listeners (depth counter beats dragleave flicker)
  // ---------------------------------------------------------------------
  useEffect(() => {
    let depth = 0;

    const onDragEnter = (e: DragEvent) => {
      if (!shouldReactToDrag(e.dataTransfer?.types)) return;
      e.preventDefault();
      depth += 1;
      if (busyRef.current) return;
      const kinds = e.dataTransfer?.items
        ? Array.from(e.dataTransfer.items).map((it) => it.kind)
        : null;
      setDragLine(describeDragItems(kinds));
      setPhase((p) => (p === "idle" ? "hover" : p));
    };

    const onDragOver = (e: DragEvent) => {
      if (!shouldReactToDrag(e.dataTransfer?.types)) return;
      e.preventDefault();
      if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
    };

    const onDragLeave = (e: DragEvent) => {
      if (!shouldReactToDrag(e.dataTransfer?.types)) return;
      depth = Math.max(0, depth - 1);
      if (depth === 0) setPhase((p) => (p === "hover" ? "idle" : p));
    };

    const onDrop = (e: DragEvent) => {
      if (!shouldReactToDrag(e.dataTransfer?.types)) return;
      e.preventDefault();
      depth = 0;
      if (busyRef.current || !e.dataTransfer) {
        setPhase((p) => (p === "hover" ? "idle" : p));
        return;
      }
      busyRef.current = true;
      const point = { x: e.clientX, y: e.clientY };
      // webkitGetAsEntry is grabbed synchronously inside collectAudioEntries.
      void collectAudioEntries(e.dataTransfer)
        .then(({ entries, skipped }) => runIngestion(entries, skipped, point))
        .catch((err) => {
          console.error("Drop ingestion failed:", err);
          setPhase("idle");
          setStrip(null);
        })
        .finally(() => { busyRef.current = false; });
    };

    window.addEventListener("dragenter", onDragEnter);
    window.addEventListener("dragover", onDragOver);
    window.addEventListener("dragleave", onDragLeave);
    window.addEventListener("drop", onDrop);
    return () => {
      window.removeEventListener("dragenter", onDragEnter);
      window.removeEventListener("dragover", onDragOver);
      window.removeEventListener("dragleave", onDragLeave);
      window.removeEventListener("drop", onDrop);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ---------------------------------------------------------------------
  // Dev hook — synthetic drops from the console / orchestrator
  // ---------------------------------------------------------------------
  useEffect(() => {
    if (!import.meta.env.DEV) return;
    (window as unknown as Record<string, unknown>).__pbSimulateDrop = async (
      files: File[],
      folderName?: string,
    ): Promise<BatchOutcome> => {
      if (busyRef.current) throw new Error("__pbSimulateDrop: a drop is already in flight");
      busyRef.current = true;
      try {
        const entries: DroppedEntry[] = files
          .filter((f) => isAudioFile(f.name))
          .map((file) => ({ file, folderName: folderName ?? null }));
        const skipped = files.length - entries.length;
        setDragLine(describeDragItems(files.map(() => "file")));
        setPhase("hover");
        await new Promise((r) => setTimeout(r, prefersReducedMotion() ? 50 : 650));
        return await runIngestion(entries, skipped, {
          x: window.innerWidth / 2,
          y: window.innerHeight / 2,
        });
      } finally {
        busyRef.current = false;
      }
    };
    return () => {
      delete (window as unknown as Record<string, unknown>).__pbSimulateDrop;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ---------------------------------------------------------------------
  // Ambient dot field — canvas port of the iOS Swift implementation
  // ---------------------------------------------------------------------
  useEffect(() => {
    if (!overlayVisible) return;
    const canvas = canvasRef.current;
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx) return;

    const reduce = prefersReducedMotion();
    let raf = 0;
    let last = performance.now();

    const resize = () => {
      const dpr = window.devicePixelRatio || 1;
      canvas.width = Math.round(window.innerWidth * dpr);
      canvas.height = Math.round(window.innerHeight * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };
    resize();
    window.addEventListener("resize", resize);

    const render = (now: number) => {
      const w = window.innerWidth;
      const h = window.innerHeight;
      ctx.clearRect(0, 0, w, h);

      const cols = Math.ceil(w / SPACING) + 2;
      const rows = Math.ceil(h / SPACING) + 2;
      const e = excitementRef.current;
      // While files hover the field breathes faster and harder.
      const amp = 1.0 + e * 0.85;
      const rRange = PEAK_RADIUS - BASE_RADIUS;
      const p1 = wave1Ref.current;
      const p2 = wave2Ref.current;

      const pulse = pulseRef.current;
      let pulseR = -1;
      let pulseDecay = 0;
      if (pulse) {
        const elapsed = (now - pulse.start) / 1000;
        if (elapsed <= PULSE_SECONDS) {
          pulseR = elapsed * PULSE_SPEED;
          pulseDecay = 1 - elapsed / PULSE_SECONDS;
        }
      }

      ctx.fillStyle = `rgb(${DOT_RGB})`;
      for (let row = 0; row < rows; row++) {
        for (let col = 0; col < cols; col++) {
          const cx = col * SPACING;
          const cy = row * SPACING;
          // Product of two slow sine planes = a localized crest that travels
          // without repeating; square it so valleys stay invisible.
          const w1 = Math.sin(col * 0.28 + row * 0.19 + p1);
          const w2 = Math.cos(col * 0.15 + row * 0.32 + p2);
          const clamped = Math.max(0, w1 * w2);
          let norm = Math.min(1, clamped * clamped * amp);

          if (pulseR >= 0) {
            const d = Math.hypot(cx - pulse!.x, cy - pulse!.y) - pulseR;
            norm = Math.min(1, norm + Math.exp(-(d * d) / (2 * PULSE_SIGMA * PULSE_SIGMA)) * pulseDecay);
          }

          if (norm < 0.02) continue; // valleys: skip the fill entirely
          const r = BASE_RADIUS + norm * rRange;
          ctx.globalAlpha = norm * PEAK_OPACITY;
          ctx.beginPath();
          ctx.arc(cx, cy, r, 0, Math.PI * 2);
          ctx.fill();
        }
      }
      ctx.globalAlpha = 1;
    };

    const tick = (now: number) => {
      const dt = Math.min(0.1, (now - last) / 1000);
      last = now;
      // Ease the excitement toward its target so amplitude/speed ramp subtly.
      const target = phaseRef.current === "hover" ? 1 : 0.3;
      excitementRef.current += (target - excitementRef.current) * Math.min(1, dt * 2.5);
      // Integrate phase (not t × speed) so speed changes never jump the wave.
      const speedBoost = 1 + excitementRef.current * 1.3;
      wave1Ref.current += dt * 0.31 * speedBoost;
      wave2Ref.current += dt * 0.24 * speedBoost;
      render(now);
      raf = requestAnimationFrame(tick);
    };

    if (reduce) {
      // Static dots — a single calm frame, no wave, no pulse.
      pulseRef.current = null;
      render(performance.now());
    } else {
      raf = requestAnimationFrame(tick);
    }

    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", resize);
    };
  }, [overlayVisible]);

  // ---------------------------------------------------------------------
  // Render — overlay never intercepts pointer events; window handles drops
  // ---------------------------------------------------------------------
  return (
    <>
      {overlayVisible && (
        <div className="dropzone-overlay" data-phase={phase} aria-hidden="true">
          <canvas ref={canvasRef} className="dropzone-canvas" />
          <div className="dropzone-center">
            {emptyNotice ? (
              <h2 className="dropzone-headline">Nothing I can play here</h2>
            ) : (
              <>
                <h2 className="dropzone-headline">Drop to add to your library</h2>
                <p className="dropzone-subline">
                  {dragLine ?? "A folder becomes a playlist"}
                </p>
              </>
            )}
          </div>
        </div>
      )}
      {phase === "uploading" && strip && (
        <div className="dropzone-strip" role="status">
          <span className="dropzone-strip-label">
            Uploading {Math.min(strip.done + 1, strip.total)} of {strip.total} · {strip.current}
          </span>
          <div className="dropzone-strip-bar">
            <div style={{ width: `${strip.pct}%` }} />
          </div>
        </div>
      )}
      {notice && (
        <div className="dropzone-notice" role="status">{notice}</div>
      )}
    </>
  );
}
