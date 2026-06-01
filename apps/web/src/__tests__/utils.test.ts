import { describe, expect, it } from "vitest";
import { catalogIdFor, catalogNumber, computeVersionDelta, coverGradient, formatVersionDelta, hashHue, heardByCount, matchesSmart, humanizeVersionType, formatHeardDisplay } from "../utils";
import type { LibraryItem, SmartFilter } from "../utils";
import type { ActivityEvent, FileAsset, Song, Version } from "@pmw/shared";

// ---------------------------------------------------------------------------
// Minimal Song fixture — only fields that matchesSmart actually reads
// ---------------------------------------------------------------------------
function makeSong(overrides: Partial<Song> = {}): Song {
  return {
    song_id: "song-test",
    workspace_id: "wsp-test",
    title: "Test Track",
    status: "draft",
    explicit_flag: false,
    genre_tags: [],
    mood_tags: [],
    instrument_tags: [],
    lyric_theme_tags: [],
    release_readiness_status: "not_ready",
    created_by: "usr-test",
    created_at: "2024-01-01T00:00:00Z",
    updated_at: "2024-01-01T00:00:00Z",
    ...overrides,
  };
}

function makeItem(songOverrides: Partial<Song> = {}): LibraryItem {
  return {
    song: makeSong(songOverrides),
    room: null,
    current_version: null,
    asset: null,
  };
}

// ---------------------------------------------------------------------------
// hashHue
// ---------------------------------------------------------------------------
describe("hashHue", () => {
  it("returns a number in [0, 360)", () => {
    const ids = ["song-midnight", "song-abc", "x", "", "a".repeat(200)];
    for (const id of ids) {
      const h = hashHue(id);
      expect(h).toBeGreaterThanOrEqual(0);
      expect(h).toBeLessThan(360);
    }
  });

  it("is deterministic — same id always yields same hue", () => {
    expect(hashHue("song-midnight")).toBe(hashHue("song-midnight"));
  });

  it("different ids produce different hues (no accidental collision on neighbouring ids)", () => {
    expect(hashHue("song-midnight")).not.toBe(hashHue("song-midnight-2"));
  });
});

// ---------------------------------------------------------------------------
// catalogNumber
// ---------------------------------------------------------------------------
describe("catalogNumber", () => {
  it("returns a 4-digit string (1000–9999)", () => {
    const ids = ["song-midnight", "song-abc", "x", "hello-world"];
    for (const id of ids) {
      const n = catalogNumber(id);
      expect(n).toMatch(/^\d{4}$/);
      const parsed = Number(n);
      expect(parsed).toBeGreaterThanOrEqual(1000);
      expect(parsed).toBeLessThanOrEqual(9999);
    }
  });

  it("is deterministic — same id always yields same catalog number", () => {
    expect(catalogNumber("song-midnight")).toBe(catalogNumber("song-midnight"));
  });

  it("never collides on the known seed ids used in the app", () => {
    const ids = ["song-midnight", "song-aurora", "song-gravity", "song-phantom"];
    const nums = ids.map(catalogNumber);
    const unique = new Set(nums);
    expect(unique.size).toBe(ids.length);
  });

  it("empty string does not throw and is in range", () => {
    const n = Number(catalogNumber(""));
    expect(n).toBeGreaterThanOrEqual(1000);
    expect(n).toBeLessThanOrEqual(9999);
  });
});

// ---------------------------------------------------------------------------
// catalogIdFor
// ---------------------------------------------------------------------------
describe("catalogIdFor", () => {
  it("formats as 'WL · XXXX'", () => {
    const id = catalogIdFor("song-midnight");
    expect(id).toMatch(/^WL · \d{4}$/);
  });

  it("embeds the same number as catalogNumber", () => {
    const songId = "song-gravity";
    expect(catalogIdFor(songId)).toBe(`WL · ${catalogNumber(songId)}`);
  });
});

