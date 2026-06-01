import Foundation

/// Workspace state for the producer side. Reads from either
/// `PMWSampleData` (default, offline-friendly) or `PMWAPIClient` when
/// `PMWConfig.useRemoteAPI == true` (the `WL_USE_REMOTE_API=1` env var).
///
/// The store interface is stable across both modes so views don't care
/// where the data came from.
@MainActor
final class PMWStore: ObservableObject {
    @Published private(set) var room = PMWSampleData.room
    @Published private(set) var songs = PMWSampleData.songs
    @Published private(set) var versions = PMWSampleData.versions
    @Published private(set) var assets = PMWSampleData.assets
    @Published private(set) var notes = PMWSampleData.notes
    @Published var selectedSongID = "song-midnight"
    @Published var selectedTab: PMWTab = .library
    @Published var selectedPlaylistID: String? = nil
    @Published private(set) var savedViews: [PMWSavedView] = PMWSampleData.savedViews
    /// nil = "All" (no filter)
    @Published var selectedSavedViewID: String? = nil
    @Published var comparisonLeftID = "ver-midnight-v1"
    @Published var comparisonRightID = "ver-midnight-v2"
    @Published var offlineQueue: Set<String> = ["song-midnight", "song-witness"]
    @Published private(set) var lastError: String?

    // Loaded asynchronously from the API for Library / Playlists / Room switcher.
    @Published var roomsSummary: [PMWAPIClient.APIRoomSummary] = []
    @Published var libraryItems: [PMWAPIClient.APILibraryItem] = []
    @Published var playlistsList: [PMWAPIClient.APIPlaylist] = []

    func loadLibrarySurfaces() async {
        do {
            self.roomsSummary  = try await PMWAPIClient.shared.roomsSummary()
        } catch { print("roomsSummary failed:", error) }
        do {
            self.libraryItems  = try await PMWAPIClient.shared.library()
        } catch { print("library failed:", error) }
        do {
            self.playlistsList = try await PMWAPIClient.shared.playlists()
        } catch { print("playlists failed:", error) }
    }

    var selectedSong: PMWSong {
        songs.first { $0.id == selectedSongID } ?? songs[0]
    }
    var selectedVersions: [PMWVersion] {
        versions.filter { $0.songID == selectedSong.id }.sorted { $0.number < $1.number }
    }
    /// Returns the active version for the selected song, or nil if the song
    /// has no versions yet. Views must handle the empty case.
    var currentVersion: PMWVersion? {
        let versions = selectedVersions
        return versions.first { $0.id == selectedSong.currentVersionID } ?? versions.last
    }
    var currentAsset: PMWAsset? { asset(for: currentVersion) }

    var visibleNotes: [PMWVisibleNote] {
        guard let current = currentVersion else { return [] }
        return pmwVisibleNotes(songID: selectedSong.id, viewingVersion: current,
                               versions: selectedVersions, assets: assets, notes: notes)
    }

    var inboxItems: [PMWInboxItem] {
        songs.compactMap { song in
            guard let current = versions.first(where: { $0.id == song.currentVersionID }) else { return nil }
            return PMWInboxItem(
                song: song,
                currentVersion: current,
                sharedBy: "Maya Chen",
                newSinceLastListen: song.id == "song-midnight",
                offlineQueued: offlineQueue.contains(song.id)
            )
        }
    }

    func asset(for version: PMWVersion?) -> PMWAsset? {
        guard let version else { return nil }
        return assets.first { $0.id == version.assetID }
    }

    // MARK: - Selection / mutation -------------------------------------

    func selectSong(_ song: PMWSong) {
        selectedSongID = song.id
        let songVersions = versions.filter { $0.songID == song.id }.sorted { $0.number < $1.number }
        comparisonLeftID = songVersions.first?.id ?? comparisonLeftID
        comparisonRightID = song.currentVersionID
        selectedTab = .song
    }

    func setCurrent(_ version: PMWVersion) {
        versions = versions.map { candidate in
            guard candidate.songID == version.songID else { return candidate }
            var next = candidate
            next.isCurrent = candidate.id == version.id
            return next
        }
        songs = songs.map { song in
            guard song.id == version.songID else { return song }
            var next = song
            next.currentVersionID = version.id
            return next
        }
    }

