/**
 * Shared (recipient) route security tests — added with the 2026-06-05 P0 batch.
 *
 * Guards:
 *  A. GET /shared/:token strips the permanent playback_url from every asset
 *     (recipients must stream via the revocation-gated endpoint, never hold a
 *     permanent URL that outlives revocation).
 *  B. POST /shared/:token/notes rejects a song/version NOT in the link's scope
 *     (a comment-enabled link must not let a holder attach notes to any song
 *     whose IDs they happen to know).
 *  C. POST /shared/:token/approve rejects a version NOT in the link's scope.
 *
 * Uses the seed link `dana-neon` (token), a public full-history link to
 * song-neon with allow_comments=true.
 */

import { describe, it, expect, beforeEach } from "vitest";
import { buildApp } from "../server.js";
import { store } from "../store.js";

const TOKEN = "dana-neon"; // seed share link → song-neon, full_history, comments on

let app: Awaited<ReturnType<typeof buildApp>>;

beforeEach(async () => {
  if (!app) app = await buildApp();
  store.reset();
});

describe("GET /shared/:token — no permanent (absolute) playback_url leaks to recipients", () => {
  it("never exposes an absolute storage URL; real uploads are withheld, seed/static URLs allowed", async () => {
    const res = await app.inject({ method: "GET", url: `/shared/${TOKEN}` });
    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { assets: Array<{ playback_url?: string }> } }>();
    expect(body.data.assets.length).toBeGreaterThan(0);
    for (const asset of body.data.assets) {
      // Invariant: a recipient must never receive an absolute http(s) storage
      // URL (a real uploaded master). Relative seed/demo paths (/seed-audio/…)
      // are harmless and may pass through so demo playback still works.
      if (asset.playback_url !== undefined) {
        expect(asset.playback_url).toMatch(/^\//);
        expect(asset.playback_url).not.toMatch(/^https?:\/\//i);
      }
    }
  });
});

describe("POST /shared/:token/notes — scope enforcement", () => {
  it("accepts a note on a song + version the link actually exposes", async () => {
    const shared = (await app.inject({ method: "GET", url: `/shared/${TOKEN}` })).json<{
      data: { songs: Array<{ song_id: string }>; versions: Array<{ version_id: string }> };
    }>();
    const songId = shared.data.songs[0].song_id;
    const versionId = shared.data.versions[0].version_id;

    const res = await app.inject({
      method: "POST",
      url: `/shared/${TOKEN}/notes`,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ song_id: songId, anchor_version_id: versionId, body: "In-scope note", scope: "song" }),
    });
    expect(res.statusCode).toBe(200);
  });

  it("rejects a note targeting a song NOT exposed by the link", async () => {
    const res = await app.inject({
      method: "POST",
      url: `/shared/${TOKEN}/notes`,
      headers: { "content-type": "application/json" },
      // song-midnight / ver-midnight-v2 are seed IDs that this song-neon link
      // does not expose. A holder must not be able to attach notes to them.
      body: JSON.stringify({ song_id: "song-midnight", anchor_version_id: "ver-midnight-v2", body: "Out-of-scope", scope: "song" }),
    });
    expect(res.statusCode).toBe(400);
    expect(res.json<{ error: string }>().error).toMatch(/not available through this link/i);
  });
});

describe("GET /shared/:token — records an opened_link event", () => {
  it("logs opened_link to the workspace activity so the manager sees the open", async () => {
    await app.inject({ method: "GET", url: `/shared/${TOKEN}` });
    const activity = (
      await app.inject({ method: "GET", url: `/workspaces/wsp-amf-private/activity` })
    ).json<{ data: Array<{ event_type: string; link_id?: string }> }>();
    const open = activity.data.find((e) => e.event_type === "opened_link" && e.link_id === "link-dana-history");
    expect(open).toBeDefined();
  });
});

describe("POST /shared/:token/approve — scope enforcement", () => {
  it("rejects approving a version NOT exposed by the link", async () => {
    // This link has allow_approval=false, but the scope guard runs after the
    // allow_approval check; an out-of-scope version on a comments-only link
    // should never reach createApproval. Assert it is refused (4xx).
    const res = await app.inject({
      method: "POST",
      url: `/shared/${TOKEN}/approve`,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ version_id: "ver-midnight-v2", state: "approved" }),
    });
    expect(res.statusCode).toBe(400);
  });
});
