import { describe, expect, it } from "vitest";
import { clampComposerPct, laneMsAtX, laneTickPct, noteDisplayParts, parseTimestampPrefix, stripTimestampPrefix } from "../noteTime";

describe("parseTimestampPrefix", () => {
  it("parses @m:ss and strips it from the body", () => {
    expect(parseTimestampPrefix("@2:14 pull the snare")).toEqual({
      ms: 134_000,
      rest: "pull the snare",
    });
  });

  it("parses @0:05 (leading-zero seconds)", () => {
    expect(parseTimestampPrefix("@0:05 intro click bleed").ms).toBe(5_000);
  });

  it("parses minutes beyond 9 (@12:30)", () => {
    expect(parseTimestampPrefix("@12:30 outro fade").ms).toBe(750_000);
  });

  it("parses @h:mm:ss", () => {
    expect(parseTimestampPrefix("@1:02:03 set break")).toEqual({
      ms: 3_723_000,
      rest: "set break",
    });
  });

  it("handles a prefix-only body (rest is empty)", () => {
    expect(parseTimestampPrefix("@2:14")).toEqual({ ms: 134_000, rest: "" });
  });

  it("collapses whitespace between prefix and body", () => {
    expect(parseTimestampPrefix("@2:14   tighten the kick").rest).toBe("tighten the kick");
  });

  it("returns null for bodies without a prefix", () => {
    expect(parseTimestampPrefix("pull the snare 1dB")).toEqual({
      ms: null,
      rest: "pull the snare 1dB",
    });
  });

  it("rejects seconds >= 60", () => {
    expect(parseTimestampPrefix("@2:74 broken").ms).toBeNull();
  });

  it("rejects a prefix glued to text (@2:14x)", () => {
    expect(parseTimestampPrefix("@2:14x not a time").ms).toBeNull();
  });

  it("rejects mid-body timestamps", () => {
    expect(parseTimestampPrefix("snare @2:14 is late").ms).toBeNull();
  });

  it("rejects bare @ and malformed times", () => {
    expect(parseTimestampPrefix("@ hello").ms).toBeNull();
    expect(parseTimestampPrefix("@2: broken").ms).toBeNull();
    expect(parseTimestampPrefix("@:14 broken").ms).toBeNull();
  });
});

describe("stripTimestampPrefix", () => {
  it("strips a valid prefix", () => {
    expect(stripTimestampPrefix("@0:42 vocal up")).toBe("vocal up");
  });

  it("leaves bodies without a prefix untouched", () => {
    expect(stripTimestampPrefix("vocal up @0:42 maybe")).toBe("vocal up @0:42 maybe");
  });
});

describe("noteDisplayParts", () => {
  it("prefers the native timestamp field over a body prefix", () => {
    expect(noteDisplayParts({ body: "@2:14 pull the snare", timestamp_start_ms: 60_000 })).toEqual({
      ms: 60_000,
      body: "pull the snare",
    });
  });

  it("falls back to the body prefix when the field is missing", () => {
    expect(noteDisplayParts({ body: "@2:14 pull the snare" })).toEqual({
      ms: 134_000,
      body: "pull the snare",
    });
  });

  it("returns no timestamp when neither exists", () => {
    expect(noteDisplayParts({ body: "general vibe note" })).toEqual({
      ms: undefined,
      body: "general vibe note",
    });
  });

  it("keeps the body intact when only the field exists", () => {
    expect(noteDisplayParts({ body: "tighten kick", timestamp_start_ms: 1_000 })).toEqual({
      ms: 1_000,
      body: "tighten kick",
    });
  });
});

describe("laneMsAtX", () => {
  it("maps a pointer x to ms proportionally", () => {
    expect(laneMsAtX(250, 1000, 200_000)).toBe(50_000);
  });

  it("clamps to the lane edges", () => {
    expect(laneMsAtX(-40, 1000, 200_000)).toBe(0);
    expect(laneMsAtX(1400, 1000, 200_000)).toBe(200_000);
  });

  it("rounds to whole ms", () => {
    expect(laneMsAtX(1, 3, 100)).toBe(33);
  });

  it("returns 0 for an unmeasured lane or unknown duration", () => {
    expect(laneMsAtX(100, 0, 200_000)).toBe(0);
    expect(laneMsAtX(100, 1000, 0)).toBe(0);
  });
});

describe("laneTickPct", () => {
  it("positions a tick proportionally", () => {
    expect(laneTickPct(30_000, 120_000)).toBe(25);
  });

  it("clamps out-of-range timestamps", () => {
    expect(laneTickPct(-5_000, 120_000)).toBe(0);
    expect(laneTickPct(500_000, 120_000)).toBe(100);
  });

  it("is 0 when the duration is unknown", () => {
    expect(laneTickPct(30_000, 0)).toBe(0);
  });
});

describe("clampComposerPct", () => {
  it("passes through a center position", () => {
    expect(clampComposerPct(50, 1000, 300)).toBe(50);
  });

  it("clamps near the edges so the popover stays inside the lane", () => {
    // 300px composer on a 1000px lane → half-width is 15%
    expect(clampComposerPct(2, 1000, 300)).toBe(15);
    expect(clampComposerPct(99, 1000, 300)).toBe(85);
  });

  it("falls back to center when the lane is unmeasured", () => {
    expect(clampComposerPct(80, 0, 300)).toBe(50);
  });

  it("centers when the composer is wider than the lane", () => {
    expect(clampComposerPct(10, 200, 600)).toBe(50);
  });
});
