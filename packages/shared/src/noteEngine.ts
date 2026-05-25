import type { FileAsset, Note, Version, VisibleNote } from "./models";

export function formatTimestamp(ms?: number): string {
  if (ms === undefined || ms === null) return "General";
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = String(totalSeconds % 60).padStart(2, "0");
  return `${minutes}:${seconds}`;
}

export function durationDiffExceeds(anchorMs: number, currentMs: number, threshold = 0.05): boolean {
  if (anchorMs <= 0 || currentMs <= 0) return false;
  return Math.abs(currentMs - anchorMs) / anchorMs > threshold;
}

export function getVersionLabel(version: Version): string {
  return version.version_label || `v${version.version_number}`;
}

export function getVisibleNotesForVersion(params: {
  version: Version;
  versions: Version[];
  notes: Note[];
  assets: FileAsset[];
}): VisibleNote[] {
  const { version, versions, notes, assets } = params;
  const versionByID = new Map(versions.map((item) => [item.version_id, item]));
  const assetDurationByVersionID = new Map(
    versions.map((item) => {
      const asset = assets.find((candidate) => candidate.asset_id === item.file_asset_id);
      return [item.version_id, asset?.duration_ms ?? 0] as const;
    })
  );

  return notes
    .filter((note) => note.song_id === version.song_id)
    .filter((note) => {
      const anchor = versionByID.get(note.anchor_version_id);
      if (!anchor) return false;
      if (note.scope === "version") return note.anchor_version_id === version.version_id;
      if (anchor.version_number > version.version_number) return false;
      if (note.status === "open") return true;
      const resolvedVersion = note.resolved_on_version_id
        ? versionByID.get(note.resolved_on_version_id)
        : undefined;
      if (!resolvedVersion) return true;
      return version.version_number <= resolvedVersion.version_number;
    })
    .map((note) => {
      const anchor = versionByID.get(note.anchor_version_id);
      const resolvedVersion = note.resolved_on_version_id
        ? versionByID.get(note.resolved_on_version_id)
        : undefined;
      const isCarried = Boolean(anchor && anchor.version_number < version.version_number && note.scope === "song");
      const anchorDuration = assetDurationByVersionID.get(note.anchor_version_id) ?? 0;
      const currentDuration = assetDurationByVersionID.get(version.version_id) ?? 0;
      const approximateTimestamp =
        isCarried &&
        note.timestamp_start_ms !== undefined &&
        durationDiffExceeds(anchorDuration, currentDuration);

      return {
        ...note,
        anchor_version_label: anchor ? getVersionLabel(anchor) : "Unknown version",
        display_version_label: getVersionLabel(version),
        is_carried: isCarried,
        is_collapsed:
          note.status === "resolved" &&
          Boolean(resolvedVersion && version.version_number <= resolvedVersion.version_number),
        approximate_timestamp: approximateTimestamp || note.timestamp_uncertain,
      };
    })
    .sort((a, b) => {
      const timeA = a.timestamp_start_ms ?? Number.MAX_SAFE_INTEGER;
      const timeB = b.timestamp_start_ms ?? Number.MAX_SAFE_INTEGER;
      return timeA - timeB || a.created_at.localeCompare(b.created_at);
    });
}

