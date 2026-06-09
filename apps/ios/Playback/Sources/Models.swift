import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct Credit: Identifiable, Hashable {
    let id = UUID()
    let key: String
    let value: String
}

/// One track in the now-playing world.
/// `coverArt` is an optional bundled image name — when present it fills the
/// Now Playing background full-bleed. `mesh` is the fallback generative gradient.
struct Track: Identifiable, Hashable {
    let id: String
    var audio: String? = nil      // bundled file name, e.g. "duel-v5.m4a"
    var importedAudioPath: String? = nil // app Documents-relative path
    var remoteAudioURL: String? = nil // service URL or API-relative path
    var remoteVersionID: String? = nil
    var coverArt: String? = nil   // bundled image name, e.g. "cover-the-first-night"
    var importedArtworkPath: String? = nil // app Documents-relative path
    var remoteArtworkURL: String? = nil
    var title: String
    var artist: String
    var label: String             // studio / room — the "Steelworks" slot
    var versionLabel: String      // "Mix v3"
    let catalog: String           // "PB ·0142"
    let durationMs: Int
    let credits: [Credit]
    let mesh: [Color]             // 9 colors — generative fallback when no coverArt
}

/// A user-created track persisted locally. It stores color tokens as hex values
/// so the native `Track` can stay focused on render-ready SwiftUI colors.
struct StoredTrack: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var artist: String
    var label: String
    var versionLabel: String
    var catalog: String
    var durationMs: Int
    var importedAudioPath: String?
    var sourceFileName: String?
    var importedArtworkPath: String?
    var meshHexes: [UInt]

    var track: Track {
        Track(
            id: id,
            importedAudioPath: importedAudioPath,
            importedArtworkPath: importedArtworkPath,
            title: title,
            artist: artist,
            label: label,
            versionLabel: versionLabel,
            catalog: catalog,
            durationMs: durationMs,
            credits: [
                Credit(key: "Key · Tempo", value: "Unknown"),
                Credit(key: "Produced", value: artist),
                Credit(key: "Source", value: sourceFileName ?? "Imported audio"),
            ],
            mesh: meshHexes.map { Color(hex: $0) }
        )
    }
}

enum TrackArtworkLoader {
    static func documentsURL(for relativePath: String) -> URL {
        if relativePath.hasPrefix("/") { return URL(fileURLWithPath: relativePath) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(relativePath)
    }

    #if canImport(UIKit)
    static func uiImage(for track: Track) -> UIImage? {
        if let path = track.importedArtworkPath, let image = uiImage(importedPath: path) {
            return image
        }
        if let name = track.coverArt {
            return UIImage(named: name)
        }
        return nil
    }

    static func uiImage(importedPath path: String) -> UIImage? {
        let url = documentsURL(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    #endif
}

struct TrackArtwork: View {
    let track: Track
    var cornerRadius: CGFloat = 8
    var showsKeyline = true
    var animateFallback = true

    var body: some View {
        ZStack {
            #if canImport(UIKit)
            if let image = TrackArtworkLoader.uiImage(for: track) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let remote = track.remoteArtworkURL,
                      let url = URL(string: remote) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        MeshCover(colors: track.mesh, animate: animateFallback, fillsSafeArea: false)
                    }
                }
            } else {
                MeshCover(colors: track.mesh, animate: animateFallback, fillsSafeArea: false)
            }
            #else
            MeshCover(colors: track.mesh, animate: animateFallback, fillsSafeArea: false)
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            if showsKeyline {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(PB.cream.opacity(0.14), lineWidth: 0.75)
            }
        }
        .accessibilityHidden(true)
    }
}

struct Version: Identifiable, Hashable {
    let id: String
    let label: String
    let loudness: String
    var approved: Bool = false
}

struct Note: Identifiable, Hashable, Codable {
    let id: UUID
    var apiID: String?     // server note_id, populated after successful POST /notes
    let positionMs: Int?   // nil = general note, otherwise pinned to a timestamp
    let author: String
    var body: String
    var resolved: Bool
    let versionLabel: String
}

struct Playlist: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var subtitle: String
    var trackIDs: [String]
}

struct ArtistSummary: Identifiable, Hashable {
    let id: String
    let name: String
    var trackIDs: [String]
    var projectIDs: [String]
}

/// A pinned item on Home — encoded as "type:id" (song / playlist / room).
enum PinKind: String { case song, playlist, room }
struct PinRef: Identifiable, Hashable {
    let kind: PinKind
    let targetID: String
    var id: String { "\(kind.rawValue):\(targetID)" }
    init(kind: PinKind, targetID: String) { self.kind = kind; self.targetID = targetID }
    init?(_ encoded: String) {
        let parts = encoded.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let rawKind = parts[0].lowercased()
        let k: PinKind?
        switch rawKind {
        case "song":
            k = .song
        case "playlist":
            k = .playlist
        case "room", "rooms", "project", "projects":
            k = .room
        default:
            k = PinKind(rawValue: rawKind)
        }
        guard let k else { return nil }
        kind = k; targetID = parts[1]
    }
}

/// A project / room — a body of work for an artist.
struct Room: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let artist: String
    var trackIDs: [String]
}

/// An inbox item — something shared with / routed to you.
struct InboxItem: Identifiable, Hashable, Codable {
    let id: String
    let trackID: String
    let sharedBy: String
    let context: String   // room / playlist name
    var isNew: Bool
}

struct SavedViewSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
}

struct CreatedShareLinkSummary: Hashable {
    let linkID: String
    let url: String
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
    init(_ url: URL) { self.url = url }
}

extension Int {
    /// ms → "m:ss"
    var clock: String {
        let total = Swift.max(0, self) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
