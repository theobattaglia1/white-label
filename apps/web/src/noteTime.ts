/**
 * noteTime.ts — timestamped-note helpers (pure functions, vitest-covered).
 *
 * Notes carry a native `timestamp_start_ms` field end-to-end (models.ts →
 * POST /notes → store.createNote → Supabase), so that is the storage of
 * record. These helpers exist for the in-body "@m:ss " convention:
 *   - typing "@2:14 pull the snare" in the composer pins the note to 2:14
 *     (the prefix is stripped before sending, the ms goes in the field);
 *   - notes that arrive with the prefix still in the body (e.g. written
 *     from surfaces that only post text) are parsed for display — time
 *     chip + clean body — and degrade honestly everywhere else.
 */

/** "@m:ss", "@mm:ss" or "@h:mm:ss" at the start of the body, followed by whitespace or end. */
const NOTE_TS_RE = /^@(\d{1,3}):([0-5]\d)(?::([0-5]\d))?(?=\s|$)/;

export type ParsedTimestampPrefix = {
  /** Parsed prefix in ms, or null when the body has no valid prefix. */
  ms: number | null;
  /** Body with the prefix (and surrounding whitespace) stripped. Unchanged when ms is null. */
  rest: string;
};

/** Parse a leading "@m:ss " / "@h:mm:ss " prefix out of a note body. */
export function parseTimestampPrefix(body: string): ParsedTimestampPrefix {
  const match = body.match(NOTE_TS_RE);
  if (!match) return { ms: null, rest: body };
  const [full, a, b, c] = match;
  const ms = c !== undefined
    ? (Number(a) * 3600 + Number(b) * 60 + Number(c)) * 1000
    : (Number(a) * 60 + Number(b)) * 1000;
  return { ms, rest: body.slice(full.length).replace(/^\s+/, "") };
}

/** Strip a valid timestamp prefix from a body; no-op when there is none. */
export function stripTimestampPrefix(body: string): string {
  return parseTimestampPrefix(body).rest;
}

/**
 * Resolve what a note should display: the native timestamp field wins,
 * a body prefix is the fallback; either way the prefix never renders twice.
 */
export function noteDisplayParts(note: { body: string; timestamp_start_ms?: number }): {
  ms?: number;
  body: string;
} {
  const { ms, rest } = parseTimestampPrefix(note.body);
  return {
    ms: note.timestamp_start_ms ?? (ms ?? undefined),
    body: ms !== null ? rest : note.body,
  };
}

// =====================================================================
// Note-lane time math — the strip beneath the scrubber where notes are
// dropped by direct manipulation. Pure px↔ms conversions, vitest-covered.
// =====================================================================

/** Pointer x (px from the lane's left edge) → playhead ms, clamped to [0, durationMs]. */
export function laneMsAtX(x: number, laneWidth: number, durationMs: number): number {
  if (laneWidth <= 0 || durationMs <= 0) return 0;
  const frac = Math.min(1, Math.max(0, x / laneWidth));
  return Math.round(frac * durationMs);
}

/** Tick position for a note at `ms`, as a percentage of the lane width, clamped to [0, 100]. */
export function laneTickPct(ms: number, durationMs: number): number {
  if (durationMs <= 0) return 0;
  return Math.min(100, Math.max(0, (ms / durationMs) * 100));
}

/**
 * Clamp an anchored composer's center (pct of lane width) so the popover
 * stays inside the lane. Falls back to center when the lane is unmeasured.
 */
export function clampComposerPct(pct: number, laneWidth: number, composerWidth: number): number {
  if (laneWidth <= 0) return 50;
  const half = Math.min(50, (composerWidth / 2 / laneWidth) * 100);
  return Math.min(100 - half, Math.max(half, pct));
}
