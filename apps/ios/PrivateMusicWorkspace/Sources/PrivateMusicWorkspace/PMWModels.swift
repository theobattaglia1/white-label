import Foundation

enum PMWVersionType: String, CaseIterable, Identifiable {
    case demo
    case rough
    case mix
    case master
    case clean
    case explicit
    case instrumental
    case acapella

    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

enum PMWNoteScope: String {
    case song
    case version
}

enum PMWNoteStatus: String {
    case open
    case resolved
}

struct PMWUser: Identifiable, Equatable {
    let id: String
    var displayName: String
    var role: String
}

struct PMWRoom: Identifiable, Equatable {
    let id: String
    var title: String
    var detail: String
    var versionPolicy: String
    var downloadPolicy: String
}

struct PMWAsset: Identifiable, Equatable {
    let id: String
    var filename: String
    var durationMS: Int
    var loudnessLUFS: Double
    var waveform: [Double]
    var hasStems: Bool
    /// Path under PMWConfig.audioBaseURL, e.g. "seed-audio/halftime-v2.mp3".
    /// nil = no playable audio (waveform/scrub still works in virtual mode).
    var assetURLPath: String?
}

struct PMWVersion: Identifiable, Equatable {
    let id: String
    var songID: String
    var number: Int
    var label: String
    var type: PMWVersionType
    var parentVersionID: String?
    var isCurrent: Bool
    var isApproved: Bool
    var assetID: String
    var createdAt: Date
}

struct PMWSong: Identifiable, Equatable {
    let id: String
    var roomID: String
    var title: String
    var artistName: String
    var projectName: String
    var status: String
    var currentVersionID: String
    var approvedVersionID: String?
    var bpm: Int
    var songKey: String
    var explicit: Bool

    /// e.g. "WL · 0142" — pencil-tone catalog label.
    var catalogId: String {
        let suffix = id.split(separator: "-").last.map(String.init) ?? id
        return "WL · " + String(suffix.uppercased().prefix(4))
    }
}

struct PMWNote: Identifiable, Equatable {
    let id: String
    var songID: String
    var anchorVersionID: String
    var author: String
    var body: String
    var scope: PMWNoteScope
    var timestampStartMS: Int?
    var timestampEndMS: Int?
    var assignedTo: String?
    var priority: String
    var status: PMWNoteStatus
    var resolvedBy: String?
    var resolvedAt: Date?
    var resolvedOnVersionID: String?
}

struct PMWVisibleNote: Identifiable, Equatable {
    var note: PMWNote
    var anchorLabel: String
    var isCarried: Bool
    var isCollapsed: Bool
    var approximateTimestamp: Bool

    var id: String { note.id }
}

struct PMWInboxItem: Identifiable, Equatable {
    var id: String { song.id }
    var song: PMWSong
    var currentVersion: PMWVersion
    var sharedBy: String
    var newSinceLastListen: Bool
    var offlineQueued: Bool
}

func pmwTimestamp(_ milliseconds: Int?) -> String {
    guard let milliseconds else { return "General" }
    let seconds = max(0, milliseconds / 1000)
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}

func pmwDurationDiffExceeds(anchorMS: Int, currentMS: Int, threshold: Double = 0.05) -> Bool {
    guard anchorMS > 0, currentMS > 0 else { return false }
    return abs(Double(currentMS - anchorMS)) / Double(anchorMS) > threshold
}

func pmwVisibleNotes(
    songID: String,
    viewingVersion: PMWVersion,
    versions: [PMWVersion],
    assets: [PMWAsset],
    notes: [PMWNote]
) -> [PMWVisibleNote] {
    let versionByID = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, $0) })
    let assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })

    return notes
        .filter { $0.songID == songID }
        .compactMap { note -> PMWVisibleNote? in
            guard let anchor = versionByID[note.anchorVersionID] else { return nil }
            if note.scope == .version, note.anchorVersionID != viewingVersion.id {
                return nil
            }
            if note.scope == .song, anchor.number > viewingVersion.number {
                return nil
            }
            if note.status == .resolved,
               let resolvedID = note.resolvedOnVersionID,
               let resolvedVersion = versionByID[resolvedID],
               viewingVersion.number > resolvedVersion.number {
                return nil
            }
            let isCarried = note.scope == .song && anchor.number < viewingVersion.number
            let anchorDuration = assetByID[anchor.assetID]?.durationMS ?? 0
            let currentDuration = assetByID[viewingVersion.assetID]?.durationMS ?? 0
            return PMWVisibleNote(
                note: note,
                anchorLabel: anchor.label,
                isCarried: isCarried,
                isCollapsed: note.status == .resolved,
                approximateTimestamp: isCarried && note.timestampStartMS != nil && pmwDurationDiffExceeds(anchorMS: anchorDuration, currentMS: currentDuration)
            )
        }
        .sorted { ($0.note.timestampStartMS ?? Int.max) < ($1.note.timestampStartMS ?? Int.max) }
}

