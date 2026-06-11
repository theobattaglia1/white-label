/**
 * THE SHELF — pure slot logic for the record-crate hero on Home.
 *
 * The shelf is Playback's pin + recents surface: up to 15 slots, pins first
 * (in the user's server-side pin order, capped at 10), then recents (newest
 * first) backfilling the rest. Pin refs use the iOS PinRef encoding —
 * "song:<id>" | "playlist:<id>" | "room:<id>" — served by
 * GET /workspaces/:id/pins.
 *
 * No React, no fetch — everything in this module is pure and unit-tested
 * (see __tests__/shelf.test.ts).
 */

export type ShelfItemType = "song" | "playlist" | "room";

export type ShelfItem = {
  /** Stable "type:id" key — doubles as the de-dupe identity on the shelf. */
  key: string;
  type: ShelfItemType;
  id: string;
  title: string;
  /** Mono all-caps meta line, e.g. "PLAYLIST · 12 SONGS". */
  subtitle: string;
  /** Seed for the deterministic cover artwork (matches Library rows). */
  seed: string;
  pinned: boolean;
};

export const SHELF_MAX_SLOTS = 15;
export const SHELF_MAX_PINS = 10;

export function shelfKey(type: ShelfItemType, id: string): string {
  return `${type}:${id}`;
}

/** Parse an iOS-format pin ref ("song:ID" | "playlist:ID" | "room:ID"). */
export function parsePinRef(ref: string): { type: ShelfItemType; id: string } | null {
  const match = /^(song|playlist|room):(.+)$/.exec(ref);
  if (!match) return null;
  return { type: match[1] as ShelfItemType, id: match[2] };
}

/** Mono-caps subtitle: type + meta ("SONG · HUDSON INGRAM", "PLAYLIST · 12 SONGS"). */
export function shelfSubtitle(
  type: ShelfItemType,
  meta: { artist?: string; songCount?: number } = {},
): string {
  if (type === "song") {
    return meta.artist ? `SONG · ${meta.artist.toUpperCase()}` : "SONG";
  }
  const label = type.toUpperCase();
  if (typeof meta.songCount === "number") {
    return `${label} · ${meta.songCount} ${meta.songCount === 1 ? "SONG" : "SONGS"}`;
  }
  return label;
}

/** The already-loaded workspace data the shelf resolves pin refs against. */
export type ShelfSources = {
  songs: Array<{ song_id: string; title: string; artist_display_name?: string; updated_at?: string }>;
  playlists: Array<{ playlist_id: string; title: string; item_count?: number; cover_seed?: string; updated_at?: string }>;
  rooms: Array<{ room_id: string; title: string; song_count?: number }>;
};

/**
 * Resolve raw pin refs to renderable shelf items. Unknown ids and malformed
 * refs are dropped (a stale pin must never render a blank card). Order is
 * preserved — it is the user's pin order.
 */
export function resolvePinRefs(refs: string[], sources: ShelfSources): ShelfItem[] {
  const songByID = new Map(sources.songs.map((s) => [s.song_id, s]));
  const playlistByID = new Map(sources.playlists.map((p) => [p.playlist_id, p]));
  const roomByID = new Map(sources.rooms.map((r) => [r.room_id, r]));
  const items: ShelfItem[] = [];
  for (const ref of refs) {
    const parsed = parsePinRef(ref);
    if (!parsed) continue;
    if (parsed.type === "song") {
      const song = songByID.get(parsed.id);
      if (!song) continue;
      items.push({
        key: shelfKey("song", song.song_id),
        type: "song",
        id: song.song_id,
        title: song.title,
        subtitle: shelfSubtitle("song", { artist: song.artist_display_name }),
        seed: song.song_id,
        pinned: true,
      });
    } else if (parsed.type === "playlist") {
      const playlist = playlistByID.get(parsed.id);
      if (!playlist) continue;
      items.push({
        key: shelfKey("playlist", playlist.playlist_id),
        type: "playlist",
        id: playlist.playlist_id,
        title: playlist.title,
        subtitle: shelfSubtitle("playlist", { songCount: playlist.item_count }),
        seed: playlist.cover_seed ?? playlist.playlist_id,
        pinned: true,
      });
    } else {
      const room = roomByID.get(parsed.id);
      if (!room) continue;
      items.push({
        key: shelfKey("room", room.room_id),
        type: "room",
        id: room.room_id,
        title: room.title,
        subtitle: shelfSubtitle("room", { songCount: room.song_count }),
        seed: room.room_id,
        pinned: true,
      });
    }
  }
  return items;
}

