/**
 * Tests for the pure helper functions in api.ts plus the request() function's
 * auth-header and error-handling behaviour.
 *
 * The supabase client is stubbed out so these tests run without any network
 * or browser auth setup.
 */
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import type { FileAsset, Version } from "@pmw/shared";

// Hoist the auth mock before the api module is loaded. vi.mock is hoisted by
// Vitest to the top of the module even when written here.
vi.mock("../auth", () => ({
  supabase: {
    auth: {
      getSession: vi.fn(),
    },
  },
}));

// Import the mocked module and the module under test AFTER vi.mock.
import { supabase } from "../auth";
import { api, assetForVersion, versionsForSong } from "../api";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

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
    created_at: "2024-01-01T00:00:00Z",
    ...overrides,
  };
}

function makeAsset(overrides: Partial<FileAsset>): FileAsset {
  return {
    asset_id: "asset-1",
    workspace_id: "wsp-test",
    original_filename: "track.mp3",
    key_original: "audio/track.mp3",
    file_size_bytes: 1024,
    checksum_sha256: "abc",
    duration_ms: 180000,
    sample_rate: 44100,
    bit_depth: 16,
    loudness_lufs: -14,
    true_peak_db: -1,
    virus_scan_status: "clean",
    transcoding_status: "ready",
    waveform_peaks: [],
    created_at: "2024-01-01T00:00:00Z",
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// assetForVersion
// ---------------------------------------------------------------------------
describe("assetForVersion", () => {
  const assets = [
    makeAsset({ asset_id: "asset-1" }),
    makeAsset({ asset_id: "asset-2" }),
  ];

  it("returns the asset matching the version's file_asset_id", () => {
    const version = makeVersion({ file_asset_id: "asset-2" });
    expect(assetForVersion(assets, version)?.asset_id).toBe("asset-2");
  });

  it("returns undefined when version is undefined", () => {
    expect(assetForVersion(assets, undefined)).toBeUndefined();
  });

  it("returns undefined when no asset matches", () => {
    const version = makeVersion({ file_asset_id: "asset-999" });
    expect(assetForVersion(assets, version)).toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// versionsForSong
// ---------------------------------------------------------------------------
describe("versionsForSong", () => {
  const versions = [
    makeVersion({ version_id: "ver-1", song_id: "song-A", version_number: 2 }),
    makeVersion({ version_id: "ver-2", song_id: "song-A", version_number: 1 }),
    makeVersion({ version_id: "ver-3", song_id: "song-B", version_number: 1 }),
  ];

  it("returns only versions that belong to the requested song", () => {
    const result = versionsForSong(versions, "song-A");
    expect(result.every((v) => v.song_id === "song-A")).toBe(true);
    expect(result).toHaveLength(2);
  });

  it("returns versions sorted ascending by version_number", () => {
    const result = versionsForSong(versions, "song-A");
    expect(result[0].version_number).toBe(1);
    expect(result[1].version_number).toBe(2);
  });

  it("returns an empty array when no versions exist for that song", () => {
    expect(versionsForSong(versions, "song-MISSING")).toEqual([]);
  });

  it("does not mutate the original array order", () => {
    const original = [
      makeVersion({ version_id: "ver-1", song_id: "song-A", version_number: 3 }),
      makeVersion({ version_id: "ver-2", song_id: "song-A", version_number: 1 }),
    ];
    versionsForSong(original, "song-A");
    // original[0] should still be version_number 3 — sort must not mutate
    expect(original[0].version_number).toBe(3);
  });
});

// ---------------------------------------------------------------------------
// request function — auth header and error-path behaviour
// ---------------------------------------------------------------------------
describe("request (via api.*)", () => {
  const getSessionMock = supabase.auth.getSession as ReturnType<typeof vi.fn>;

  beforeEach(() => {
    vi.resetAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("sends Bearer token when session has an access_token", async () => {
    getSessionMock.mockResolvedValue({
      data: { session: { access_token: "tok-abc" } },
    });

    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify({ data: { room: {}, songs: [], versions: [], assets: [], notes: [], links: [] } }), { status: 200 })
    );

    await api.room("room-test");

    const [_url, init] = fetchSpy.mock.calls[0];
    const headers = init?.headers as Record<string, string>;
    expect(headers["authorization"]).toBe("Bearer tok-abc");
  });

  it("falls back to x-user-id header when no session exists", async () => {
    getSessionMock.mockResolvedValue({
      data: { session: null },
    });

    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify({ data: [] }), { status: 200 })
    );

    await api.inbox();

    const [_url, init] = fetchSpy.mock.calls[0];
    const headers = init?.headers as Record<string, string>;
    expect(headers["x-user-id"]).toBe("usr-theo");
    expect(headers["authorization"]).toBeUndefined();
  });

  it("throws the server's error message when the API returns an error payload", async () => {
    getSessionMock.mockResolvedValue({ data: { session: null } });

    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify({ error: "Not found" }), { status: 404 })
    );

    await expect(api.room("room-missing")).rejects.toThrow("Not found");
  });

  it("throws a generic 'Request failed' when the response is non-OK and has no error field", async () => {
    getSessionMock.mockResolvedValue({ data: { session: null } });

    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify({ data: null }), { status: 500 })
    );

    await expect(api.room("room-broken")).rejects.toThrow("Request failed");
  });
});
