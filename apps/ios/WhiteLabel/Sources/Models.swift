import SwiftUI

struct Credit: Identifiable, Hashable {
    let id = UUID()
    let key: String
    let value: String
}

/// One track in the now-playing world. `mesh` is the 9-color grid that drives
/// the living gradient cover; it stands in for the generative artwork.
struct Track: Identifiable, Hashable {
    let id: String
    var audio: String? = nil   // bundled file name, e.g. "duel-v5.m4a"
    let title: String
    let artist: String
    let label: String          // studio / room — the "Steelworks" slot
    let versionLabel: String   // "Mix v3"
    let catalog: String        // "WL · 0142"
    let durationMs: Int
    let credits: [Credit]
    let mesh: [Color]          // 9 colors, row-major 3×3
}

struct Version: Identifiable, Hashable {
    let id: String
    let label: String
    let loudness: String
    var approved: Bool = false
}

struct Note: Identifiable, Hashable, Codable {
    let id: UUID
    let positionMs: Int?   // nil = general note, otherwise pinned to a timestamp
    let author: String
    let body: String
    var resolved: Bool
    let versionLabel: String
}

struct Playlist: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let trackIDs: [String]
}

/// A project / room — a body of work for an artist.
struct Room: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let trackIDs: [String]
}

/// An inbox item — something shared with / routed to you.
struct InboxItem: Identifiable, Hashable {
    let id: String
    let trackID: String
    let sharedBy: String
    let context: String   // room / playlist name
    var isNew: Bool
}

extension Int {
    /// ms → "m:ss"
    var clock: String {
        let total = Swift.max(0, self) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
