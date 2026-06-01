/**
 * Route-level tests for POST /assistant/ask.
 *
 * Runs with no ANTHROPIC_API_KEY, so the handler returns the deterministic
 * fallback shape. Verifies the input guard and the response envelope.
 */

import { describe, it, expect, beforeEach } from "vitest";
import { buildApp } from "../server.js";
import { store } from "../store.js";
import { resetRateLimits } from "../ratelimit.js";

let app: Awaited<ReturnType<typeof buildApp>>;

beforeEach(async () => {
  delete process.env.ANTHROPIC_API_KEY;
  if (!app) app = await buildApp();
  store.reset();
  resetRateLimits();
});

const askHeaders = (userID: string) => ({
  "x-user-id": userID,
  "content-type": "application/json",
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
      headers: askHeaders("usr-theo"),
      payload: { question: "what's the status?", song_id: song.song_id, version_id: song.current_version_id },
    });
    expect(res.statusCode).toBe(200);
  });

  it("rate-limits a single identity after the per-window cap (20/min)", async () => {
    const ask = () =>
      app.inject({
        method: "POST",
        url: "/assistant/ask",
        headers: askHeaders("usr-ratelimit"),
        payload: { question: "summary" },
      });
    // First 20 succeed; the 21st is throttled.
    for (let i = 0; i < 20; i++) expect((await ask()).statusCode).toBe(200);
    const throttled = await ask();
    expect(throttled.statusCode).toBe(429);
    expect(throttled.headers["retry-after"]).toBeDefined();
  });

  it("isolates rate-limit windows per identity", async () => {
    const ask = (uid: string) =>
      app.inject({ method: "POST", url: "/assistant/ask", headers: askHeaders(uid), payload: { question: "summary" } });
    for (let i = 0; i < 20; i++) await ask("usr-heavy");
    expect((await ask("usr-heavy")).statusCode).toBe(429);
    // A different identity is unaffected.
    expect((await ask("usr-light")).statusCode).toBe(200);
  });
});

describe("GET /assistant/status", () => {
  it("reports llm_enabled false when no ANTHROPIC_API_KEY is set", async () => {
    const res = await app.inject({ method: "GET", url: "/assistant/status" });
    expect(res.statusCode).toBe(200);
    const body = res.json<{ data: { llm_enabled: boolean } }>();
    expect(body.data.llm_enabled).toBe(false);
  });
});
