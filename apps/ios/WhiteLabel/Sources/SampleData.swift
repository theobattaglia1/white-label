import SwiftUI

enum SampleData {
    static let playlists: [Playlist] = [
        Playlist(id: "pl-friday", title: "Friday Session", subtitle: "What to play through on the train home",
                 trackIDs: ["first-night", "duel", "lighting-the-fuse", "best-of-me"]),
        Playlist(id: "pl-pitch", title: "Pitch — Mira", subtitle: "For the Tuesday A&R call",
                 trackIDs: ["duel", "first-night"]),
        Playlist(id: "pl-ear", title: "Needs Your Ear", subtitle: "Flagged for review",
                 trackIDs: ["first-night", "best-of-me"]),
    ]

    static let rooms: [Room] = [
        Room(id: "rm-hudson", title: "Hudson Ingram LP", artist: "Hudson Ingram",
             trackIDs: ["first-night", "lighting-the-fuse"]),
        Room(id: "rm-ruby", title: "Ruby Plume — Single", artist: "Ruby Plume",
             trackIDs: ["duel"]),
        Room(id: "rm-daniel", title: "Daniel Price — EP", artist: "Daniel Price",
             trackIDs: ["best-of-me"]),
    ]

    static let inbox: [InboxItem] = [
        InboxItem(id: "ib-1", trackID: "first-night", sharedBy: "Maya Chen", context: "Hudson Ingram LP", isNew: true),
        InboxItem(id: "ib-2", trackID: "lighting-the-fuse", sharedBy: "Maya Chen", context: "Hudson Ingram LP", isNew: true),
        InboxItem(id: "ib-3", trackID: "duel", sharedBy: "Mira Tan", context: "Ruby Plume — Single", isNew: true),
        InboxItem(id: "ib-4", trackID: "best-of-me", sharedBy: "Olmo", context: "Daniel Price — EP", isNew: false),
    ]

    static func track(_ id: String) -> Track? { tracks.first { $0.id == id } }

    static let tracks: [Track] = [
        Track(
            id: "first-night",
            audio: "the-first-night-v1-pitch.mp3",
            title: "The First Night",
            artist: "Hudson Ingram",
            label: "Hudson Ingram LP",
            versionLabel: "Mix v3",
            catalog: "WL · 0142",
            durationMs: 214_000,
            credits: [
                Credit(key: "Key · Tempo", value: "F minor · 92"),
                Credit(key: "Produced", value: "PomPom"),
            ],
            // purple → coral → amber (the mock’s warm wash)
            mesh: [
                Color(hex: 0x6E4BD6), Color(hex: 0x8A4BC8), Color(hex: 0xB14B9E),
                Color(hex: 0x7A53C8), Color(hex: 0xC2566F), Color(hex: 0xE0734A),
                Color(hex: 0xC85A52), Color(hex: 0xE68A45), Color(hex: 0xF0A85A),
            ]
        ),
        Track(
            id: "lighting-the-fuse",
            audio: "lighting-the-fuse-v2.mp3",
            title: "Lighting The Fuse",
            artist: "Hudson Ingram",
            label: "Hudson Ingram LP",
            versionLabel: "Mix v3",
            catalog: "WL · 0148",
            durationMs: 256_000,
            credits: [
                Credit(key: "Key · Tempo", value: "A minor · 120"),
                Credit(key: "Produced", value: "PomPom"),
            ],
            mesh: [
                Color(hex: 0x2C3FB0), Color(hex: 0x3A52D6), Color(hex: 0x4663E8),
                Color(hex: 0x35499E), Color(hex: 0x4663E8), Color(hex: 0x5A7BF0),
                Color(hex: 0x1F2C6E), Color(hex: 0x3146A0), Color(hex: 0x6E86E8),
            ]
        ),
        Track(
            id: "duel",
            audio: "duel-v5.m4a",
            title: "Duel",
            artist: "Ruby Plume",
            label: "Ruby Plume — Single",
            versionLabel: "Clean v3",
            catalog: "WL · 0210",
            durationMs: 199_000,
            credits: [
                Credit(key: "Key · Tempo", value: "D minor · 76"),
                Credit(key: "Produced", value: "Mira Tan"),
            ],
            mesh: [
                Color(hex: 0xB1417E), Color(hex: 0xD0466A), Color(hex: 0xE15A6A),
                Color(hex: 0x9A3C8A), Color(hex: 0xE14B6A), Color(hex: 0xF07A6A),
                Color(hex: 0x6E2C7A), Color(hex: 0xB13F72), Color(hex: 0xF0996E),
            ]
        ),
        Track(
            id: "best-of-me",
            audio: "best-of-me-v2.mp3",
            title: "Best Of Me",
            artist: "Daniel Price",
            label: "Daniel Price — EP",
            versionLabel: "Mix v2",
            catalog: "WL · 0233",
            durationMs: 241_000,
            credits: [
                Credit(key: "Key · Tempo", value: "G major · 98"),
                Credit(key: "Produced", value: "Olmo"),
            ],
            mesh: [
                Color(hex: 0xC8902E), Color(hex: 0xE0A22E), Color(hex: 0xE8B84A),
                Color(hex: 0xA8742A), Color(hex: 0xE0A22E), Color(hex: 0xF0CC6A),
                Color(hex: 0x6E4E22), Color(hex: 0xB1842E), Color(hex: 0xE8C87A),
            ]
        ),
    ]
}
