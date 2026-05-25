import type { FileAsset, Song, Version, VersionType } from "./models";

export function makeVersionLabel(type: VersionType, versionNumber: number): string {
  const prefix = type === "master" ? "Master" : type === "rough" ? "Rough" : "Mix";
  return `${prefix} v${versionNumber}`;
}

export function promoteVersion(params: {
  song: Song;
  versions: Version[];
  versionID: string;
}): { song: Song; versions: Version[] } {
  const selected = params.versions.find((version) => version.version_id === params.versionID);
  if (!selected) throw new Error("Version not found");
  return {
    song: {
      ...params.song,
      current_version_id: selected.version_id,
      updated_at: new Date().toISOString(),
    },
    versions: params.versions.map((version) => ({
      ...version,
      is_current: version.version_id === selected.version_id,
    })),
  };
}

export function appendVersion(params: {
  song: Song;
  versions: Version[];
  asset: FileAsset;
  uploadedBy: string;
  type?: VersionType;
  label?: string;
  idFactory: () => string;
  now?: string;
}): { song: Song; versions: Version[]; version: Version } {
  const existing = params.versions
    .filter((version) => version.song_id === params.song.song_id)
    .sort((a, b) => a.version_number - b.version_number);
  const priorCurrent = existing.find((version) => version.is_current);
  const versionNumber = existing.length + 1;
  const type = params.type ?? "mix";
  const now = params.now ?? new Date().toISOString();
  const version: Version = {
    version_id: params.idFactory(),
    song_id: params.song.song_id,
    version_number: versionNumber,
    version_label: params.label ?? makeVersionLabel(type, versionNumber),
    type,
    parent_version_id: priorCurrent?.version_id,
    is_current: true,
    is_approved: false,
    uploaded_by: params.uploadedBy,
    file_asset_id: params.asset.asset_id,
    created_at: now,
  };
  const versions = params.versions.map((item) =>
    item.song_id === params.song.song_id ? { ...item, is_current: false } : item
  );

  return {
    song: {
      ...params.song,
      current_version_id: version.version_id,
      updated_at: now,
    },
    versions: [...versions, version],
    version,
  };
}

export function getCurrentVersion(song: Song, versions: Version[]): Version | undefined {
  return versions.find((version) => version.version_id === song.current_version_id);
}

