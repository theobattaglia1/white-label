/**
 * voiceNote.ts — voice-note marker convention (pure functions, vitest-covered).
 *
 * A voice note is an ordinary note whose body carries a machine-readable
 * marker at the start: `[voice](URL) optional text`. Pure convention — no
 * schema change. Clients that understand the marker render an inline audio
 * chip; clients that don't show the link text, which degrades honestly.
 */

/** `[voice](https://…)` at the very start of the body, then optional whitespace. */
const VOICE_MARKER_RE = /^\[voice\]\((https?:\/\/[^\s)]+)\)\s*/;

export type ParsedVoiceMarker = {
  /** Audio URL, or null when the body carries no marker. */
  url: string | null;
  /** Body with the marker stripped. Unchanged when url is null. */
  rest: string;
};

/** Parse a leading `[voice](URL)` marker out of a note body. */
export function parseVoiceMarker(body: string): ParsedVoiceMarker {
  const match = body.match(VOICE_MARKER_RE);
  if (!match) return { url: null, rest: body };
  return { url: match[1], rest: body.slice(match[0].length) };
}

/** Build a voice-note body: marker first, optional text after. */
export function buildVoiceBody(url: string, text?: string): string {
  const rest = text?.trim();
  return rest ? `[voice](${url}) ${rest}` : `[voice](${url})`;
}

/**
 * Pick the best MediaRecorder mime type the browser supports.
 * Prefers webm/opus (Chrome, Firefox), falls back to mp4 (Safari),
 * returns undefined to let the browser choose its default.
 */
export function pickRecordingMime(isSupported: (type: string) => boolean): string | undefined {
  const candidates = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4"];
  for (const type of candidates) {
    try {
      if (isSupported(type)) return type;
    } catch {
      // isTypeSupported threw — treat as unsupported
    }
  }
  return undefined;
}

/** File extension for a recording mime type (container only, codecs ignored). */
export function extForMime(mime: string): string {
  const container = mime.split(";")[0].trim().toLowerCase();
  switch (container) {
    case "audio/webm": return ".webm";
    case "audio/mp4": return ".m4a";
    case "audio/mpeg": return ".mp3";
    case "audio/ogg": return ".ogg";
    case "audio/wav":
    case "audio/x-wav": return ".wav";
    default: return ".webm";
  }
}