// ---------------------------------------------------------------------------
// coverGradient
// ---------------------------------------------------------------------------
describe("coverGradient", () => {
  it("returns a CSS linear-gradient string", () => {
    const g = coverGradient("song-midnight");
    expect(g).toMatch(/^linear-gradient\(/);
  });

  it("is deterministic", () => {
    expect(coverGradient("song-midnight")).toBe(coverGradient("song-midnight"));
  });

  it("different ids produce different gradients", () => {
    expect(coverGradient("song-midnight")).not.toBe(coverGradient("song-aurora"));
  });

  it("angle stays within expected band (130–169 degrees)", () => {
    // angle = 130 + (hashHue(id + 'a') % 40)  ∴ range [130, 169]
    const angleMatch = coverGradient("song-test").match(/linear-gradient\((\d+)deg/);
    expect(angleMatch).not.toBeNull();
    const angle = Number(angleMatch![1]);
    expect(angle).toBeGreaterThanOrEqual(130);
    expect(angle).toBeLessThanOrEqual(169);
  });
});

// ---------------------------------------------------------------------------
// matchesSmart
// ---------------------------------------------------------------------------
describe("matchesSmart", () => {
  it("passes an item when no filter clauses are present", () => {
    const item = makeItem({ status: "draft", release_readiness_status: "not_ready" });
    expect(matchesSmart(item, {})).toBe(true);
  });

  it("filters by status — matching status passes", () => {
    const filter: SmartFilter = { status: "approved" };
    expect(matchesSmart(makeItem({ status: "approved" }), filter)).toBe(true);
  });

  it("filters by status — non-matching status fails", () => {
    const filter: SmartFilter = { status: "approved" };
    expect(matchesSmart(makeItem({ status: "in_review" }), filter)).toBe(false);
  });

  it("filters by release_readiness — matching value passes", () => {
    const filter: SmartFilter = { release_readiness: "ready" };
    expect(
      matchesSmart(makeItem({ release_readiness_status: "ready" }), filter)
    ).toBe(true);
  });

  it("filters by release_readiness — non-matching value fails", () => {
    const filter: SmartFilter = { release_readiness: "ready" };
    expect(
      matchesSmart(makeItem({ release_readiness_status: "not_ready" }), filter)
    ).toBe(false);
  });

  it("missing-array filter excludes songs that ARE ready (proxy for deliverable gap)", () => {
    const filter: SmartFilter = { missing: ["instrumental", "stems"] };
    // A ready song should be excluded
    expect(
      matchesSmart(makeItem({ release_readiness_status: "ready" }), filter)
    ).toBe(false);
    // A not-ready song should pass (it IS missing deliverables — correct to show)
    expect(
      matchesSmart(makeItem({ release_readiness_status: "not_ready" }), filter)
    ).toBe(true);
  });

  it("multiple clauses must all pass — status match + missing-array excludes ready", () => {
    const filter: SmartFilter = { status: "in_review", missing: ["stems"] };
    // status matches but song is ready → excluded
    expect(
      matchesSmart(makeItem({ status: "in_review", release_readiness_status: "ready" }), filter)
    ).toBe(false);
    // status matches and song is not_ready → included
    expect(
      matchesSmart(makeItem({ status: "in_review", release_readiness_status: "not_ready" }), filter)
    ).toBe(true);
    // status doesn't match → excluded
    expect(
      matchesSmart(makeItem({ status: "draft", release_readiness_status: "not_ready" }), filter)
    ).toBe(false);
  });

  it("ignores filter.status when it is not a string (e.g. undefined)", () => {
    // filter has status key but value is a number — should not filter
    const filter: SmartFilter = { status: 42 };
    expect(matchesSmart(makeItem({ status: "draft" }), filter)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Feature 2 — computeVersionDelta / formatVersionDelta
// ---------------------------------------------------------------------------

function makeVersion(overrides: Partial<Version> & { version_id: string; version_number: number; file_asset_id: string }): Version {
  return {
    song_id: "song-test",
    version_label: `v${overrides.version_number}`,
    type: "mix",
    is_current: false,
    is_approved: false,
    uploaded_by: "usr-test",
    created_at: "2024-01-01T00:00:00Z",
    ...overrides,
  };
}

function makeAsset(assetId: string, loudnessLufs: number, durationMs: number): FileAsset {
  return {
    asset_id: assetId,
    workspace_id: "wsp-test",
    original_filename: "test.wav",
    key_original: "path/test.wav",
    file_size_bytes: 1000000,
    checksum_sha256: "abc",
    duration_ms: durationMs,
    sample_rate: 44100,
    bit_depth: 24,
    loudness_lufs: loudnessLufs,
    true_peak_db: -1,
    virus_scan_status: "clean",
    transcoding_status: "ready",
    waveform_peaks: [],
    created_at: "2024-01-01T00:00:00Z",
  };
}

describe("computeVersionDelta", () => {
  const v1 = makeVersion({ version_id: "v1", version_number: 1, file_asset_id: "a1" });
  const v2 = makeVersion({ version_id: "v2", version_number: 2, file_asset_id: "a2" });
  const v3 = makeVersion({ version_id: "v3", version_number: 3, file_asset_id: "a3" });
  const a1 = makeAsset("a1", -12.0, 180000);
  const a2 = makeAsset("a2", -12.8, 183000);
  const a3 = makeAsset("a3", -13.0, 179000);
  // PF1: caller pre-sorts and pre-builds the Map
  const sortedVersions = [v1, v2, v3];
  const assetMap = new Map([
    [a1.asset_id, a1],
    [a2.asset_id, a2],
    [a3.asset_id, a3],
  ]);

  it("returns null for the first version (no earlier version)", () => {
    expect(computeVersionDelta(v1, sortedVersions, assetMap)).toBeNull();
  });

  it("computes lufs and duration delta vs the immediately-earlier version", () => {
    const delta = computeVersionDelta(v2, sortedVersions, assetMap);
    expect(delta).not.toBeNull();
    // a2.loudness_lufs(-12.8) - a1.loudness_lufs(-12.0) = -0.8
    expect(delta!.lufsDelta).toBeCloseTo(-0.8, 5);
    // a2.duration_ms(183000) - a1.duration_ms(180000) = 3000ms
    expect(delta!.durationDeltaMs).toBe(3000);
  });

  it("computes delta vs immediately-earlier only, not vs v1", () => {
    const delta = computeVersionDelta(v3, sortedVersions, assetMap);
    // a3 vs a2: loudness -13.0 - (-12.8) = -0.2; duration 179000-183000 = -4000ms
    expect(delta!.lufsDelta).toBeCloseTo(-0.2, 5);
    expect(delta!.durationDeltaMs).toBe(-4000);
  });

  it("returns null when asset is missing for either version", () => {
    expect(computeVersionDelta(v2, sortedVersions, new Map())).toBeNull();
  });

  it("returns null when only the current version's asset is missing", () => {
    // a2 absent, a1 present — current asset lookup fails
    const partialMap = new Map([[a1.asset_id, a1], [a3.asset_id, a3]]);
    expect(computeVersionDelta(v2, sortedVersions, partialMap)).toBeNull();
  });

  it("returns null when only the previous version's asset is missing", () => {
    // a1 absent, a2 present — previous asset lookup fails
    const partialMap = new Map([[a2.asset_id, a2], [a3.asset_id, a3]]);
    expect(computeVersionDelta(v2, sortedVersions, partialMap)).toBeNull();
  });

  it("returns null when there is only one version (no earlier version to compare)", () => {
    expect(computeVersionDelta(v1, [v1], assetMap)).toBeNull();
  });

  it("caller provides pre-sorted list — version_number order determines adjacency", () => {
    // v2 compared against v1 using a pre-sorted list
    const delta = computeVersionDelta(v2, sortedVersions, assetMap);
    expect(delta).not.toBeNull();
    expect(delta!.lufsDelta).toBeCloseTo(-0.8, 5);
    expect(delta!.durationDeltaMs).toBe(3000);
  });

  it("picks the immediately-adjacent earlier version, not the first version", () => {
    // v3's neighbour is v2, not v1 — delta must NOT use a1
    const delta = computeVersionDelta(v3, sortedVersions, assetMap);
    expect(delta).not.toBeNull();
    // If it accidentally compared against v1 (a1): -13.0 - (-12.0) = -1.0 — wrong
    expect(delta!.lufsDelta).not.toBeCloseTo(-1.0, 5);
    // Correct: -13.0 - (-12.8) = -0.2
    expect(delta!.lufsDelta).toBeCloseTo(-0.2, 5);
  });

  it("detects a type change between adjacent versions", () => {
    const vRough = makeVersion({ version_id: "vr", version_number: 1, file_asset_id: "a1", type: "rough" });
    const vMix   = makeVersion({ version_id: "vm", version_number: 2, file_asset_id: "a2", type: "mix"   });
    const delta = computeVersionDelta(vMix, [vRough, vMix], assetMap);
    expect(delta).not.toBeNull();
    expect(delta!.typeChange).toEqual({ from: "rough", to: "mix" });
  });

  it("returns no typeChange when adjacent versions share the same type", () => {
    const delta = computeVersionDelta(v2, sortedVersions, assetMap);
    expect(delta).not.toBeNull();
    expect(delta!.typeChange).toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// humanizeVersionType
// ---------------------------------------------------------------------------
describe("humanizeVersionType", () => {
  it("maps tv_track to 'TV track'", () => {
    expect(humanizeVersionType("tv_track")).toBe("TV track");
  });
  it("maps alt_arrangement to 'Alt arrangement'", () => {
    expect(humanizeVersionType("alt_arrangement")).toBe("Alt arrangement");
  });
  it("maps sped_up to 'Sped up'", () => {
    expect(humanizeVersionType("sped_up")).toBe("Sped up");
  });
  it("maps slowed to 'Slowed'", () => {
    expect(humanizeVersionType("slowed")).toBe("Slowed");
  });
  it("maps stem_derived to 'Stem derived'", () => {
    expect(humanizeVersionType("stem_derived")).toBe("Stem derived");
  });
  it("maps mix to 'Mix'", () => {
    expect(humanizeVersionType("mix")).toBe("Mix");
  });
  it("falls back gracefully for unknown types", () => {
    expect(humanizeVersionType("future_type" as any)).toBe("Future Type");
  });
});

// ---------------------------------------------------------------------------
// formatHeardDisplay
// ---------------------------------------------------------------------------
describe("formatHeardDisplay", () => {
  it("returns null when there are zero plays and zero opens", () => {
    expect(formatHeardDisplay({ heard: 0, total: 0 }, true)).toBeNull();
    expect(formatHeardDisplay({ heard: 0, total: 0 }, false)).toBeNull();
  });

  it("identity-required: returns 'Heard by N of M' when total > 0", () => {
    expect(formatHeardDisplay({ heard: 2, total: 5 }, true)).toBe("Heard by 2 of 5");
  });

  it("public link: returns play count only, never a denominator", () => {
    expect(formatHeardDisplay({ heard: 3, total: 3 }, false)).toBe("3 plays");
  });

  it("public link: singular play", () => {
    expect(formatHeardDisplay({ heard: 1, total: 1 }, false)).toBe("1 play");
  });

  it("public link with opens but no plays returns null", () => {
    expect(formatHeardDisplay({ heard: 0, total: 2 }, false)).toBeNull();
  });

  it("identity-required with zero opens but some plays shows ratio", () => {
    // total is 0 so falls through to play-count branch
    expect(formatHeardDisplay({ heard: 1, total: 0 }, true)).toBe("1 play");
  });
});

describe("formatVersionDelta", () => {
  it("returns null for a null delta", () => {
    expect(formatVersionDelta(null)).toBeNull();
  });

  it("formats a negative lufs and positive duration delta", () => {
    const result = formatVersionDelta({ lufsDelta: -0.8, durationDeltaMs: 3000 });
    expect(result).toBe("−0.8 LUFS · +0:03");
  });

  it("formats a positive lufs and negative duration delta", () => {
    const result = formatVersionDelta({ lufsDelta: 1.2, durationDeltaMs: -4000 });
    expect(result).toBe("+1.2 LUFS · −0:04");
  });

  it("formats zero values with correct sign", () => {
    const result = formatVersionDelta({ lufsDelta: 0, durationDeltaMs: 0 });
    expect(result).toBe("+0.0 LUFS · +0:00");
  });

  it("handles minute-spanning durations", () => {
    const result = formatVersionDelta({ lufsDelta: 0, durationDeltaMs: 65000 });
    expect(result).toBe("+0.0 LUFS · +1:05");
  });

  it("formats negative multi-minute duration correctly as mm:ss with sign", () => {
    // -125000ms = -2min 5sec → "−2:05"
    const result = formatVersionDelta({ lufsDelta: 0, durationDeltaMs: -125000 });
    expect(result).toBe("+0.0 LUFS · −2:05");
  });

  it("pads seconds to two digits when seconds < 10", () => {
    const result = formatVersionDelta({ lufsDelta: 0, durationDeltaMs: 63000 });
    expect(result).toBe("+0.0 LUFS · +1:03");
  });

  it("formats exactly 60 seconds as 1:00", () => {
    const result = formatVersionDelta({ lufsDelta: 0, durationDeltaMs: -60000 });
    expect(result).toBe("+0.0 LUFS · −1:00");
  });
});

// ---------------------------------------------------------------------------
// Feature 3 — heardByCount
// ---------------------------------------------------------------------------

function makeEvent(overrides: Partial<ActivityEvent> & { event_type: ActivityEvent["event_type"] }): ActivityEvent {
  return {
    event_id: Math.random().toString(36).slice(2),
    workspace_id: "wsp-test",
    link_id: "link-1",
    metadata: {},
    created_at: "2024-01-01T00:00:00Z",
    ...overrides,
  };
}

describe("heardByCount", () => {
  it("returns zero counts for an empty event list", () => {
    const result = heardByCount([]);
    expect(result).toEqual({ heard: 0, total: 0 });
  });

  it("counts distinct recipients who played as heard", () => {
    const events = [
      makeEvent({ event_type: "played_track", actor_recipient_label: "Alice" }),
      makeEvent({ event_type: "played_track", actor_recipient_label: "Alice" }), // duplicate
      makeEvent({ event_type: "played_track", actor_recipient_label: "Bob" }),
    ];
    const result = heardByCount(events);
    expect(result.heard).toBe(2);
  });

  it("counts distinct recipients who opened but did not play as total but not heard", () => {
    const events = [
      makeEvent({ event_type: "opened_link", actor_recipient_label: "Carol" }),
      makeEvent({ event_type: "played_track", actor_recipient_label: "Alice" }),
    ];
    const result = heardByCount(events);
    expect(result.heard).toBe(1);
    expect(result.total).toBe(2);
  });

  it("falls back to actor_user_id when actor_recipient_label is absent", () => {
    const events = [
      makeEvent({ event_type: "played_track", actor_user_id: "usr-1" }),
      makeEvent({ event_type: "played_track", actor_user_id: "usr-2" }),
    ];
    const result = heardByCount(events);
    expect(result.heard).toBe(2);
    expect(result.total).toBe(2);
  });

  it("ignores events that are neither opened_link nor played_track in total count", () => {
    const events = [
      makeEvent({ event_type: "downloaded_file", actor_recipient_label: "Dave" }),
      makeEvent({ event_type: "commented", actor_recipient_label: "Eve" }),
    ];
    const result = heardByCount(events);
    expect(result.heard).toBe(0);
    expect(result.total).toBe(0);
  });

  it("opened_link-only actors appear in total but not heard", () => {
    // Only opens, no plays — heard must stay 0 while total grows
    const events = [
      makeEvent({ event_type: "opened_link", actor_recipient_label: "Frank" }),
      makeEvent({ event_type: "opened_link", actor_recipient_label: "Grace" }),
      makeEvent({ event_type: "opened_link", actor_recipient_label: "Frank" }), // duplicate open
    ];
    const result = heardByCount(events);
    expect(result.heard).toBe(0);
    expect(result.total).toBe(2);
  });

  it("a played_track event alone (no separate open) still counts the actor in total", () => {
    // played_track must add to BOTH sets — total shouldn't require a separate opened_link
    const events = [
      makeEvent({ event_type: "played_track", actor_recipient_label: "Hank" }),
    ];
    const result = heardByCount(events);
    expect(result.heard).toBe(1);
    expect(result.total).toBe(1);
  });

  it("deduplicate: same actor opening multiple times and playing counts as one heard, one total", () => {
    const events = [
      makeEvent({ event_type: "opened_link", actor_recipient_label: "Iris" }),
      makeEvent({ event_type: "opened_link", actor_recipient_label: "Iris" }),
      makeEvent({ event_type: "played_track", actor_recipient_label: "Iris" }),
      makeEvent({ event_type: "played_track", actor_recipient_label: "Iris" }),
    ];
    const result = heardByCount(events);
    expect(result.heard).toBe(1);
    expect(result.total).toBe(1);
  });

  it("anonymous actors (no label, no user_id) are bucketed together — multiple events count as one slot", () => {
    // All anonymous events — both opens and plays — collapse into a single __anonymous__ key
    const events = [
      makeEvent({ event_type: "opened_link" }),  // no label, no user_id
      makeEvent({ event_type: "opened_link" }),
      makeEvent({ event_type: "played_track" }),
    ];
    const result = heardByCount(events);
    expect(result.total).toBe(1);
    expect(result.heard).toBe(1);
  });

  it("anonymous slot without a play is counted in total only", () => {
    const events = [
      makeEvent({ event_type: "opened_link" }),  // anonymous open
    ];
    const result = heardByCount(events);
    expect(result.total).toBe(1);
    expect(result.heard).toBe(0);
  });

  it("heard never exceeds total across a mixed event set", () => {
    // Invariant: heardActors ⊆ totalActors
    const events = [
      makeEvent({ event_type: "played_track", actor_recipient_label: "Alice" }),
      makeEvent({ event_type: "played_track", actor_recipient_label: "Bob" }),
      makeEvent({ event_type: "opened_link", actor_recipient_label: "Carol" }),
      makeEvent({ event_type: "played_track", actor_user_id: "usr-99" }),
      makeEvent({ event_type: "commented", actor_recipient_label: "Dave" }),
    ];
    const result = heardByCount(events);
    expect(result.heard).toBeLessThanOrEqual(result.total);
    // Verify concrete numbers: Alice + Bob + usr-99 heard (3); + Carol total (4)
    expect(result.heard).toBe(3);
    expect(result.total).toBe(4);
  });
});