/** The shape of a /workspaces/:id/recent row the shelf cares about. */
export type ShelfRecent = {
  entity_type: string;
  entity_id: string;
  title: string;
  artist_display_name?: string;
};

/**
 * Convert a recent-activity row to a shelf item. Recents only surface songs
 * and playlists today; anything else (e.g. projects) returns null because the
 * shelf has no open handler for it.
 */
export function recentToShelfItem(recent: ShelfRecent, sources: ShelfSources): ShelfItem | null {
  if (recent.entity_type === "song") {
    const song = sources.songs.find((s) => s.song_id === recent.entity_id);
    return {
      key: shelfKey("song", recent.entity_id),
      type: "song",
      id: recent.entity_id,
      title: recent.title,
      subtitle: shelfSubtitle("song", { artist: recent.artist_display_name ?? song?.artist_display_name }),
      seed: recent.entity_id,
      pinned: false,
    };
  }
  if (recent.entity_type === "playlist") {
    const playlist = sources.playlists.find((p) => p.playlist_id === recent.entity_id);
    return {
      key: shelfKey("playlist", recent.entity_id),
      type: "playlist",
      id: recent.entity_id,
      title: recent.title,
      subtitle: shelfSubtitle("playlist", { songCount: playlist?.item_count }),
      seed: playlist?.cover_seed ?? recent.entity_id,
      pinned: false,
    };
  }
  return null;
}

/**
 * Fallback recents when the recent-activity feed is empty or unavailable
 * (e.g. a workspace with no activity rows yet): derive "recents" from the
 * already-loaded workspace data — songs and playlists interleaved newest-first
 * by updated_at. Pure, so the shelf never shows a dead band on a workspace
 * that plainly has content.
 */
export function fallbackRecents(sources: ShelfSources): ShelfItem[] {
  const dated: Array<{ at: string; item: ShelfItem }> = [];
  for (const song of sources.songs) {
    dated.push({
      at: song.updated_at ?? "",
      item: {
        key: shelfKey("song", song.song_id),
        type: "song",
        id: song.song_id,
        title: song.title,
        subtitle: shelfSubtitle("song", { artist: song.artist_display_name }),
        seed: song.song_id,
        pinned: false,
      },
    });
  }
  for (const playlist of sources.playlists) {
    dated.push({
      at: playlist.updated_at ?? "",
      item: {
        key: shelfKey("playlist", playlist.playlist_id),
        type: "playlist",
        id: playlist.playlist_id,
        title: playlist.title,
        subtitle: shelfSubtitle("playlist", { songCount: playlist.item_count }),
        seed: playlist.cover_seed ?? playlist.playlist_id,
        pinned: false,
      },
    });
  }
  dated.sort((a, b) => b.at.localeCompare(a.at));
  return dated.map((d) => d.item);
}

/**
 * Build the shelf's slot list:
 *  - 15 slots max
 *  - up to 10 pins first, in pin order (extra pins are truncated)
 *  - then recents, newest first, backfilling the remaining slots — which
 *    guarantees the 5 most-recent (non-pinned) items are always present
 *    even at the 10-pin cap
 *  - de-duped by key: a pinned item never appears twice, recents skip
 *    anything already pinned
 *  - fewer than 15 available → return what exists
 */
export function buildShelfSlots(pins: ShelfItem[], recents: ShelfItem[]): ShelfItem[] {
  const slots: ShelfItem[] = [];
  const seen = new Set<string>();
  for (const pin of pins) {
    if (slots.length >= SHELF_MAX_PINS) break;
    if (seen.has(pin.key)) continue;
    seen.add(pin.key);
    slots.push(pin.pinned ? pin : { ...pin, pinned: true });
  }
  for (const recent of recents) {
    if (slots.length >= SHELF_MAX_SLOTS) break;
    if (seen.has(recent.key)) continue;
    seen.add(recent.key);
    slots.push(recent.pinned ? { ...recent, pinned: false } : recent);
  }
  return slots;
}
