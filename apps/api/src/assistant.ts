import Anthropic from "@anthropic-ai/sdk";
import {
  answerWorkspaceQuestion,
  computeDeliverables,
  type AssistantAnswer,
  type Song,
  type Version,
  type WorkspaceSnapshot,
} from "@pmw/shared";

/**
 * Claude-backed "Ask the workspace" assistant.
 *
 * This is the real, intelligence-bearing version of the Ask feature. The
 * deterministic keyword matcher in `@pmw/shared` (`answerWorkspaceQuestion`)
 * remains the FALLBACK: when `ANTHROPIC_API_KEY` is absent — or any LLM call
 * fails — we degrade to it gracefully. So the whole feature is
 * behaviour-preserving until the key is configured, then "lights up", exactly
 * like the Supabase/JWT gating elsewhere in this API.
 *
 * Strictly read-only: the model is given a snapshot of workspace records as
 * context and asked to answer from them. It has no tools and cannot mutate
 * anything — which keeps the UI's "Ask cannot modify workspace state" promise
 * honest.
 */

const MODEL = "claude-opus-4-8";

let _client: Anthropic | null = null;
let _checked = false;

function getClient(): Anthropic | null {
  if (_checked) return _client;
  _checked = true;
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) {
    console.log("[assistant] ANTHROPIC_API_KEY not set — Ask uses the deterministic fallback");
    return null;
  }
  // maxRetries 1 keeps worst-case latency bounded (~2× timeout) before we fall
  // back to the deterministic matcher — this is a latency-sensitive endpoint.
  _client = new Anthropic({ apiKey: key, maxRetries: 1, timeout: 30_000 });
  console.log("[assistant] Claude-backed Ask enabled");
  return _client;
}

/** True when a real LLM backend is configured (the key is present). */
export function isAssistantLlmEnabled(): boolean {
  return getClient() !== null;
}

const SYSTEM_INSTRUCTIONS = [
  "You are the Ask assistant inside White Label, a private workspace for unreleased music.",
  "Answer the user's question using ONLY the workspace records provided below.",
  "You are strictly read-only: you cannot change, approve, upload, or send anything — never imply that you can.",
  "If the records don't contain the answer, say so plainly rather than guessing. Never invent songs, people, numbers, or events.",
  "Be concise and direct — a sentence or two is usually right. No preamble, no restating the question.",
  "Cite the specific records you used in the `citations` array, using the exact id strings shown in the context (song_id, version_id, room_id, or note_id). Only cite records that actually appear below.",
].join(" ");

const ANSWER_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    answer: { type: "string" },
    citations: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          type: { type: "string", enum: ["song", "version", "activity", "note", "room"] },
          id: { type: "string" },
          label: { type: "string" },
        },
        required: ["type", "id", "label"],
      },
    },
  },
  required: ["answer", "citations"],
};

