/**
 * Drop-anywhere upload — pure ingestion logic.
 *
 * Everything here is framework-free and unit-tested: file filtering, title
 * cleaning, folder traversal (against structural FileSystemEntry-like fakes),
 * ingestion planning, and the closing-notice copy. The React shell
 * (DropZone.tsx) stays thin so the whole pipeline can be exercised from tests
 * and from the `window.__pbSimulateDrop` dev hook.
 */

// ---------------------------------------------------------------------------
// Audio filter
// ---------------------------------------------------------------------------

export const AUDIO_EXTENSIONS = new Set([
  "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg",
]);

/** Lower-cased extension without the dot, or "" when there is none. */
export function fileExtension(name: string): string {
  const idx = name.lastIndexOf(".");
  if (idx <= 0 || idx === name.length - 1) return "";
  return name.slice(idx + 1).toLowerCase();
}

export function isAudioFile(name: string): boolean {
  return AUDIO_EXTENSIONS.has(fileExtension(name));
}

// ---------------------------------------------------------------------------
// Title cleaning
// ---------------------------------------------------------------------------

/**
 * Filename → song title: drop the extension, underscores/dashes → spaces,
 * collapse whitespace. Version-ish suffixes are trimmed ONLY when trivially
 * safe — a single trailing `v<digits>` token (e.g. "duel-v5.m4a" → "duel").
 * Anything more ambiguous is kept as-is.
 */
export function cleanSongTitle(filename: string): string {
  const ext = fileExtension(filename);
  let base = ext ? filename.slice(0, filename.length - ext.length - 1) : filename;
  base = base.replace(/[_-]+/g, " ").replace(/\s+/g, " ").trim();
  const stripped = base.replace(/\s+v\d{1,3}$/i, "").trim();
  return (stripped.length > 0 ? stripped : base) || filename;
}

/** Folder name → playlist title: separators → spaces, Title Case each word. */
export function titleCaseFolderName(name: string): string {
  const words = name.replace(/[_-]+/g, " ").replace(/\s+/g, " ").trim().split(" ");
  return words
    .filter((w) => w.length > 0)
    .map((w) => w[0].toUpperCase() + w.slice(1).toLowerCase())
    .join(" ") || name;
}

// ---------------------------------------------------------------------------
// Drag heuristics (dragenter/dragover — before any file is readable)
// ---------------------------------------------------------------------------

/** True only when actual OS files are being dragged (never text/images from another tab). */
export function shouldReactToDrag(types: readonly string[] | DOMStringList | null | undefined): boolean {
  if (!types) return false;
  const list = Array.from(types as Iterable<string>);
  return list.includes("Files");
}

/**
 * Second line under "DROP TO ADD TO YOUR LIBRARY" while hovering. Browsers
 * reveal item *count* during drag but not names or file-vs-folder, so we only
 * promise what we know — never a wrong count, never a wrong noun.
 */
export function describeDragItems(itemKinds: readonly string[] | null | undefined): string | null {
  if (!itemKinds || itemKinds.length === 0) return null;
  const n = itemKinds.filter((k) => k === "file").length;
  if (n === 0) return null;
  return `${n} ${n === 1 ? "ITEM" : "ITEMS"}`;
}

// ---------------------------------------------------------------------------
// Folder traversal (webkitGetAsEntry / FileSystemEntry)
// ---------------------------------------------------------------------------

/** Structural subset of FileSystemEntry so tests can use plain fakes. */
export type EntryLike = {
  isFile: boolean;
  isDirectory: boolean;
  name: string;
  file?: (resolve: (f: File) => void, reject?: (err: unknown) => void) => void;
  createReader?: () => {
    readEntries: (resolve: (entries: EntryLike[]) => void, reject?: (err: unknown) => void) => void;
  };
};

export type DroppedEntry = {
  file: File;
  /** Top-level folder the file arrived in, or null for loose files. */
  folderName: string | null;
};

export type CollectResult = {
  entries: DroppedEntry[];
  /** Files that were present but not audio. */
  skipped: number;
};

function entryFile(entry: EntryLike): Promise<File> {
  return new Promise((resolve, reject) => {
    if (!entry.file) { reject(new Error(`entry ${entry.name} has no file()`)); return; }
    entry.file(resolve, reject);
  });
}

/** Drain a directory reader — readEntries returns results in chunks until []. */
async function readAllEntries(dir: EntryLike): Promise<EntryLike[]> {
  if (!dir.createReader) return [];
  const reader = dir.createReader();
  const all: EntryLike[] = [];
  for (;;) {
    const chunk = await new Promise<EntryLike[]>((resolve, reject) => reader.readEntries(resolve, reject));
    if (chunk.length === 0) break;
    all.push(...chunk);
  }
  return all;
}

/**
 * Recursively walk FileSystemEntry-like roots. Files inside a folder are
 * tagged with the TOP-LEVEL folder's name (nested subfolders inherit it),
 * because one dropped folder becomes one playlist.
 */
