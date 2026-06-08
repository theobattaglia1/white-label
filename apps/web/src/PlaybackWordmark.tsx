import { useEffect, useId, useRef } from "react";

/* =====================================================================
   PLAYBACK wordmark — web port of apps/ios/.../PlaybackWordmark.swift.

   The leading "P" is a circular cap (the AMF fader-knob turned playhead).
   It rides into the word, sitting slightly over the "L", oscillating on a
   4.4s cosine clock. The P is ALWAYS animating — no pause/dock state.

   Genealogy: AMF's mark is a mixing console — circular Helvetica caps in
   pill tracks, looping forever (mixing has no end). PLAYBACK reuses the
   cap, turned on its side, and it can *stop* — because you play a thing
   back.

   Motion is driven by requestAnimationFrame writing `transform` straight
   to the cap node (no React state per frame) so a wordmark on a busy
   screen never re-renders the tree.
   ===================================================================== */

type Size = "sm" | "md" | "lg";

const SIZES: Record<Size, { font: number; cap: number }> = {
  sm: { font: 18, cap: 17 },
  md: { font: 28, cap: 26 },
  lg: { font: 48, cap: 44 },
};

const PERIOD = 4.4; // seconds for one in-and-out cycle (matches iOS)

/** The circular playhead cap. `knockout` cuts the P out of the disc so the
 *  surface shows through (used as the standalone monogram on varied
 *  surfaces); otherwise it's the iOS knob treatment — cream disc, black P. */
function PlayheadCap({ px, knockout = false }: { px: number; knockout?: boolean }) {
  const id = useId();
  if (knockout) {
    return (
      <svg width={px} height={px} viewBox="0 0 100 100" className="pb-cap-svg" aria-hidden="true">
        <mask id={id}>
          <rect width="100" height="100" fill="white" />
          <text
            x="50"
            y="52"
            textAnchor="middle"
            dominantBaseline="central"
            fontFamily="'Helvetica Neue', Helvetica, Arial, sans-serif"
            fontWeight="700"
            fontSize="52"
            fill="black"
          >
            P
          </text>
        </mask>
        <circle cx="50" cy="50" r="50" fill="currentColor" mask={`url(#${id})`} />
      </svg>
    );
  }
  return (
    <svg width={px} height={px} viewBox="0 0 100 100" className="pb-cap-svg" aria-hidden="true">
      <circle cx="50" cy="50" r="50" className="pb-cap-fill" />
      <text
        x="50"
        y="52"
        textAnchor="middle"
        dominantBaseline="central"
        fontFamily="'Helvetica Neue', Helvetica, Arial, sans-serif"
        fontWeight="700"
        fontSize="52"
        className="pb-cap-letter"
      >
        P
      </text>
    </svg>
  );
}

/** The standalone playhead monogram (replaces the old "WL" MonoMark). */
export function PlaybackMark({ size = 22 }: { size?: number }) {
  return (
    <span className="pb-mark" style={{ width: size, height: size }} aria-label="Playback" role="img">
      <PlayheadCap px={size} knockout />
    </span>
  );
}

export function PlaybackWordmark({ size = "md", title, isPlaying = false }: { size?: Size; title?: string; isPlaying?: boolean }) {
  const { font, cap } = SIZES[size];
  const travel = cap * 0.38;
  const pad = cap * 0.16;

  const capRef = useRef<HTMLSpanElement>(null);
  const startRef = useRef<number | null>(null);
  const rafRef = useRef<number>(0);

  // State-bound motion: rAF runs while isPlaying; parks at the dock when stopped.
  // The playhead moves when audio plays and stops when it stops — same thesis as iOS.
  useEffect(() => {
    const node = capRef.current;
    if (!node) return;

    if (!isPlaying) {
      // Park — ease the P to the dock position (over the L) and hold.
      cancelAnimationFrame(rafRef.current);
      node.style.willChange = "";
      node.style.transition = "transform 0.55s ease-in-out";
      node.style.transform = `translateX(${travel}px)`;
      return;
    }

    // Playing — restart cycle from the dock so the P glides out smoothly.
    startRef.current = null;
    node.style.transition = "none";
    node.style.willChange = "transform";
    const tick = (now: number) => {
      if (startRef.current == null) startRef.current = now;
      const t = (now - startRef.current) / 1000;
      const phase = (t % PERIOD) / PERIOD;
      const x = (travel * (1 + Math.cos(2 * Math.PI * phase))) / 2;
      node.style.transform = `translateX(${x}px)`;
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(rafRef.current);
      node.style.willChange = "";
    };
  }, [isPlaying, travel]);

  return (
    <span
      className={`pb-wordmark pb-wordmark-${size}`}
      title={title}
      aria-label={isPlaying ? "Playback — playing" : "Playback — stopped"}
      role="img"
      style={{ ["--pb-font" as string]: `${font}px`, ["--pb-pad" as string]: `${pad}px` }}
    >
      <span
        ref={capRef}
        className="pb-cap"
        style={{ transform: `translateX(${travel}px)` }}
        aria-hidden="true"
      >
        <PlayheadCap px={cap} />
      </span>
      <span className="pb-word" aria-hidden="true">
        LAYBACK
      </span>
    </span>
  );
}
