/** Unit tests for the in-memory fixed-window rate limiter. */

import { describe, it, expect, beforeEach } from "vitest";
import { rateLimit, resetRateLimits } from "../ratelimit.js";

beforeEach(() => resetRateLimits());

describe("rateLimit", () => {
  it("allows up to `max` hits per window, then denies", () => {
    const t0 = 1_000;
    for (let i = 0; i < 3; i++) {
      expect(rateLimit("k", 3, 1000, t0).allowed).toBe(true);
    }
    const denied = rateLimit("k", 3, 1000, t0);
    expect(denied.allowed).toBe(false);
    expect(denied.retryAfterMs).toBeGreaterThan(0);
    expect(denied.retryAfterMs).toBeLessThanOrEqual(1000);
  });

  it("resets after the window elapses", () => {
    const t0 = 1_000;
    rateLimit("k", 1, 1000, t0);
    expect(rateLimit("k", 1, 1000, t0).allowed).toBe(false); // same window
    expect(rateLimit("k", 1, 1000, t0 + 1000).allowed).toBe(true); // next window
  });

  it("tracks distinct keys independently", () => {
    const t0 = 1_000;
    rateLimit("a", 1, 1000, t0);
    expect(rateLimit("a", 1, 1000, t0).allowed).toBe(false);
    expect(rateLimit("b", 1, 1000, t0).allowed).toBe(true);
  });

  it("reports retryAfterMs counting down within the window", () => {
    const t0 = 1_000;
    rateLimit("k", 1, 1000, t0);
    const r = rateLimit("k", 1, 1000, t0 + 400);
    expect(r.allowed).toBe(false);
    expect(r.retryAfterMs).toBe(600);
  });
});
