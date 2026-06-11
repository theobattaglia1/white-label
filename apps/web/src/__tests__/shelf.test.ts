import { describe, expect, it } from "vitest";
import {
  SHELF_MAX_PINS,
  SHELF_MAX_SLOTS,
  buildShelfSlots,
  parsePinRef,
  recentIdentity,
  recentToShelfItem,
  resolvePinRefs,
  shelfKey,
  shelfSubtitle,
  type ShelfItem,
  type ShelfSources,
} from "../shelf";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

function makeItem(type: "song" | "playlist" | "room", id: string, pinned = false): ShelfItem {
  return {
    key: shelfKey(type, id),
    type,
    id,
    title: `Title ${id}`,
    subtitle: type.toUpperCase(),
    seed: id,
    pinned,
  };
}

/** n pinned songs: pin-0 … pin-(n-1), in pin order. */
function pins(n: number): ShelfItem[] {
  return Array.from({ length: n }, (_, i) => makeItem("song", `pin-${i}`, true));
}

/** n recent songs: rec-0 (newest) … rec-(n-1) (oldest). */
function recents(n: number): ShelfItem[] {
  return Array.from({ length: n }, (_, i) => makeItem("song", `rec-${i}`));
}

const sources: ShelfSources = {
  songs: [
    { song_id: "song-1", title: "Midnight", artist_display_name: "Hudson Ingram" },
    { song_id: "song-2", title: "Daylight" },
  ],
  playlists: [
    { playlist_id: "pl-1", title: "Rough Cuts", item_count: 12, cover_seed: "seed-pl-1" },
    { playlist_id: "pl-2", title: "One Track", item_count: 1 },
  ],
  rooms: [{ room_id: "room-1", title: "Hudson Ingram LP", song_count: 8 }],
};

// ---------------------------------------------------------------------------
// buildShelfSlots — slot counts, ordering, de-dupe, backfill, truncation
// ---------------------------------------------------------------------------

describe("buildShelfSlots", () => {
  it("caps the shelf at 15 slots", () => {
    const slots = buildShelfSlots(pins(10), recents(30));
    expect(slots).toHaveLength(SHELF_MAX_SLOTS);
  });

  it("puts pins first (in pin order), then recents newest-first", () => {
    const slots = buildShelfSlots(pins(3), recents(4));
    expect(slots.map((s) => s.id)).toEqual([
      "pin-0", "pin-1", "pin-2",
      "rec-0", "rec-1", "rec-2", "rec-3",
    ]);
  });

  it("keeps the 5 most-recent items present even at the 10-pin cap", () => {
    const slots = buildShelfSlots(pins(10), recents(20));
    const recentIDs = slots.slice(SHELF_MAX_PINS).map((s) => s.id);
    expect(recentIDs).toEqual(["rec-0", "rec-1", "rec-2", "rec-3", "rec-4"]);
  });

  it("truncates more than 10 pins down to 10", () => {
    const slots = buildShelfSlots(pins(14), recents(20));
    expect(slots.filter((s) => s.pinned)).toHaveLength(SHELF_MAX_PINS);
    expect(slots.map((s) => s.id).slice(0, 10)).toEqual(
      Array.from({ length: 10 }, (_, i) => `pin-${i}`),
    );
    expect(slots).toHaveLength(SHELF_MAX_SLOTS);
  });

  it("backfills remaining slots with further recents when there are few pins", () => {
    const slots = buildShelfSlots(pins(2), recents(30));
    expect(slots).toHaveLength(SHELF_MAX_SLOTS);
    // 2 pins + 13 recents (rec-0 … rec-12)
    expect(slots.slice(2).map((s) => s.id)).toEqual(
      Array.from({ length: 13 }, (_, i) => `rec-${i}`),
    );
  });

  it("recents skip anything already pinned (a pinned item never appears twice)", () => {
    const pinned = [makeItem("song", "shared", true), makeItem("playlist", "pl-x", true)];
    const recent = [makeItem("song", "shared"), makeItem("song", "fresh"), makeItem("playlist", "pl-x")];
    const slots = buildShelfSlots(pinned, recent);
    expect(slots.map((s) => s.key)).toEqual(["song:shared", "playlist:pl-x", "song:fresh"]);
    expect(new Set(slots.map((s) => s.key)).size).toBe(slots.length);
  });

  it("de-dupes repeated pins, preserving first position", () => {
    const pinned = [makeItem("song", "a", true), makeItem("song", "a", true), makeItem("song", "b", true)];
    expect(buildShelfSlots(pinned, []).map((s) => s.id)).toEqual(["a", "b"]);
  });

  it("renders only what exists when fewer than 15 items are available", () => {
    expect(buildShelfSlots(pins(1), recents(2))).toHaveLength(3);
    expect(buildShelfSlots([], recents(4))).toHaveLength(4);
    expect(buildShelfSlots([], [])).toHaveLength(0);
  });

  it("works with 0 pins — recents fill the shelf newest-first", () => {
    const slots = buildShelfSlots([], recents(20));
    expect(slots).toHaveLength(SHELF_MAX_SLOTS);
    expect(slots[0].id).toBe("rec-0");
    expect(slots.every((s) => !s.pinned)).toBe(true);
  });

  it("normalizes the pinned flag: pins true, recents false", () => {
    const slots = buildShelfSlots(
      [makeItem("song", "p", false)], // mis-flagged pin
      [makeItem("song", "r", true)], // mis-flagged recent
    );
    expect(slots.find((s) => s.id === "p")?.pinned).toBe(true);
    expect(slots.find((s) => s.id === "r")?.pinned).toBe(false);
  });

  it("a song and a playlist with the same raw id do not collide (key is type-scoped)", () => {
    const slots = buildShelfSlots([makeItem("song", "x", true)], [makeItem("playlist", "x")]);
    expect(slots).toHaveLength(2);
  });
});

