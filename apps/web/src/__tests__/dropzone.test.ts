import { describe, expect, it } from "vitest";
import {
  cleanSongTitle,
  collectFromEntries,
  describeDragItems,
  fileExtension,
  isAudioFile,
  planIngestion,
  runWithConcurrency,
  shouldReactToDrag,
  summarizeBatch,
  titleCaseFolderName,
  type DroppedEntry,
  type EntryLike,
} from "../dropzone";

// ---------------------------------------------------------------------------
// Fakes for FileSystemEntry traversal
// ---------------------------------------------------------------------------

function fakeFile(name: string): File {
  return new File(["x"], name, { type: "application/octet-stream" });
}

function fileEntry(name: string): EntryLike {
  return {
    isFile: true,
    isDirectory: false,
    name,
    file: (resolve) => resolve(fakeFile(name)),
  };
}

/** Directory whose reader yields children in chunks (real readEntries batches at 100). */
function dirEntry(name: string, children: EntryLike[], chunkSize = 2): EntryLike {
  return {
    isFile: false,
    isDirectory: true,
    name,
    createReader: () => {
      let cursor = 0;
      return {
        readEntries: (resolve) => {
          const chunk = children.slice(cursor, cursor + chunkSize);
          cursor += chunk.length;
          resolve(chunk);
        },
      };
    },
  };
}

// ---------------------------------------------------------------------------
// File filtering
// ---------------------------------------------------------------------------

describe("fileExtension / isAudioFile", () => {
  it("extracts lower-cased extensions", () => {
    expect(fileExtension("Fences_22.WAV")).toBe("wav");
    expect(fileExtension("song.v2.mp3")).toBe("mp3");
    expect(fileExtension("no-extension")).toBe("");
    expect(fileExtension(".hidden")).toBe("");
    expect(fileExtension("trailing.")).toBe("");
  });

  it("accepts every supported audio format, case-insensitively", () => {
    for (const ext of ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg"]) {
      expect(isAudioFile(`track.${ext}`)).toBe(true);
      expect(isAudioFile(`TRACK.${ext.toUpperCase()}`)).toBe(true);
    }
  });

  it("rejects non-audio files", () => {
    for (const name of ["notes.txt", "cover.png", "session.als", "mix.pdf", "README", "track.mp3.zip"]) {
      expect(isAudioFile(name)).toBe(false);
    }
  });
});

// ---------------------------------------------------------------------------
// Title cleaning
// ---------------------------------------------------------------------------

describe("cleanSongTitle", () => {
  it("drops the extension and turns separators into spaces", () => {
    expect(cleanSongTitle("fences_22.wav")).toBe("fences 22");
    expect(cleanSongTitle("the-first-night.mp3")).toBe("the first night");
    expect(cleanSongTitle("My  Track.flac")).toBe("My Track");
  });

  it("strips a trailing vN token (trivially safe) but nothing else", () => {
    expect(cleanSongTitle("duel-v5.m4a")).toBe("duel");
    expect(cleanSongTitle("best-of-me-v2.mp3")).toBe("best of me");
    expect(cleanSongTitle("Best Of Me V12.wav")).toBe("Best Of Me");
    // v-token NOT at the end → keep as-is
    expect(cleanSongTitle("the-first-night-v1-pitch.mp3")).toBe("the first night v1 pitch");
    // "v" followed by non-digits is a word, not a version
    expect(cleanSongTitle("velvet.mp3")).toBe("velvet");
    expect(cleanSongTitle("love-vibes.mp3")).toBe("love vibes");
  });

  it("never returns an empty title", () => {
    expect(cleanSongTitle("v2.wav")).toBe("v2");
    expect(cleanSongTitle("___.mp3").length).toBeGreaterThan(0);
  });
});

describe("titleCaseFolderName", () => {
  it("title-cases and normalizes separators", () => {
    expect(titleCaseFolderName("demos_june")).toBe("Demos June");
    expect(titleCaseFolderName("DEMOS-JUNE")).toBe("Demos June");
    expect(titleCaseFolderName("rough mixes 2026")).toBe("Rough Mixes 2026");
    expect(titleCaseFolderName("Already Titled")).toBe("Already Titled");
  });
});