function formatDuration(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return "unknown";
  const total = Math.round(ms / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${s.toString().padStart(2, "0")}`;
}

function truncate(text: string, max = 90): string {
  const oneLine = text.replace(/\s+/g, " ").trim();
  return oneLine.length > max ? `${oneLine.slice(0, max - 1)}…` : oneLine;
}

/**
 * Renders the workspace into a compact, DETERMINISTIC plain-text block.
 * Determinism matters: this is the prompt-cache prefix, so it must not contain
 * timestamps, random ids, or unsorted output — otherwise every request writes a
 * fresh cache entry instead of reading one. We iterate the snapshot arrays in
 * their existing (stable) order and never stamp the current time.
 */
export function buildWorkspaceContext(snapshot: WorkspaceSnapshot): string {
  const userName = (id?: string) =>
    snapshot.users.find((u) => u.user_id === id)?.display_name ?? "Unknown";
  const assetById = new Map(snapshot.assets.map((a) => [a.asset_id, a]));
  const lines: string[] = [];

  const ws = snapshot.workspaces[0];
  lines.push(`WORKSPACE: ${ws?.name ?? "Untitled"}`);
  lines.push(
    `Totals: ${snapshot.songs.length} songs, ${snapshot.versions.length} versions, ` +
      `${snapshot.notes.filter((n) => n.status === "open").length} open notes, ` +
      `${snapshot.rooms.length} rooms, ${snapshot.playlists.length} playlists.`,
  );

  lines.push("", "MEMBERS:");
  for (const m of snapshot.memberships) {
    lines.push(`- ${userName(m.user_id)} (${m.role}) [user_id: ${m.user_id}]`);
  }

  lines.push("", "ROOMS:");
  for (const r of snapshot.rooms) {
    lines.push(`- ${r.title} — type ${r.type}, status ${r.status} [room_id: ${r.room_id}]`);
  }

  lines.push("", "SONGS:");
  for (const song of snapshot.songs) {
    const current = snapshot.versions.find((v) => v.version_id === song.current_version_id);
    const asset = current ? assetById.get(current.file_asset_id) : undefined;
    const openNotes = snapshot.notes.filter((n) => n.song_id === song.song_id && n.status === "open").length;
    const deliverables = computeDeliverables(song, snapshot.versions, snapshot.assets);
    const plays = snapshot.activityEvents.filter(
      (e) => e.event_type === "played_track" && e.song_id === song.song_id,
    ).length;
    const parts = [
      `- "${song.title}"`,
      song.artist_display_name ? `by ${song.artist_display_name}` : null,
      `status ${song.status}`,
      `readiness ${song.release_readiness_status}`,
      song.bpm ? `${song.bpm} BPM` : null,
      song.song_key ? `key ${song.song_key}` : null,
      current ? `current ${current.version_label} (${current.type})` : "no current version",
      asset ? `${asset.loudness_lufs} LUFS · ${formatDuration(asset.duration_ms)}` : null,
      song.approved_version_id ? "approved" : "not approved",
      `${openNotes} open notes`,
      `${plays} plays`,
      deliverables.ready ? "deliverables ready" : `missing: ${deliverables.missing.join(", ") || "none"}`,
      `[song_id: ${song.song_id}${current ? `, current version_id: ${current.version_id}` : ""}]`,
    ].filter(Boolean);
    lines.push(parts.join(" · "));
  }

  lines.push("", "VERSIONS (for citing specific revisions):");
  for (const v of snapshot.versions) {
    const song = snapshot.songs.find((s) => s.song_id === v.song_id);
    lines.push(
      `- ${song?.title ?? "?"} ${v.version_label} (${v.type})` +
        `${v.is_current ? " — current" : ""}${v.is_approved ? " — approved" : ""} [version_id: ${v.version_id}]`,
    );
  }

  // Exclude `private`-visibility note bodies — those are personal scratch notes,
  // not for general synthesis. Bound the list so a high-note-count workspace
  // can't balloon the context (and the injection surface) without limit.
  const NOTE_LIMIT = 50;
  const openNotes = snapshot.notes.filter((n) => n.status === "open" && n.visibility !== "private");
  if (openNotes.length) {
    lines.push("", "OPEN NOTES:");
    for (const n of openNotes.slice(0, NOTE_LIMIT)) {
      const song = snapshot.songs.find((s) => s.song_id === n.song_id);
      const author = n.author_user_id ? userName(n.author_user_id) : n.author_guest_label ?? "Guest";
      lines.push(`- on "${song?.title ?? "?"}" by ${author}: "${truncate(n.body)}" [note_id: ${n.note_id}]`);
    }
    if (openNotes.length > NOTE_LIMIT) lines.push(`- …and ${openNotes.length - NOTE_LIMIT} more open notes.`);
  }

  // Links are described for context, but we don't expose link_id as a citable
  // id (the answer schema only supports song/version/room/note/activity), so we
  // don't tempt the model to cite something that would just be stripped.
  const activeLinks = snapshot.shareLinks.filter((l) => !l.revoked_at);
  if (activeLinks.length) {
    lines.push("", "SHARE LINKS:");
    for (const l of activeLinks) {
      lines.push(`- ${l.link_name ?? "Untitled link"} — ${l.access_mode}, ${l.target_type}`);
    }
  }

  if (snapshot.playlists.length) {
    lines.push("", "PLAYLISTS:");
    for (const p of snapshot.playlists) {
      const count = snapshot.playlistItems.filter((i) => i.playlist_id === p.playlist_id).length;
      lines.push(`- "${p.title}" — ${count} songs [playlist_id: ${p.playlist_id}]`);
    }
  }

  return lines.join("\n");
}

/** Builds an optional "the user is looking at X" line from the request focus. */
function buildFocusLine(
  snapshot: WorkspaceSnapshot,
  context?: { song_id?: string; version_id?: string },
): string | null {
  if (!context?.song_id && !context?.version_id) return null;
  let song: Song | undefined;
  let version: Version | undefined;
  if (context.version_id) {
    version = snapshot.versions.find((v) => v.version_id === context.version_id);
    if (version) song = snapshot.songs.find((s) => s.song_id === version!.song_id);
  }
  if (!song && context.song_id) song = snapshot.songs.find((s) => s.song_id === context.song_id);
  if (!song) return null;
  const focus = version
    ? `"${song.title}" — ${version.version_label}`
    : `"${song.title}"`;
  return `The user is currently looking at ${focus} (song_id: ${song.song_id}${version ? `, version_id: ${version.version_id}` : ""}). Weight the answer toward this if the question is ambiguous, but answer about the whole workspace when that's what's asked.`;
}

/** Drops any citation whose id doesn't resolve to a real record (anti-hallucination). */
function sanitizeAnswer(answer: AssistantAnswer, snapshot: WorkspaceSnapshot): AssistantAnswer {
  const ids = new Set<string>([
    ...snapshot.songs.map((s) => s.song_id),
    ...snapshot.versions.map((v) => v.version_id),
    ...snapshot.rooms.map((r) => r.room_id),
    ...snapshot.notes.map((n) => n.note_id),
    ...snapshot.activityEvents.map((e) => e.event_id),
  ]);
  return {
    answer: answer.answer,
    citations: (answer.citations ?? []).filter((c) => c && typeof c.id === "string" && ids.has(c.id)),
  };
}

/**
 * Answer a workspace question with Claude when available, else fall back to the
 * deterministic shared matcher. Never throws — failures degrade to the stub.
 */
export async function answerWorkspaceQuestionLlm(
  snapshot: WorkspaceSnapshot,
  question: string,
  context?: { song_id?: string; version_id?: string },
): Promise<AssistantAnswer> {
  const client = getClient();
  const trimmed = question.trim();
  if (!client || !trimmed) {
    return answerWorkspaceQuestion(snapshot, question);
  }

  try {
    const focus = buildFocusLine(snapshot, context);
    const userText = focus ? `${focus}\n\nQuestion: ${trimmed}` : `Question: ${trimmed}`;

    const response = await client.messages.create({
      model: MODEL,
      // 2048 gives the JSON envelope + a multi-citation answer real headroom;
      // at 1024 a long answer could truncate mid-JSON and fail to parse.
      max_tokens: 2048,
      // Stable instructions first, then the (larger) workspace context with a
      // cache breakpoint — so repeated questions in the same workspace read the
      // cache instead of re-paying for the context every time.
      system: [
        { type: "text", text: SYSTEM_INSTRUCTIONS },
        {
          type: "text",
          text: buildWorkspaceContext(snapshot),
          cache_control: { type: "ephemeral" },
        },
      ],
      output_config: {
        format: { type: "json_schema", schema: ANSWER_SCHEMA },
        // medium effort: this is reading comprehension over supplied records,
        // not open-ended reasoning — bound cost/latency without hurting quality.
        effort: "medium",
      },
      messages: [{ role: "user", content: userText }],
    });

    // A truncated response yields unparseable JSON; surface it distinctly
    // rather than letting it look like a generic API failure.
    if (response.stop_reason === "max_tokens") {
      console.warn("[assistant] response hit max_tokens — answer may be truncated; falling back");
      return answerWorkspaceQuestion(snapshot, question);
    }
    const text = response.content.find((b) => b.type === "text")?.text;
    if (!text) return answerWorkspaceQuestion(snapshot, question);
    const parsed = JSON.parse(text) as AssistantAnswer;
    return sanitizeAnswer(parsed, snapshot);
  } catch (err) {
    // Log the error class/status, not the raw SDK message (which can echo the
    // upstream HTTP response body into logs).
    const e = err as { name?: string; status?: number };
    console.warn(`[assistant] LLM ask failed (${e.name ?? "Error"}${e.status ? ` ${e.status}` : ""}) — falling back to deterministic`);
    return answerWorkspaceQuestion(snapshot, question);
  }
}