// ---------------------------------------------------------------------------
// recents de-dupe by normalized title + artist — duplicate library rows
// (e.g. song + version entries with distinct ids) must not render twins
// ---------------------------------------------------------------------------

describe("recents de-dupe by normalized identity", () => {
  const song = (id: string, title: string, artist?: string, pinned = false): ShelfItem => ({
    key: shelfKey("song", id),
    type: "song",
    id,
    title,
    subtitle: shelfSubtitle("song", { artist }),
    seed: id,
    pinned,
  });

  it("recentIdentity normalizes case and whitespace, scoped by type", () => {
    expect(recentIdentity(song("a", "Seeing You  In Everything Final", "Adam Melchor"))).toBe(
      recentIdentity(song("b", "  seeing you in everything final ", "ADAM MELCHOR")),
    );
    const asPlaylist: ShelfItem = { ...makeItem("playlist", "p"), title: "Midnight" };
    const asSong = song("s", "Midnight", "Hudson Ingram");
    expect(recentIdentity(asPlaylist)).not.toBe(recentIdentity(asSong));
  });

  it("collapses recents twins with distinct ids — newest (first) wins", () => {
    const slots = buildShelfSlots([], [
      song("v2", "seeing you in everything final", "Adam Melchor"),
      song("v1", "Seeing You In Everything Final", "Adam Melchor"),
      song("other", "Daylight", "Adam Melchor"),
    ]);
    expect(slots.map((s) => s.id)).toEqual(["v2", "other"]);
  });

  it("keeps same-title songs by DIFFERENT artists apart", () => {
    const slots = buildShelfSlots([], [
      song("a", "Midnight", "Hudson Ingram"),
      song("b", "Midnight", "Adam Melchor"),
    ]);
    expect(slots).toHaveLength(2);
  });

  it("pinned twins are exempt (the user chose them)", () => {
    const slots = buildShelfSlots(
      [song("v1", "Seeing You In Everything Final", "Adam Melchor", true),
       song("v2", "seeing you in everything final", "Adam Melchor", true)],
      [],
    );
    expect(slots.map((s) => s.id)).toEqual(["v1", "v2"]);
  });

  it("recents skip items that read identical to a pin", () => {
    const slots = buildShelfSlots(
      [song("pinned-v", "Seeing You In Everything Final", "Adam Melchor", true)],
      [song("recent-v", "seeing you in everything final", "Adam Melchor"), song("ok", "Daylight")],
    );
    expect(slots.map((s) => s.id)).toEqual(["pinned-v", "ok"]);
  });

  it("playlists de-dupe on type + title", () => {
    const pl = (id: string, title: string): ShelfItem => ({
      ...makeItem("playlist", id),
      title,
      subtitle: shelfSubtitle("playlist", { songCount: 3 }),
    });
    const slots = buildShelfSlots([], [pl("p1", "Rough Cuts"), pl("p2", "rough cuts")]);
    expect(slots.map((s) => s.id)).toEqual(["p1"]);
  });
});

