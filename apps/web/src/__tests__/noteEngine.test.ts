/**
 * Tests for the note carry-forward engine in @pmw/shared.
 *
 * These guard the most consequential business rule in the product:
 * "Which notes are visible on version N, and are they marked as carried
 * forward from an earlier version?"
 *
 * A bug here silently hides or surfaces notes in the wrong context —
 * a reviewer or artist acts on stale/wrong information.
 */
import { describe, expect, it } from "vitest";
import {
  durationDiffExceeds,
  formatTimestamp,
  getVisibleNotesForVersion,
} from "@pmw/shared";
import type { FileAsset, Note, Version } from "@pmw/shared";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------
const NOW = "2024-01-01T00:00:00Z";
const LATER = "2024-01-02T00:00:00Z";

function makeVersion(overrides: Partial<Version>): Version {
  return {
    version_id: "ver-1",
    song_id: "song-1",
    version_number: 1,
    version_label: "Mix v1",
    type: "mix",
    is_current: false,
    is_approved: false,
    uploaded_by: "usr-test",
    file_asset_id: "asset-1",
    created_at: NOW,
    ...overrides,
  };
}

function makeNote(overrides: Partial<Note>): Note {
  return {
    note_id: "note-1",
    song_id: "song-1",
    anchor_version_id: "ver-1",
    body: "Fix the kick",
    scope: "song",
    visibility: "everyone",
    timestamp_uncertain: false,
    priority: "normal",
    status: "open",
    created_at: NOW,
    updated_at: NOW,
    ...overrides,
  };
}

function makeAsset(id: string, duration_ms: number): FileAsset {
  return {
    asset_id: id,
    workspace_id: "wsp-test",
    original_filename: "track.mp3",
    key_original: "audio/track.mp3",
    file_size_bytes: 1024,
    checksum_sha256: "abc",
    duration_ms,
    sample_rate: 44100,
    bit_depth: 16,
    loudness_lufs: -14,
    true_peak_db: -1,
    virus_scan_status: "clean",
    transcoding_status: "ready",
    waveform_peaks: [],
    created_at: NOW,
  };
}

// ---------------------------------------------------------------------------
// formatTimestamp
// ---------------------------------------------------------------------------
describe("formatTimestamp", () => {
  it("formats zero as 0:00", () => {
    expect(formatTimestamp(0)).toBe("0:00");
  });

  it("pads seconds to two digits", () => {
    expect(formatTimestamp(5000)).toBe("0:05");
  });

  it("handles minutes correctly", () => {
    expect(formatTimestamp(90000)).toBe("1:30");
  });

  it("handles undefined / null gracefully as 'General'", () => {
    expect(formatTimestamp(undefined)).toBe("General");
    // @ts-expect-error — testing runtime null path
    expect(formatTimestamp(null)).toBe("General");
  });

  it("floors sub-second values (does not round up to next second)", () => {
    // 1999ms → 1 second, not 2
    expect(formatTimestamp(1999)).toBe("0:01");
  });
});