// ---------------------------------------------------------------------------
// Drag heuristics
// ---------------------------------------------------------------------------

describe("shouldReactToDrag", () => {
  it("reacts only when actual files are dragged", () => {
    expect(shouldReactToDrag(["Files"])).toBe(true);
    expect(shouldReactToDrag(["text/plain", "Files"])).toBe(true);
    // text or images dragged from another tab must NOT raise the overlay
    expect(shouldReactToDrag(["text/plain"])).toBe(false);
    expect(shouldReactToDrag(["text/html", "text/uri-list"])).toBe(false);
    expect(shouldReactToDrag([])).toBe(false);
    expect(shouldReactToDrag(null)).toBe(false);
    expect(shouldReactToDrag(undefined)).toBe(false);
  });
});

describe("describeDragItems", () => {
  it("counts file-kind items when the browser reveals them", () => {
    expect(describeDragItems(["file"])).toBe("1 ITEM");
    expect(describeDragItems(["file", "file", "file"])).toBe("3 ITEMS");
    expect(describeDragItems(["file", "string"])).toBe("1 ITEM");
  });

  it("returns null (generic line) when counts are unknowable", () => {
    expect(describeDragItems(null)).toBeNull();
    expect(describeDragItems(undefined)).toBeNull();
    expect(describeDragItems([])).toBeNull();
    expect(describeDragItems(["string"])).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// Folder traversal
// ---------------------------------------------------------------------------

describe("collectFromEntries", () => {
  it("collects loose audio files with no folder tag", async () => {
    const { entries, skipped } = await collectFromEntries([
      fileEntry("a.mp3"),
      fileEntry("b.wav"),
    ]);
    expect(entries.map((e) => e.file.name)).toEqual(["a.mp3", "b.wav"]);
    expect(entries.every((e) => e.folderName === null)).toBe(true);
    expect(skipped).toBe(0);
  });

  it("silently skips non-audio and counts them", async () => {
    const { entries, skipped } = await collectFromEntries([
      fileEntry("a.mp3"),
      fileEntry("art.png"),
      fileEntry("notes.txt"),
    ]);
    expect(entries.map((e) => e.file.name)).toEqual(["a.mp3"]);
    expect(skipped).toBe(2);
  });

  it("traverses folders recursively; nested files inherit the TOP-LEVEL folder", async () => {
    const root = dirEntry("demos_june", [
      fileEntry("01 one.mp3"),
      fileEntry("02 two.wav"),
      dirEntry("stems", [fileEntry("kick.aiff"), fileEntry("readme.txt")]),
      fileEntry("cover.jpg"),
    ]);
    const { entries, skipped } = await collectFromEntries([root]);
    expect(entries.map((e) => e.file.name).sort()).toEqual(["01 one.mp3", "02 two.wav", "kick.aiff"]);
    expect(entries.every((e) => e.folderName === "demos_june")).toBe(true);
    expect(skipped).toBe(2); // readme.txt + cover.jpg
  });

  it("drains chunked directory readers completely", async () => {
    const many = Array.from({ length: 7 }, (_, i) => fileEntry(`t${i}.mp3`));
    const { entries } = await collectFromEntries([dirEntry("big", many, 3)]);
    expect(entries).toHaveLength(7);
  });

  it("handles folder + loose files mixed", async () => {
    const { entries } = await collectFromEntries([
      fileEntry("loose.mp3"),
      dirEntry("ep", [fileEntry("a.mp3")]),
    ]);
    expect(entries.find((e) => e.file.name === "loose.mp3")?.folderName).toBeNull();
    expect(entries.find((e) => e.file.name === "a.mp3")?.folderName).toBe("ep");
  });
});

// ---------------------------------------------------------------------------
// Ingestion planning
// ---------------------------------------------------------------------------

function entry(name: string, folderName: string | null = null): DroppedEntry {
  return { file: fakeFile(name), folderName };
}

describe("planIngestion", () => {
  it("loose files become plain library adds", () => {
    const plan = planIngestion([entry("b.mp3"), entry("a.mp3")]);
    expect(plan.libraryAdds.map((f) => f.name)).toEqual(["a.mp3", "b.mp3"]);
    expect(plan.playlists).toEqual([]);
  });

  it("a folder becomes one playlist named after it (title-cased), files in filename order", () => {
    const plan = planIngestion([
      entry("02 second.mp3", "demos_june"),
      entry("01 first.mp3", "demos_june"),
      entry("10 tenth.mp3", "demos_june"),
    ]);
    expect(plan.libraryAdds).toEqual([]);
    expect(plan.playlists).toHaveLength(1);
    expect(plan.playlists[0].name).toBe("Demos June");
    // numeric-aware filename order: 01, 02, 10
    expect(plan.playlists[0].files.map((f) => f.name)).toEqual([
      "01 first.mp3", "02 second.mp3", "10 tenth.mp3",
    ]);
  });

  it("folder + loose mixed: folder → playlist, loose → library", () => {
    const plan = planIngestion([
      entry("loose.wav"),
      entry("a.mp3", "ep_one"),
      entry("b.mp3", "ep_one"),
    ]);
    expect(plan.libraryAdds.map((f) => f.name)).toEqual(["loose.wav"]);
    expect(plan.playlists).toEqual([
      { name: "Ep One", files: plan.playlists[0].files },
    ]);
    expect(plan.playlists[0].files.map((f) => f.name)).toEqual(["a.mp3", "b.mp3"]);
  });

  it("multiple folders become multiple playlists", () => {
    const plan = planIngestion([
      entry("a.mp3", "one"),
      entry("b.mp3", "two"),
    ]);
    expect(plan.playlists.map((p) => p.name).sort()).toEqual(["One", "Two"]);
  });

  it("empty input produces an empty plan", () => {
    const plan = planIngestion([]);
    expect(plan.libraryAdds).toEqual([]);
    expect(plan.playlists).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// Closing-notice copy
// ---------------------------------------------------------------------------

describe("summarizeBatch", () => {
  it("formats the happy path", () => {
    expect(summarizeBatch({ added: 7, playlists: ["Demos June"], skipped: 0, failed: [] }))
      .toBe("7 SONGS ADDED · PLAYLIST 'DEMOS JUNE' CREATED");
  });

  it("singular forms", () => {
    expect(summarizeBatch({ added: 1, playlists: [], skipped: 1, failed: [] }))
      .toBe("1 SONG ADDED · 1 FILE SKIPPED — NOT AUDIO");
  });

  it("reports skips and failures", () => {
    expect(summarizeBatch({ added: 5, playlists: [], skipped: 2, failed: ["x.wav"] }))
      .toBe("5 SONGS ADDED · 2 FILES SKIPPED — NOT AUDIO · 1 FAILED — RETRY IN LIBRARY");
  });

  it("nothing added at all", () => {
    expect(summarizeBatch({ added: 0, playlists: [], skipped: 0, failed: [] }))
      .toBe("NOTHING ADDED");
  });
});

// ---------------------------------------------------------------------------
// Concurrency runner
// ---------------------------------------------------------------------------

describe("runWithConcurrency", () => {
  it("preserves input order in the results", async () => {
    const out = await runWithConcurrency([3, 1, 2], 2, async (n) => {
      await new Promise((r) => setTimeout(r, n * 5));
      return n * 10;
    });
    expect(out).toEqual([30, 10, 20]);
  });

  it("never exceeds the concurrency limit", async () => {
    let inFlight = 0;
    let peak = 0;
    await runWithConcurrency(Array.from({ length: 8 }, (_, i) => i), 2, async () => {
      inFlight += 1;
      peak = Math.max(peak, inFlight);
      await new Promise((r) => setTimeout(r, 3));
      inFlight -= 1;
    });
    expect(peak).toBe(2);
  });

  it("handles empty input", async () => {
    expect(await runWithConcurrency([], 2, async () => 1)).toEqual([]);
  });
});