// ---------------------------------------------------------------------------
// parsePinRef — iOS "type:id" encoding
// ---------------------------------------------------------------------------

describe("parsePinRef", () => {
  it("parses song / playlist / room refs", () => {
    expect(parsePinRef("song:song-1")).toEqual({ type: "song", id: "song-1" });
    expect(parsePinRef("playlist:pl-1")).toEqual({ type: "playlist", id: "pl-1" });
    expect(parsePinRef("room:room-1")).toEqual({ type: "room", id: "room-1" });
  });

  it("keeps colons inside the id intact", () => {
    expect(parsePinRef("song:weird:id")).toEqual({ type: "song", id: "weird:id" });
  });

  it("rejects malformed refs", () => {
    expect(parsePinRef("album:x")).toBeNull();
    expect(parsePinRef("song:")).toBeNull();
    expect(parsePinRef("song-1")).toBeNull();
    expect(parsePinRef("")).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// resolvePinRefs — refs → renderable items against loaded workspace data
// ---------------------------------------------------------------------------

describe("resolvePinRefs", () => {
  it("resolves each ref type with title, subtitle, and seed", () => {
    const items = resolvePinRefs(["song:song-1", "playlist:pl-1", "room:room-1"], sources);
    expect(items.map((i) => [i.type, i.title, i.subtitle, i.seed, i.pinned])).toEqual([
      ["song", "Midnight", "SONG · HUDSON INGRAM", "song-1", true],
      ["playlist", "Rough Cuts", "PLAYLIST · 12 SONGS", "seed-pl-1", true],
      ["room", "Hudson Ingram LP", "ROOM · 8 SONGS", "room-1", true],
    ]);
  });

  it("drops unknown ids and malformed refs, preserving pin order", () => {
    const items = resolvePinRefs(
      ["song:nope", "garbage", "room:room-1", "song:song-2"],
      sources,
    );
    expect(items.map((i) => i.key)).toEqual(["room:room-1", "song:song-2"]);
  });

  it("falls back to bare type subtitles when meta is missing", () => {
    const items = resolvePinRefs(["song:song-2"], sources);
    expect(items[0].subtitle).toBe("SONG");
  });
});

// ---------------------------------------------------------------------------
// recentToShelfItem + shelfSubtitle
// ---------------------------------------------------------------------------

describe("recentToShelfItem", () => {
  it("maps song recents, enriching artist from sources when absent", () => {
    const item = recentToShelfItem(
      { entity_type: "song", entity_id: "song-1", title: "Midnight" },
      sources,
    );
    expect(item).toMatchObject({ type: "song", subtitle: "SONG · HUDSON INGRAM", pinned: false });
  });

  it("maps playlist recents, enriching count and cover seed from sources", () => {
    const item = recentToShelfItem(
      { entity_type: "playlist", entity_id: "pl-1", title: "Rough Cuts" },
      sources,
    );
    expect(item).toMatchObject({ subtitle: "PLAYLIST · 12 SONGS", seed: "seed-pl-1" });
  });

  it("returns null for entity types the shelf cannot open", () => {
    expect(
      recentToShelfItem({ entity_type: "project", entity_id: "pr-1", title: "LP" }, sources),
    ).toBeNull();
  });
});

describe("shelfSubtitle", () => {
  it("formats mono-caps type + meta", () => {
    expect(shelfSubtitle("song", { artist: "Hudson Ingram" })).toBe("SONG · HUDSON INGRAM");
    expect(shelfSubtitle("playlist", { songCount: 12 })).toBe("PLAYLIST · 12 SONGS");
    expect(shelfSubtitle("playlist", { songCount: 1 })).toBe("PLAYLIST · 1 SONG");
    expect(shelfSubtitle("room", { songCount: 0 })).toBe("ROOM · 0 SONGS");
    expect(shelfSubtitle("room")).toBe("ROOM");
  });
});
