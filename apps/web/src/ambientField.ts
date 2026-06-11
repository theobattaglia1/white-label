/**
 * ambientField.ts — the ONE ambient dot-field implementation.
 *
 * Canvas port of apps/ios .../AmbientDotField.swift: a grid of cream dots
 * whose radii ride the product of two slow sine planes — a localized crest
 * that travels without repeating. Radial pressure pulses (a drop, a
 * sign-in, a keystroke) propagate through the grid as a gaussian wavefront.
 *
 * Shared by DropOverlay.tsx (hero brightness, full frame rate, drop pulse)
 * and SignIn.tsx (low amplitude, ~13fps, typing ripples + entry pulse).
 * One implementation, parametrized — never copy-pasted.
 */

// --- Dot-field constants (ported from apps/ios .../AmbientDotField.swift) ---
export const SPACING = 22;        // px between dot centres
export const BASE_RADIUS = 1.4;
export const PEAK_RADIUS = 3.2;
export const PEAK_OPACITY = 0.34; // hotter than the iOS backdrop (0.16) — this is the hero
export const DOT_RGB = "243, 236, 222"; // cream (#F3ECDE-ish, matches iOS 0.953/0.925/0.871)
export const PULSE_SPEED = 850;   // px/s radial wavefront
export const PULSE_SECONDS = 1.4;
export const PULSE_SIGMA = 64;    // wavefront thickness

