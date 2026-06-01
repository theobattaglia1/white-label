/**
 * Route-level tests for POST /assistant/ask.
 *
 * Runs with no ANTHROPIC_API_KEY, so the handler returns the deterministic
 * fallback shape. Verifies the input guard and the response envelope.
 */

import { describe, it, expect, beforeEach } from "vitest";
import { buildApp } from "../server.js";
import { store } from "../store.js";

let app: Awaited<ReturnType<typeof buildApp>>;

beforeEach(async () => {
  delete process.env.ANTHROPIC_API_KEY;
  if (!app) app = await buildApp();
  store.reset();
});

describe("POST /assistant/ask", () => {
  it("returns an answer + citations array for a normal question", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/assistant/ask",
      headers: { "x-user-id": "usr-theo", "content-type": "application/json" },
      payload: { question: "give me a workspace summary" },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { answer: string; citations: unknown[] } }>();
    expect(typeof body.data.answer).toBe("string");
    expect(Array.isArray(body.data.citations)).toBe(true);
  });

  it("rejects an over-length question before placing any model call", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/assistant/ask",
      headers: { "x-user-id": "usr-theo", "content-type": "application/json" },
      payload: { question: "a".repeat(2001) },
    });
    expect(res.statusCode).toBe(400);
  });

  it("accepts optional song/version focus context without error", async () => {
    const song = store.data.songs[0];
    const res = await app.inject({
      method: "POST",
      url: "/assistant/ask",
      headers: { "x-user-id": "usr-theo", "content-type": "application/json" },
      payload: { question: "what's the status?", song_id: song.song_id, version_id: song.current_version_id },
    });
    expect(res.statusCode).toBe(200);
  });
});