    func addDemoVersion() {
        let nextNumber = selectedVersions.count + 1
        let assetID = "asset-\(selectedSong.id)-\(nextNumber)"
        let duration = (currentAsset?.durationMS ?? 190000) + 4000
        let asset = PMWSampleData.asset(assetID, "\(selectedSong.title) mix v\(nextNumber).wav",
                                        duration, -13.4, seed: nextNumber + 20)
        assets.append(asset)
        versions = versions.map { v in
            guard v.songID == selectedSong.id else { return v }
            var next = v
            next.isCurrent = false
            return next
        }
        let version = PMWVersion(
            id: "ver-\(selectedSong.id)-\(nextNumber)",
            songID: selectedSong.id,
            number: nextNumber,
            label: "Mix v\(nextNumber)",
            type: .mix,
            parentVersionID: currentVersion?.id,
            isCurrent: true,
            isApproved: false,
            assetID: assetID,
            createdAt: Date()
        )
        versions.append(version)
        songs = songs.map { song in
            guard song.id == selectedSong.id else { return song }
            var next = song
            next.currentVersionID = version.id
            next.status = "Review"
            return next
        }
    }

    func addNote(body: String, timestampMS: Int?) {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let current = currentVersion else { return }

        // Local optimistic note
        let local = PMWNote(
            id: UUID().uuidString,
            songID: selectedSong.id,
            anchorVersionID: current.id,
            author: "Theo Battaglia",
            body: body,
            scope: .song,
            timestampStartMS: timestampMS,
            timestampEndMS: nil,
            assignedTo: nil,
            priority: "normal",
            status: .open
        )
        notes.append(local)

        guard PMWConfig.useRemoteAPI else { return }
        Task {
            do {
                _ = try await PMWAPIClient.shared.createNote(
                    songID: selectedSong.id,
                    versionID: current.id,
                    body: body,
                    timestampMS: timestampMS,
                    author: "Theo Battaglia"
                )
            } catch {
                lastError = "Note may not have synced: \(error.localizedDescription)"
            }
        }
    }

    func resolve(_ visibleNote: PMWVisibleNote) {
        let resolvedOn = currentVersion?.id
        notes = notes.map { note in
            guard note.id == visibleNote.note.id else { return note }
            var next = note
            next.status = .resolved
            next.resolvedBy = "Theo Battaglia"
            next.resolvedAt = Date()
            next.resolvedOnVersionID = resolvedOn
            return next
        }
    }

    func reopen(_ visibleNote: PMWVisibleNote) {
        notes = notes.map { note in
            guard note.id == visibleNote.note.id else { return note }
            var next = note
            next.status = .open
            next.resolvedBy = nil
            next.resolvedAt = nil
            next.resolvedOnVersionID = nil
            return next
        }
    }

    func deliverables(for song: PMWSong) -> (ready: Bool, present: [String], missing: [String]) {
        let songVersions = versions.filter { $0.songID == song.id }
        let types = Set(songVersions.map(\.type))
        let hasStems = songVersions.contains { asset(for: $0)?.hasStems == true }
        let rows: [(String, Bool)] = [
            ("clean", types.contains(.clean)),
            ("explicit", types.contains(.explicit) || !song.explicit),
            ("instrumental", types.contains(.instrumental)),
            ("acapella", types.contains(.acapella)),
            ("stems", hasStems),
            ("BPM", song.bpm > 0),
            ("key", !song.songKey.isEmpty)
        ]
        let present = rows.filter(\.1).map(\.0)
        let missing = rows.filter { !$0.1 }.map(\.0)
        return (missing.isEmpty, present, missing)
    }

    /// Client-side release-readiness string derived from deliverables.
    /// Returns "ready" when all deliverables are present, nil otherwise.
    func releaseReadiness(for song: PMWSong) -> String? {
        deliverables(for: song).ready ? "ready" : nil
    }

    /// The active saved view, if any.
    var activeSavedView: PMWSavedView? {
        guard let id = selectedSavedViewID else { return nil }
        return savedViews.first { $0.id == id }
    }

    /// Songs filtered by the currently active saved view.
    /// Falls through to the full list when selectedSavedViewID is nil.
    var smartFilteredSongs: [PMWSong] {
        guard let view = activeSavedView else { return songs }
        return songs.filter { song in
            pmwMatchesSmart(song: song,
                            readiness: releaseReadiness(for: song),
                            view: view)
        }
    }

