import Foundation

/// THE SHELF — pure slot logic for the record-crate band on Home.
///
/// Port of the web reference (apps/web/src/shelf.ts): up to 15 slots, pins
/// first (in the user's server-side pin order, capped at 10), then recents
/// (newest first) backfilling the rest. Pin refs use the PinRef encoding —
/// "song:<id>" | "playlist:<id>" | "room:<id>".
///
/// Everything in this file is pure: no store observation, no views, no I/O.

/// One sleeve on the shelf.
struct ShelfItem: Identifiable, Hashable {
    let ref: PinRef
    let title: String
    /// Mono all-caps meta line, e.g. "PLAYLIST · 12 SONGS".
    let subtitle: String
    let pinned: Bool
    /// Stable "type:id" key — doubles as the de-dupe identity on the shelf.
    var id: String { ref.id }
}

enum ShelfSlots {
    static let maxSlots = 15
    static let maxPins = 10

    /// Mono-caps subtitle: type + meta ("SONG · HUDSON INGRAM",
    /// "PLAYLIST · 12 SONGS"). Rooms read as projects in this universe.
    static func subtitle(for kind: PinKind, artist: String? = nil, songCount: Int? = nil) -> String {
        switch kind {
        case .song:
            guard let artist, !artist.isEmpty else { return "SONG" }
            return "SONG · \(artist.uppercased())"
        case .playlist, .room:
            let label = kind == .playlist ? "PLAYLIST" : "PROJECT"
            guard let songCount else { return label }
            return "\(label) · \(songCount) \(songCount == 1 ? "SONG" : "SONGS")"
        }
    }

    /// Resolve raw pin refs ("song:ID" | "playlist:ID" | "room:ID") to shelf
    /// items. Unknown ids and malformed refs are dropped silently (a stale pin
    /// must never render a blank card). Order is preserved — it is the user's
    /// pin order.
    static func resolvePins(
        refs: [String],
        tracks: [Track],
        playlists: [Playlist],
        rooms: [Room],
        titleOverrides: [String: String]
    ) -> [ShelfItem] {
        refs.compactMap { raw in
            guard let ref = PinRef(raw) else { return nil }
            switch ref.kind {
            case .song:
                guard let track = tracks.first(where: { $0.id == ref.targetID }) else { return nil }
                return ShelfItem(
                    ref: ref,
                    title: titleOverrides[track.id] ?? track.title,
                    subtitle: subtitle(for: .song, artist: track.artist),
                    pinned: true
                )
            case .playlist:
                guard let playlist = playlists.first(where: { $0.id == ref.targetID }) else { return nil }
                return ShelfItem(
                    ref: ref,
                    title: playlist.title,
                    subtitle: subtitle(for: .playlist, songCount: playlist.trackIDs.count),
                    pinned: true
                )
            case .room:
                guard let room = rooms.first(where: { $0.id == ref.targetID }) else { return nil }
                return ShelfItem(
                    ref: ref,
                    title: room.title,
                    subtitle: subtitle(for: .room, songCount: room.trackIDs.count),
                    pinned: true
                )
            }
        }
    }

    /// Recents, newest first: songs and playlists ordered by last-touch
    /// activity (rooms reach the shelf only by being pinned, matching the web
    /// shelf, which has no recents-open handler for them). Untouched items
    /// fall to a stable default order — playlists ahead of songs, original
    /// catalog order within each — so the shelf is never a dead band on a
    /// workspace that plainly has content.
    static func recents(
        tracks: [Track],
        playlists: [Playlist],
        activity: [String: Date],
        titleOverrides: [String: String]
    ) -> [ShelfItem] {
        var dated: [(at: Date, item: ShelfItem)] = []
        for (i, track) in tracks.enumerated() {
            let ref = PinRef(kind: .song, targetID: track.id)
            dated.append((
                at: activity[ref.id] ?? Date(timeIntervalSince1970: TimeInterval(800 - i)),
                item: ShelfItem(
                    ref: ref,
                    title: titleOverrides[track.id] ?? track.title,
                    subtitle: subtitle(for: .song, artist: track.artist),
                    pinned: false
                )
            ))
        }
        for (i, playlist) in playlists.enumerated() {
            let ref = PinRef(kind: .playlist, targetID: playlist.id)
            dated.append((
                at: activity[ref.id] ?? Date(timeIntervalSince1970: TimeInterval(1000 - i)),
                item: ShelfItem(
                    ref: ref,
                    title: playlist.title,
                    subtitle: subtitle(for: .playlist, songCount: playlist.trackIDs.count),
                    pinned: false
                )
            ))
        }
        return dated.sorted { $0.at > $1.at }.map(\.item)
    }

    /// Normalized "what the listener sees" identity for recents de-duping.
    /// The library can hold several rows that render identically — e.g.
    /// song+version entries with distinct ids but the same title and artist —
    /// and adjacent twins on the shelf read as a bug. Songs normalize on
    /// title + subtitle (the subtitle carries the artist); playlists and
    /// rooms normalize on type + title.
    static func recentIdentity(_ item: ShelfItem) -> String {
        func norm(_ s: String) -> String {
            s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return item.ref.kind == .song
            ? "song|\(norm(item.title))|\(norm(item.subtitle))"
            : "\(item.ref.kind.rawValue)|\(norm(item.title))"
    }

    /// Build the shelf's slot list:
    ///  - 15 slots max
    ///  - up to 10 pins first, in pin order (extra pins are truncated)
    ///  - then recents, newest first, backfilling the remaining slots — which
    ///    guarantees the 5 most-recent (non-pinned) items are always present
    ///    even at the 10-pin cap
    ///  - de-duped by "type:id" key: a pinned item never appears twice,
    ///    recents skip anything already pinned
    ///  - recents are additionally de-duped by normalized title + artist
    ///    (recentIdentity) so duplicate library rows with distinct ids don't
    ///    render twin sleeves; newest-first input means the newest twin wins.
    ///    Pins are exempt — the user chose them — but recents do skip anything
    ///    that *reads* identical to a pin.
    ///  - fewer than 15 available → return what exists
    static func build(pins: [ShelfItem], recents: [ShelfItem]) -> [ShelfItem] {
        var slots: [ShelfItem] = []
        var seen = Set<String>()
        var seenIdentity = Set<String>()
        for pin in pins {
            if slots.count >= maxPins { break }
            guard seen.insert(pin.id).inserted else { continue }
            seenIdentity.insert(recentIdentity(pin))
            slots.append(pin.pinned ? pin : ShelfItem(ref: pin.ref, title: pin.title, subtitle: pin.subtitle, pinned: true))
        }
        for recent in recents {
            if slots.count >= maxSlots { break }
            guard !seen.contains(recent.id) else { continue }
            let identity = recentIdentity(recent)
            guard seenIdentity.insert(identity).inserted else { continue }
            seen.insert(recent.id)
            slots.append(recent.pinned ? ShelfItem(ref: recent.ref, title: recent.title, subtitle: recent.subtitle, pinned: false) : recent)
        }
        return slots
    }
}
