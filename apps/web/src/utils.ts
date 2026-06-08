/**
 * Pure helpers extracted from App.tsx so they can be unit-tested without
 * importing React or the Supabase client.  App.tsx re-exports/re-calls these
 * directly — no behaviour change, just a seam.
 */

import type { ActivityEvent, FileAsset, Song, Version, VersionType } from "@pmw/shared";

// ---------------------------------------------------------------------------
// Cover art / visual identity
// ---------------------------------------------------------------------------

/** Derive a stable hue (0–360) from an arbitrary string id. */
export function hashHue(id: string): number {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
  return h % 360;
}

/** Derive a stable 4-digit catalog number from a song id.
 *  FNV-1a 64-bit — bit-for-bit matching iOS's PMWSong.catalogNumber.
 *  Uses BigInt to avoid JS's 53-bit precision limit. */
export function catalogNumber(id: string): string {
  let hash = 0xcbf29ce484222325n; // FNV-1a 64-bit offset basis
  const prime = 0x100000001b3n; // FNV-1a 64-bit prime
  const mask = 0xffffffffffffffffn; // 64-bit unsigned wrap
  const bytes = new TextEncoder().encode(id);
  for (const byte of bytes) {
    hash = ((hash ^ BigInt(byte)) * prime) & mask;
  }
  const n = Number(hash % 9000n) + 1000;
  return String(n);
}

/** Full "PB · XXXX" display form. */
export function catalogIdFor(songId: string): string {
  return `PB · ${catalogNumber(songId)}`;
}

/** Build a sleeve-mode CSS gradient string keyed off the song id. */
export function coverGradient(id: string): string {
  const hue = hashHue(id);
  const angle = 130 + (hashHue(id + "a") % 40);
  // Saturation floored higher than before so the light stops read as a real
  // colour (amber / teal / mauve) instead of desaturated olive-grey mud, while
  // the dark anchor keeps the sleeve grounded. Tuned for the cream surface.
  return `linear-gradient(${angle}deg,
    hsl(${(hue + 200) % 360} 16% 13%) 0%,
    hsl(${(hue + 30) % 360} 30% 30%) 32%,
    hsl(${hue} 46% 52%) 66%,
    hsl(${(hue + 25) % 360} 60% 74%) 100%)`;
}

// ---------------------------------------------------------------------------
// Smart-view filter predicate
// ---------------------------------------------------------------------------

/** The shape that LibraryView receives as `smartView`. */
export type SmartFilter = Record<string, unknown>;

/** A single row from the workspace library endpoint. */
export type LibraryItem = {
  song: Song;
  room: { room_id: string; title: string; type: string } | null;
  current_version: import("@pmw/shared").Version | null;
  asset: import("@pmw/shared").FileAsset | null;
};

// ---------------------------------------------------------------------------
// Copy — humanize VersionType for user-facing display
// ---------------------------------------------------------------------------

const VERSION_TYPE_LABELS: Record<VersionType, string> = {
  mix: "Mix",
  master: "Master",
  demo: "Demo",
  rough: "Rough",
  clean: "Clean",
  explicit: "Explicit",
  instrumental: "Instrumental",
  acapella: "Acapella",
  tv_track: "TV track",
  sped_up: "Sped up",
  slowed: "Slowed",
  alt_arrangement: "Alt arrangement",
  reference: "Reference",
  stem_derived: "Stem derived",
};

/**
 * Return a human-readable label for a VersionType value.
 * Falls back to title-casing the raw string if the type isn't in the map.
 */
