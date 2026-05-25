import type { ShareLink, Song, Version } from "./models";
import { getCurrentVersion } from "./versioning";

export function resolveShareLink(params: {
  tokenHash: string;
  links: ShareLink[];
  songs: Song[];
  versions: Version[];
}): { link: ShareLink; songs: Song[]; versions: Version[] } {
  const link = params.links.find((candidate) => candidate.token_hash === params.tokenHash);
  if (!link || link.revoked_at) throw new Error("Share link is unavailable");
  if (link.expires_at && new Date(link.expires_at).getTime() < Date.now()) throw new Error("Share link has expired");

  const songs =
    link.target_type === "song"
      ? params.songs.filter((song) => song.song_id === link.target_id)
      : params.songs.filter((song) => song.primary_room_id === link.target_id);

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