// ---------------------------------------------------------------------------
// durationDiffExceeds
// ---------------------------------------------------------------------------
describe("durationDiffExceeds", () => {
  it("returns false when either duration is zero or negative", () => {
    expect(durationDiffExceeds(0, 180000)).toBe(false);
    expect(durationDiffExceeds(180000, 0)).toBe(false);
    expect(durationDiffExceeds(-1, 180000)).toBe(false);
  });

  it("returns false when the difference is within the default 5% threshold", () => {
    // 180s anchor, 184s current = +2.2% — within threshold
    expect(durationDiffExceeds(180000, 184000)).toBe(false);
  });

  it("returns true when the difference exceeds the default 5% threshold", () => {
    // 180s anchor, 200s current = +11.1% — exceeds threshold
    expect(durationDiffExceeds(180000, 200000)).toBe(true);
  });

  it("respects a custom threshold", () => {
    // 10% difference, custom threshold of 0.15 → should NOT exceed
    expect(durationDiffExceeds(180000, 198000, 0.15)).toBe(false);
    // same difference, tighter threshold of 0.05 → should exceed
    expect(durationDiffExceeds(180000, 198000, 0.05)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// getVisibleNotesForVersion — core carry-forward engine
// ---------------------------------------------------------------------------
describe("getVisibleNotesForVersion", () => {
  const v1 = makeVersion({ version_id: "ver-1", version_number: 1, file_asset_id: "asset-1" });
  const v2 = makeVersion({ version_id: "ver-2", version_number: 2, file_asset_id: "asset-2" });
  const versions = [v1, v2];
  const assets = [makeAsset("asset-1", 180000), makeAsset("asset-2", 181000)];

  it("shows an open song-scoped note on the version it was anchored to", () => {
    const note = makeNote({ anchor_version_id: "ver-1", scope: "song", status: "open" });
    const result = getVisibleNotesForVersion({ version: v1, versions, notes: [note], assets });
    expect(result).toHaveLength(1);
    expect(result[0].note_id).toBe("note-1");
  });

  it("carries an open song-scoped note forward to a later version (is_carried = true)", () => {
    const note = makeNote({ anchor_version_id: "ver-1", scope: "song", status: "open" });
    const result = getVisibleNotesForVersion({ version: v2, versions, notes: [note], assets });
    expect(result).toHaveLength(1);
    expect(result[0].is_carried).toBe(true);
    expect(result[0].anchor_version_label).toBe("Mix v1");
  });

  it("does NOT carry a version-scoped note to a later version", () => {
    const note = makeNote({ anchor_version_id: "ver-1", scope: "version", status: "open" });
    // Should appear on v1 only
    const onV1 = getVisibleNotesForVersion({ version: v1, versions, notes: [note], assets });
    expect(onV1).toHaveLength(1);

    const onV2 = getVisibleNotesForVersion({ version: v2, versions, notes: [note], assets });
    expect(onV2).toHaveLength(0);
  });

  it("shows a resolved note on the version that resolved it (is_collapsed = true)", () => {
    // Resolved on v2: appears on v1 AND v2 (you can see what was just resolved),
    // but is_collapsed flags it so the UI can fold it.
    const note = makeNote({
      anchor_version_id: "ver-1",
      scope: "song",
      status: "resolved",
      resolved_on_version_id: "ver-2",
    });
    const onV2 = getVisibleNotesForVersion({ version: v2, versions, notes: [note], assets });
    expect(onV2).toHaveLength(1);
    expect(onV2[0].is_collapsed).toBe(true);
  });

  it("shows a resolved note on versions BEFORE the resolving version", () => {
    // Resolved on v2 — also appears on v1 (the anchored version)
    const note = makeNote({
      anchor_version_id: "ver-1",
      scope: "song",
      status: "resolved",
      resolved_on_version_id: "ver-2",
    });
    const onV1 = getVisibleNotesForVersion({ version: v1, versions, notes: [note], assets });
    expect(onV1).toHaveLength(1);
  });

  it("hides a resolved note on versions AFTER the resolving version", () => {
    // Resolved on v1 — should NOT appear on v2 (note was addressed; move on)
    const v3 = makeVersion({ version_id: "ver-3", version_number: 3, file_asset_id: "asset-2" });
    const note = makeNote({
      anchor_version_id: "ver-1",
      scope: "song",
      status: "resolved",
      resolved_on_version_id: "ver-1",
    });
    const onV2 = getVisibleNotesForVersion({
      version: v2,
      versions: [...versions, v3],
      notes: [note],
      assets,
    });
    expect(onV2).toHaveLength(0);
  });

  it("excludes notes from a different song", () => {
    const foreignNote = makeNote({ song_id: "song-other" });
    const result = getVisibleNotesForVersion({ version: v1, versions, notes: [foreignNote], assets });
    expect(result).toHaveLength(0);
  });

  it("excludes notes whose anchor version is newer than the target version", () => {
    // Note anchored to v2 should not appear on v1
    const note = makeNote({ anchor_version_id: "ver-2", scope: "song", status: "open" });
    const result = getVisibleNotesForVersion({ version: v1, versions, notes: [note], assets });
    expect(result).toHaveLength(0);
  });

  it("sorts notes by timestamp_start_ms ascending (nulls last)", () => {
    const n1 = makeNote({ note_id: "note-1", timestamp_start_ms: 60000 });
    const n2 = makeNote({ note_id: "note-2", timestamp_start_ms: 10000 });
    const n3 = makeNote({ note_id: "note-3", timestamp_start_ms: undefined }); // general
    const result = getVisibleNotesForVersion({ version: v1, versions, notes: [n1, n2, n3], assets });
    expect(result.map((n) => n.note_id)).toEqual(["note-2", "note-1", "note-3"]);
  });

  it("marks approximate_timestamp when durations have diverged beyond threshold", () => {
    // v1 = 180s, v3 = 200s (11% longer — exceeds 5% threshold)
    const v3 = makeVersion({ version_id: "ver-3", version_number: 3, file_asset_id: "asset-3" });
    const longAsset = makeAsset("asset-3", 200000); // 200s vs 180s = +11%
    const note = makeNote({
      anchor_version_id: "ver-1",
      scope: "song",
      status: "open",
      timestamp_start_ms: 30000,
    });
    const result = getVisibleNotesForVersion({
      version: v3,
      versions: [...versions, v3],
      notes: [note],
      assets: [...assets, longAsset],
    });
    expect(result[0].is_carried).toBe(true);
    expect(result[0].approximate_timestamp).toBe(true);
  });

  it("does NOT mark approximate_timestamp when durations are similar (within 5%)", () => {
    // v1 = 180s, v2 = 181s — well within threshold
    const note = makeNote({
      anchor_version_id: "ver-1",
      scope: "song",
      status: "open",
      timestamp_start_ms: 30000,
    });
    const result = getVisibleNotesForVersion({ version: v2, versions, notes: [note], assets });
    expect(result[0].approximate_timestamp).toBe(false);
  });
});