    func assistantAnswer(for question: String) -> String {
        let normalized = question.lowercased()
        if normalized.contains("heard") || normalized.contains("hasn't") {
            return "Hudson Ingram, Alex Rivera, and Dana Kim have not heard The First Night · Mix v2."
        }
        if normalized.contains("missing") || normalized.contains("deliverable") {
            return songs.map { song in
                let missing = deliverables(for: song).missing.joined(separator: ", ")
                return "\(song.title): missing \(missing)"
            }.joined(separator: "\n")
        }
        return "\(room.title) has \(songs.count) songs, \(versions.count) versions, and \(notes.filter { $0.status == .open }.count) open notes. The assistant is read-only."
    }

    // MARK: - Loading from API ----------------------------------------

    /// Hydrate from the Fastify API. No-op when `useRemoteAPI` is false.
    /// Call from `.task { ... }` on the root view.
    func loadFromAPIIfEnabled() async {
        guard PMWConfig.useRemoteAPI else { return }
        do {
            let payload = try await PMWAPIClient.shared.room()
            adopt(payload: payload)
        } catch {
            lastError = "Could not load workspace: \(error.localizedDescription)"
        }
    }

    func adoptRoomPayload(_ payload: PMWAPIClient.RoomPayload) { adopt(payload: payload) }

    private func adopt(payload: PMWAPIClient.RoomPayload) {
        room = PMWRoom(
            id: payload.room.room_id,
            title: payload.room.title,
            detail: payload.room.description ?? "",
            versionPolicy: "full history",
            downloadPolicy: "none"
        )
        songs = payload.songs.map { s in
            PMWSong(
                id: s.song_id, roomID: payload.room.room_id,
                title: s.title, artistName: s.artist_display_name ?? "",
                projectName: s.project_name ?? "",
                status: s.status,
                currentVersionID: s.current_version_id ?? "",
                approvedVersionID: s.approved_version_id,
                bpm: s.bpm ?? 0, songKey: s.song_key ?? "",
                explicit: s.explicit_flag ?? false
            )
        }
        versions = payload.versions.map { v in
            PMWVersion(
                id: v.version_id, songID: v.song_id,
                number: v.version_number,
                label: v.version_label ?? "v\(v.version_number)",
                type: PMWVersionType(rawValue: v.type) ?? .mix,
                parentVersionID: v.parent_version_id,
                isCurrent: v.is_current,
                isApproved: v.is_approved,
                assetID: v.file_asset_id,
                createdAt: Date()
            )
        }
        assets = payload.assets.map { a in
            PMWAsset(
                id: a.asset_id,
                filename: a.original_filename,
                durationMS: a.duration_ms ?? 0,
                loudnessLUFS: a.loudness_lufs ?? -14,
                waveform: a.waveform_peaks ?? [],
                hasStems: a.key_stems_zip != nil,
                assetURLPath: a.playback_url?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
        }
        notes = payload.notes.map { n in
            PMWNote(
                id: n.note_id, songID: n.song_id,
                anchorVersionID: n.anchor_version_id,
                author: n.author_guest_label ?? n.author_user_id ?? "Anonymous",
                body: n.body ?? "",
                scope: PMWNoteScope(rawValue: n.scope) ?? .song,
                timestampStartMS: n.timestamp_start_ms,
                timestampEndMS: n.timestamp_end_ms,
                assignedTo: nil,
                priority: "normal",
                status: PMWNoteStatus(rawValue: n.status) ?? .open
            )
        }
        if let first = songs.first { selectSong(first) }
    }
}

enum PMWTab: String, CaseIterable, Identifiable {
    case library, song, inbox, playlists, room, compare, links, ask
    var id: String { rawValue }

    /// HIG-compliant primary tabs (max 5). The remaining cases live in a More sheet.
    static let primary: [PMWTab] = [.library, .song, .inbox]
    static let secondary: [PMWTab] = [.playlists, .room, .compare, .links, .ask]

    var title: String {
        switch self {
        case .library: "Library"
        case .song: "Song"
        case .inbox: "Inbox"
        case .playlists: "Playlists"
        case .room: "Room"
        case .compare: "Compare"
        case .links: "Links"
        case .ask: "Ask"
        }
    }

    var symbol: String {
        switch self {
        case .library: "music.note.list"
        case .song: "waveform"
        case .inbox: "tray"
        case .playlists: "list.bullet.rectangle"
        case .room: "square.stack"
        case .compare: "rectangle.split.2x1"
        case .links: "link"
        case .ask: "message"
        }
    }

    /// True if this tab appears directly in the bottom bar.
    var isPrimary: Bool { Self.primary.contains(self) }
}
