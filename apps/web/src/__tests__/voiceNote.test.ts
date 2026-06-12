import { describe, expect, it } from "vitest";
import { buildVoiceBody, extForMime, parseVoiceMarker, pickRecordingMime } from "../voiceNote";

describe("parseVoiceMarker", () => {
  it("parses a marker-only body", () => {
    expect(parseVoiceMarker("[voice](https://x.test/a.webm)")).toEqual({
      url: "https://x.test/a.webm",
      rest: "",
    });
  });

  it("parses marker + trailing text, stripping the separator whitespace", () => {
    expect(parseVoiceMarker("[voice](https://x.test/a.webm) pull the snare")).toEqual({
      url: "https://x.test/a.webm",
      rest: "pull the snare",
    });
  });

  it("returns null url for a plain text body, unchanged", () => {
    expect(parseVoiceMarker("pull the snare")).toEqual({ url: null, rest: "pull the snare" });
  });

  it("ignores a marker that is not at the start", () => {
    const body = "listen [voice](https://x.test/a.webm)";
    expect(parseVoiceMarker(body)).toEqual({ url: null, rest: body });
  });

  it("rejects non-http(s) schemes", () => {
    const body = "[voice](javascript:alert(1))";
    expect(parseVoiceMarker(body)).toEqual({ url: null, rest: body });
  });

  it("does not swallow URLs containing spaces or close-parens", () => {
    expect(parseVoiceMarker("[voice](https://x.test/a).webm) hi").url).toBe("https://x.test/a");
  });
});

describe("buildVoiceBody", () => {
  it("builds marker-only when there is no text", () => {
    expect(buildVoiceBody("https://x.test/a.webm")).toBe("[voice](https://x.test/a.webm)");
  });

  it("appends trimmed text after the marker", () => {
    expect(buildVoiceBody("https://x.test/a.webm", "  too hot  ")).toBe(
      "[voice](https://x.test/a.webm) too hot",
    );
  });

  it("round-trips through parseVoiceMarker", () => {
    const body = buildVoiceBody("https://x.test/a.m4a", "verse 2");
    expect(parseVoiceMarker(body)).toEqual({ url: "https://x.test/a.m4a", rest: "verse 2" });
  });
});

describe("pickRecordingMime", () => {
  it("prefers webm/opus when supported", () => {
    expect(pickRecordingMime(() => true)).toBe("audio/webm;codecs=opus");
  });

  it("falls back to mp4 when webm is unsupported (Safari)", () => {
    expect(pickRecordingMime((t) => t === "audio/mp4")).toBe("audio/mp4");
  });

  it("returns undefined when nothing is supported (browser default)", () => {
    expect(pickRecordingMime(() => false)).toBeUndefined();
  });

  it("treats a throwing isSupported as unsupported", () => {
    expect(pickRecordingMime(() => { throw new Error("nope"); })).toBeUndefined();
  });
});

describe("extForMime", () => {
  it("maps containers, ignoring codecs", () => {
    expect(extForMime("audio/webm;codecs=opus")).toBe(".webm");
    expect(extForMime("audio/mp4")).toBe(".m4a");
    expect(extForMime("audio/ogg")).toBe(".ogg");
  });

  it("defaults unknown types to .webm", () => {
    expect(extForMime("application/octet-stream")).toBe(".webm");
  });
});