export async function collectFromEntries(roots: EntryLike[]): Promise<CollectResult> {
  const entries: DroppedEntry[] = [];
  let skipped = 0;

  async function walk(entry: EntryLike, topFolder: string | null): Promise<void> {
    if (entry.isFile) {
      let file: File;
      try {
        file = await entryFile(entry);
      } catch {
        skipped += 1;
        return;
      }
      if (isAudioFile(file.name)) entries.push({ file, folderName: topFolder });
      else skipped += 1;
      return;
    }
    if (entry.isDirectory) {
      const children = await readAllEntries(entry);
      const folder = topFolder ?? entry.name;
      for (const child of children) await walk(child, folder);
    }
  }

  for (const root of roots) await walk(root, null);
  return { entries, skipped };
}

/**
 * Pull everything out of a real drop's DataTransfer. The webkitGetAsEntry /
 * getAsFile calls happen synchronously before any await — the item list is
 * dead once the drop handler yields.
 */
export function collectAudioEntries(dt: DataTransfer): Promise<CollectResult> {
  const roots: EntryLike[] = [];
  const looseFiles: File[] = [];

  const items = dt.items ? Array.from(dt.items) : [];
  if (items.length > 0) {
    for (const item of items) {
      if (item.kind !== "file") continue;
      const entry = typeof item.webkitGetAsEntry === "function"
        ? (item.webkitGetAsEntry() as EntryLike | null)
        : null;
      if (entry) roots.push(entry);
      else {
        const f = item.getAsFile();
        if (f) looseFiles.push(f);
      }
    }
  } else if (dt.files) {
    // Older engines: flat file list only, no folder structure.
    looseFiles.push(...Array.from(dt.files));
  }

  return collectFromEntries(roots).then((fromEntries) => {
    const entries = [...fromEntries.entries];
    let skipped = fromEntries.skipped;
    for (const f of looseFiles) {
      if (isAudioFile(f.name)) entries.push({ file: f, folderName: null });
      else skipped += 1;
    }
    return { entries, skipped };
  });
}

// ---------------------------------------------------------------------------
// Ingestion planning
// ---------------------------------------------------------------------------

export type IngestionPlan = {
  /** Loose audio files → plain library adds. */
  libraryAdds: File[];
  /** One dropped folder → one playlist (title-cased), files in filename order. */
  playlists: Array<{ name: string; files: File[] }>;
};

const byFilename = (a: File, b: File) =>
  a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });

export function planIngestion(entries: DroppedEntry[]): IngestionPlan {
  const libraryAdds: File[] = [];
  const folders = new Map<string, File[]>();

  for (const { file, folderName } of entries) {
    if (folderName === null) libraryAdds.push(file);
    else {
      const bucket = folders.get(folderName) ?? [];
      bucket.push(file);
      folders.set(folderName, bucket);
    }
  }

  libraryAdds.sort(byFilename);
  const playlists = Array.from(folders.entries()).map(([folder, files]) => ({
    name: titleCaseFolderName(folder),
    files: [...files].sort(byFilename),
  }));

  return { libraryAdds, playlists };
}

// ---------------------------------------------------------------------------
// Closing notice copy
// ---------------------------------------------------------------------------

export type BatchOutcome = {
  added: number;
  /** Names of playlists actually created. */
  playlists: string[];
  skipped: number;
  /** Filenames whose upload failed. */
  failed: string[];
};

export function summarizeBatch(outcome: BatchOutcome): string {
  const parts: string[] = [];
  if (outcome.added > 0) {
    parts.push(`${outcome.added} ${outcome.added === 1 ? "SONG" : "SONGS"} ADDED`);
  }
  for (const name of outcome.playlists) {
    parts.push(`PLAYLIST '${name.toUpperCase()}' CREATED`);
  }
  if (outcome.skipped > 0) {
    parts.push(`${outcome.skipped} ${outcome.skipped === 1 ? "FILE" : "FILES"} SKIPPED — NOT AUDIO`);
  }
  if (outcome.failed.length > 0) {
    parts.push(`${outcome.failed.length} FAILED — RETRY IN LIBRARY`);
  }
  if (parts.length === 0) return "NOTHING ADDED";
  return parts.join(" · ");
}

// ---------------------------------------------------------------------------
// Bounded-concurrency runner (upload limit = 2)
// ---------------------------------------------------------------------------

/** Map `items` through `worker` with at most `limit` in flight; result order matches input. */
export async function runWithConcurrency<T, R>(
  items: T[],
  limit: number,
  worker: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  async function lane(): Promise<void> {
    for (;;) {
      const idx = next++;
      if (idx >= items.length) return;
      results[idx] = await worker(items[idx], idx);
    }
  }
  const lanes = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, lane);
  await Promise.all(lanes);
  return results;
}
