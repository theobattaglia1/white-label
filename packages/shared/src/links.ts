import type { PlaylistItem, ShareLink, Song, Version } from "./models";
import { getCurrentVersion } from "./versioning";

export function resolveShareLink(params: {
  tokenHash: string;
  links: ShareLink[];
  songs: Song[];
  versions: Version[];
  /** Required only when resolving a playlist-targeted link. */
  playlistItems?: PlaylistItem[];
}): { link: ShareLink; songs: Song[]; versions: Version[] } {
  const link = params.links.find((candidate) => candidate.token_hash === params.tokenHash);
  if (!link || link.revoked_at) throw new Error("Share link is unavailable");
  if (link.expires_at && new Date(link.expires_at).getTime() < Date.now()) throw new Error("Share link has expired");

  let songs: Song[];
  switch (link.target_type) {
    case "song":
      songs = params.songs.filter((song) => song.song_id === link.target_id);
      break;
    case "project":
      songs = params.songs.filter((song) => song.primary_project_id === link.target_id);
      break;
    case "playlist": {
      const items = (params.playlistItems ?? [])
        .filter((it) => it.playlist_id === link.target_id)
        .sort((a, b) => a.position - b.position);
      const songByID = new Map(params.songs.map((s) => [s.song_id, s]));
      songs = items
        .map((it) => songByID.get(it.song_id))
        .filter((s): s is Song => Boolean(s));
      break;
    }
  }

  const songIDs = new Set(songs.map((song) => song.song_id));
  const allVersions = params.versions.filter((version) => songIDs.has(version.song_id));
  const versions =
    link.version_policy === "latest_only"
      ? songs
          .map((song) => getCurrentVersion(song, allVersions))
          .filter((version): version is Version => Boolean(version))
      : allVersions;

  return { link, songs, versions };
}
