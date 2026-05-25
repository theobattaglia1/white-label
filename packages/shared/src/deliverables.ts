import type { DeliverableStatus, FileAsset, Song, Version } from "./models";

export function computeDeliverables(song: Song, versions: Version[], assets: FileAsset[]): DeliverableStatus {
  const songVersions = versions.filter((version) => version.song_id === song.song_id);
  const versionTypes = new Set(songVersions.map((version) => version.type));
  const assetByID = new Map(assets.map((asset) => [asset.asset_id, asset]));
  const hasStems = songVersions.some((version) => Boolean(assetByID.get(version.file_asset_id)?.key_stems_zip));
  const required = [
    ["clean", versionTypes.has("clean")],
    ["explicit", versionTypes.has("explicit") || song.explicit_flag === false],
    ["instrumental", versionTypes.has("instrumental")],
    ["acapella", versionTypes.has("acapella")],
    ["stems", hasStems],
    ["BPM", Boolean(song.bpm)],
    ["key", Boolean(song.song_key)],
  ] as const;
  const present = required.filter(([, ok]) => ok).map(([label]) => label);
  const missing = required.filter(([, ok]) => !ok).map(([label]) => label);
  return { ready: missing.length === 0, present, missing };
}

