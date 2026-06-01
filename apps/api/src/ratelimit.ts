/**
 * Minimal in-memory fixed-window rate limiter.
 *
 * Single-instance only: state lives in this process's memory, so on a
 * multi-dyno deploy each instance counts independently (the effective limit is
 * max × instances). That's fine for the current single Render service and for
 * the purpose here — blunting cost/abuse on the LLM-backed Ask route, not
 * precise quota enforcement. Swap for a shared store (Redis) if we scale out.
 */

type Window = { count: number; resetAt: number };

const windows = new Map<string, Window>();

export interface RateLimitResult {
  allowed: boolean;
  /** Milliseconds until the current window resets (0 when allowed). */
  retryAfterMs: number;
}

/**
 * Record a hit against `key` and report whether it's within `max` per
 * `windowMs`. `now` is injectable for deterministic tests.
 */
export function rateLimit(
  key: string,
  max: number,
  windowMs: number,
  now: number = Date.now(),
): RateLimitResult {
  const w = windows.get(key);
  if (!w || now >= w.resetAt) {
    windows.set(key, { count: 1, resetAt: now + windowMs });
    return { allowed: true, retryAfterMs: 0 };
  }
  if (w.count >= max) {
    return { allowed: false, retryAfterMs: w.resetAt - now };
  }
  w.count += 1;
  return { allowed: true, retryAfterMs: 0 };
}

/** Clear all windows — used by tests (and any future maintenance reset). */
export function resetRateLimits(): void {
  windows.clear();
}