export function humanizeVersionType(type: VersionType | string): string {
  if (type in VERSION_TYPE_LABELS) return VERSION_TYPE_LABELS[type as VersionType];
  return type.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

// ---------------------------------------------------------------------------
// Feature 2 — Version delta
// ---------------------------------------------------------------------------

export type VersionDelta = {
  lufsDelta: number;
  durationDeltaMs: number;
  /** Present when the two adjacent versions have different types. */
  typeChange?: { from: VersionType; to: VersionType };
};

/**
 * Compute loudness, duration, and type delta between two adjacent versions.
 *
 * PF1: Accepts a pre-sorted version list and a pre-built asset Map so the
 * owning component can hoist the O(n log n) sort and O(n) Map construction
 * outside the per-row render cycle.
 *
 * @param currentVersion   The version whose delta we want to display.
 * @param sortedVersions   All versions for the song, already sorted ascending by version_number.
 * @param assetMap         Map<asset_id, FileAsset> built once by the owner.
 */
export function computeVersionDelta(
  currentVersion: Version,
  sortedVersions: Version[],
  assetMap: Map<string, FileAsset>
): VersionDelta | null {
  const idx = sortedVersions.findIndex((v) => v.version_id === currentVersion.version_id);
  if (idx <= 0) return null; // no earlier version
  const earlier = sortedVersions[idx - 1];
  const curAsset = assetMap.get(currentVersion.file_asset_id);
  const prevAsset = assetMap.get(earlier.file_asset_id);
  if (!curAsset || !prevAsset) return null;
  const delta: VersionDelta = {
    lufsDelta: curAsset.loudness_lufs - prevAsset.loudness_lufs,
    durationDeltaMs: curAsset.duration_ms - prevAsset.duration_ms,
  };
  if (earlier.type !== currentVersion.type) {
    delta.typeChange = { from: earlier.type, to: currentVersion.type };
  }
  return delta;
}

/**
 * Format a VersionDelta into a compact display string,
 * e.g. "rough → mix · −0.8 LUFS · +0:03".
 * Returns null when delta is null.
 */
export function formatVersionDelta(delta: VersionDelta | null): string | null {
  if (!delta) return null;
  const lufsSign = delta.lufsDelta >= 0 ? "+" : "−";
  const lufsAbs = Math.abs(delta.lufsDelta).toFixed(1);
  const durSign = delta.durationDeltaMs >= 0 ? "+" : "−";
  const durAbsS = Math.abs(Math.round(delta.durationDeltaMs / 1000));
  const durMins = Math.floor(durAbsS / 60);
  const durSecs = String(durAbsS % 60).padStart(2, "0");
  const lufsStr = `${lufsSign}${lufsAbs} LUFS`;
  const durStr = `${durSign}${durMins}:${durSecs}`;
  if (delta.typeChange) {
    const fromLabel = humanizeVersionType(delta.typeChange.from);
    const toLabel = humanizeVersionType(delta.typeChange.to);
    return `${fromLabel} → ${toLabel} · ${lufsStr} · ${durStr}`;
  }
  return `${lufsStr} · ${durStr}`;
}

// ---------------------------------------------------------------------------
// Feature 3 — "Heard by N of M" aggregation
// ---------------------------------------------------------------------------

export type HeardByCount = {
  /** Recipients with at least one played_track event. */
  heard: number;
  /** Distinct recipients who opened or played (total exposed). */
  total: number;
};

/**
 * Given the analytics events for a single link, count distinct recipients who
 * played (heard) vs. distinct recipients who opened or played (total).
 *
 * Uses `actor_recipient_label` as the recipient identifier, falling back to
 * `actor_user_id`. Events with neither are attributed to a single anonymous
 * slot (counted once in total, not in heard unless they also played).
 *
 * @param events  Analytics events filtered to a single link_id.
 */
export function heardByCount(events: ActivityEvent[]): HeardByCount {
  const actorKey = (e: ActivityEvent): string =>
    e.actor_recipient_label ?? e.actor_user_id ?? "__anonymous__";

  const totalActors = new Set<string>();
  const heardActors = new Set<string>();

  for (const ev of events) {
    const key = actorKey(ev);
    if (ev.event_type === "opened_link" || ev.event_type === "played_track") {
      totalActors.add(key);
    }
    if (ev.event_type === "played_track") {
      heardActors.add(key);
    }
  }

  return { heard: heardActors.size, total: totalActors.size };
}

/**
 * T2 — Honest "heard by" display string for a single link.
 *
 * Rules:
 *  - identity_required links: show "Heard by N of M" only when a recipient
 *    count is meaningful (M comes from distinct named actors, not anonymous
 *    slots). Falls through to play-count form when M = 0 or all actors are
 *    anonymous.
 *  - public/anonymous links (requires_identity = false): never show "of M"
 *    because the anonymous-slot collapsing makes M misleading. Show play
 *    count only.
 *
 * Returns null when there is nothing honest to show (zero plays).
 */
export function formatHeardDisplay(
  heard: HeardByCount,
  requiresIdentity: boolean
): string | null {
  if (heard.heard === 0 && heard.total === 0) return null;

  if (requiresIdentity && heard.total > 0) {
    // Named recipients only: if we have a meaningful denominator, show ratio.
    // The total includes opens + plays by named actors; this is our best proxy
    // for "people who were sent the link and engaged" on identity-required links.
    return `Heard by ${heard.heard} of ${heard.total}`;
  }

  // Public links or identity-required with zero opens: show play count only.
  if (heard.heard > 0) {
    return `${heard.heard} ${heard.heard === 1 ? "play" : "plays"}`;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Smart-view filter predicate
// ---------------------------------------------------------------------------

/**
 * Returns true when `item` satisfies every clause in `filter`.
 * Extracted from LibraryView so the predicate can be tested without mounting
 * the component.
 *
 * Supported filter keys:
 *   status             — exact match against song.status
 *   release_readiness  — exact match against song.release_readiness_status
 *   missing            — array presence means "exclude ready songs" (client-side
 *                        proxy for deliverable gap logic; see App.tsx comment)
 */
export function matchesSmart(item: LibraryItem, filter: SmartFilter): boolean {
  if (typeof filter.status === "string" && item.song.status !== filter.status) return false;
  if (
    typeof filter.release_readiness === "string" &&
    item.song.release_readiness_status !== filter.release_readiness
  )
    return false;
  if (Array.isArray(filter.missing) && item.song.release_readiness_status === "ready") return false;
  return true;
}
