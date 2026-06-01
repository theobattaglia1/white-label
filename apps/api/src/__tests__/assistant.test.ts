/**
 * Tests for the Claude-backed Ask assistant.
 *
 * These run with NO ANTHROPIC_API_KEY set, so they exercise the
 * behaviour-preserving FALLBACK path (deterministic shared matcher) plus the
 * pure, LLM-independent helpers (context builder, enablement flag). The actual
 * model call is gated and not exercised here — no network, no key.
 */

import { describe, it, expect, beforeAll } from "vitest";
import { createSeedSnapshot, answerWorkspaceQuestion } from "@pmw/shared";
import {
  answerWorkspaceQuestionLlm,
  buildWorkspaceContext,
  isAssistantLlmEnabled,
} from "../assistant.js";

beforeAll(() => {
  delete process.env.ANTHROPIC_API_KEY; // guarantee the fallback path
});

const snapshot = createSeedSnapshot();

describe("isAssistantLlmEnabled", () => {
  it("is false when ANTHROPIC_API_KEY is absent", () => {
    expect(isAssistantLlmEnabled()).toBe(false);
  });
});

describe("answerWorkspaceQuestionLlm (fallback path)", () => {
  it("matches the deterministic matcher exactly when no key is configured", async () => {
    for (const q of [
      "what is missing deliverables?",
      "who hasn't heard the latest?",
      "what changed between mix versions?",
      "any public links expiring?",
      "give me a workspace summary",
    ]) {
      const viaLlm = await answerWorkspaceQuestionLlm(snapshot, q);
      const viaStub = answerWorkspaceQuestion(snapshot, q);
      expect(viaLlm).toEqual(viaStub);
    }
  });

  it("never throws and returns the answer shape for an empty question", async () => {
    const res = await answerWorkspaceQuestionLlm(snapshot, "   ");
    expect(res).toHaveProperty("answer");
    expect(Array.isArray(res.citations)).toBe(true);
  });

  it("ignores focus context on the fallback path without error", async () => {
    const song = snapshot.songs[0];
    const res = await answerWorkspaceQuestionLlm(snapshot, "summary", {
      song_id: song.song_id,
      version_id: song.current_version_id,
    });
    expect(typeof res.answer).toBe("string");
  });
});

describe("buildWorkspaceContext", () => {
  const ctx = buildWorkspaceContext(snapshot);

  it("is deterministic across calls (stable prompt-cache prefix)", () => {
    expect(buildWorkspaceContext(snapshot)).toBe(ctx);
  });

  it("contains no current-time stamp that would bust the cache", () => {
    // The builder must not stamp Date.now(); a fresh year string appearing
    // would signal an accidental timestamp injection.
    const thisYear = new Date().getFullYear().toString();
    // Seed data has fixed ISO dates; the builder itself emits none — so the
    // only way the current year shows up is an accidental new Date() call.
    // (Seed timestamps are intentionally not rendered by the builder.)
    expect(ctx.includes(`${thisYear}-`)).toBe(false);
  });

  it("exposes citable ids for every record type the schema allows", () => {
    expect(ctx).toContain("song_id:");
    expect(ctx).toContain("version_id:");
    expect(ctx).toContain("room_id:");
    expect(ctx).toMatch(/SONGS:/);
    expect(ctx).toMatch(/VERSIONS/);
    // Every seeded song title should appear in the context.
    for (const song of snapshot.songs) {
      expect(ctx).toContain(song.title);
    }
  });
});