export function prefersReducedMotion(): boolean {
  return typeof window.matchMedia === "function"
    && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

export type PulseOptions = {
  /** px/s wavefront speed (default: drop-overlay PULSE_SPEED). */
  speed?: number;
  /** lifetime in seconds (default: PULSE_SECONDS). */
  seconds?: number;
  /** wavefront thickness (default: PULSE_SIGMA). */
  sigma?: number;
  /** peak contribution 0..1 — 1 is the full drop pulse (default: 1). */
  strength?: number;
};

type ActivePulse = Required<PulseOptions> & { x: number; y: number; start: number };

export type AmbientFieldOptions = {
  /** Cap the render rate (e.g. 13 for the calm sign-in field). 0/undefined = every rAF. */
  fps?: number;
  /** Scales dot alpha — 1 is drop-overlay hero brightness. */
  opacityScale?: number;
  /** Initial excitement target, 0 (calm) .. 1 (files hovering). */
  excitementTarget?: number;
};

/**
 * Owns the wave phases, excitement easing, live pulses and the rAF loop.
 * Wave state lives on the instance so the field keeps continuity across
 * attach/detach cycles (the overlay hiding and re-showing never "jumps").
 * Under prefers-reduced-motion attach() paints a single static frame and
 * pulse() is a no-op.
 */
export class AmbientField {
  private wave1 = Math.random() * 20;
  private wave2 = Math.random() * 20;
  private excitement = 0;
  private excitementTarget: number;
  private pulses: ActivePulse[] = [];
  private readonly frameInterval: number;
  private readonly opacityScale: number;
  private ctx: CanvasRenderingContext2D | null = null;
  private raf = 0;
  private last = 0;
  private lastDraw = -Infinity;
  private reduced = prefersReducedMotion();
  private onResize: (() => void) | null = null;

  constructor(opts: AmbientFieldOptions = {}) {
    this.frameInterval = opts.fps && opts.fps > 0 ? 1000 / opts.fps : 0;
    this.opacityScale = opts.opacityScale ?? 1;
    this.excitementTarget = opts.excitementTarget ?? 0;
  }

  /** Ease the field toward calm (0) or agitated (1); ramps, never jumps. */
  setExcitementTarget(target: number): void {
    this.excitementTarget = target;
  }

  /** Radial pressure pulse from a viewport point. No-op under reduced motion. */
  pulse(x: number, y: number, opts: PulseOptions = {}): void {
    if (this.reduced) return;
    this.pulses.push({
      x,
      y,
      start: performance.now(),
      speed: opts.speed ?? PULSE_SPEED,
      seconds: opts.seconds ?? PULSE_SECONDS,
      sigma: opts.sigma ?? PULSE_SIGMA,
      strength: opts.strength ?? 1,
    });
  }

  clearPulses(): void {
    this.pulses = [];
  }

  /** Bind to a full-viewport canvas and start rendering. */
  attach(canvas: HTMLCanvasElement): void {
    this.detach();
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    this.ctx = ctx;
    this.reduced = prefersReducedMotion();

    const resize = () => {
      const dpr = window.devicePixelRatio || 1;
      canvas.width = Math.round(window.innerWidth * dpr);
      canvas.height = Math.round(window.innerHeight * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };
    resize();
    window.addEventListener("resize", resize);
    this.onResize = resize;

    if (this.reduced) {
      // Static dots — a single calm frame, no wave, no pulse.
      this.pulses = [];
      this.render(performance.now());
      return;
    }
    this.last = performance.now();
    this.lastDraw = -Infinity;
    this.raf = requestAnimationFrame(this.tick);
  }

  /** Stop rendering and release the canvas; wave state is kept. */
  detach(): void {
    cancelAnimationFrame(this.raf);
    this.raf = 0;
    if (this.onResize) {
      window.removeEventListener("resize", this.onResize);
      this.onResize = null;
    }
    this.ctx = null;
  }

  private tick = (now: number) => {
    this.raf = requestAnimationFrame(this.tick);
    // fps cap: skip frames without integrating, so dt stays honest.
    if (this.frameInterval > 0 && now - this.lastDraw < this.frameInterval) return;
    this.lastDraw = now;
    const dt = Math.min(0.1, (now - this.last) / 1000);
    this.last = now;
    // Ease the excitement toward its target so amplitude/speed ramp subtly.
    this.excitement += (this.excitementTarget - this.excitement) * Math.min(1, dt * 2.5);
    // Integrate phase (not t × speed) so speed changes never jump the wave.
    const speedBoost = 1 + this.excitement * 1.3;
    this.wave1 += dt * 0.31 * speedBoost;
    this.wave2 += dt * 0.24 * speedBoost;
    this.render(now);
  };

  private render(now: number): void {
    const ctx = this.ctx;
    if (!ctx) return;
    const w = window.innerWidth;
    const h = window.innerHeight;
    ctx.clearRect(0, 0, w, h);

    const cols = Math.ceil(w / SPACING) + 2;
    const rows = Math.ceil(h / SPACING) + 2;
    // While excited (files hovering) the field breathes faster and harder.
    const amp = 1.0 + this.excitement * 0.85;
    const rRange = PEAK_RADIUS - BASE_RADIUS;
    const p1 = this.wave1;
    const p2 = this.wave2;

    // Resolve live pulses once per frame; expired ones fall out of the array.
    this.pulses = this.pulses.filter((p) => (now - p.start) / 1000 <= p.seconds);
    const live = this.pulses.map((p) => {
      const elapsed = (now - p.start) / 1000;
      return {
        x: p.x,
        y: p.y,
        r: elapsed * p.speed,
        twoSigmaSq: 2 * p.sigma * p.sigma,
        decay: (1 - elapsed / p.seconds) * p.strength,
      };
    });

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

        for (const p of live) {
          const d = Math.hypot(cx - p.x, cy - p.y) - p.r;
          norm = Math.min(1, norm + Math.exp(-(d * d) / p.twoSigmaSq) * p.decay);
        }

        if (norm < 0.02) continue; // valleys: skip the fill entirely
        const r = BASE_RADIUS + norm * rRange;
        ctx.globalAlpha = norm * PEAK_OPACITY * this.opacityScale;
        ctx.beginPath();
        ctx.arc(cx, cy, r, 0, Math.PI * 2);
        ctx.fill();
      }
    }
    ctx.globalAlpha = 1;
  }
}
