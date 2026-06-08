import SwiftUI
import Observation

enum WorkspaceSyncState: String, Codable {
    case ready = "Saved on device"
    case saving = "Saving"
    case syncing = "Syncing"
    case synced = "Synced"
    case offline = "Offline changes"
    case error = "Save failed"
}

/// Holds the workspace layer — versions and notes per track — seeded with the
/// sample catalog. Notes added while listening are kept here for the session.
@Observable
final class WorkspaceStore {
    var versionsByTrack: [String: [Version]] = [:]
    var currentByTrack: [String: String] = [:]
    var notesByTrack: [String: [Note]] = [:]
    var titleOverrides: [String: String] = [:]
    var pins: [String] = []                          // ordered "type:id" refs
    var localPlaylists: [Playlist] = SampleData.playlists  // mutable; drafts and offline lists
    var customRooms: [Room] = []
    var customTracks: [StoredTrack] = []
    var serviceTracks: [Track] = []
    var serviceRooms: [Room] = []
    var servicePlaylists: [Playlist] = []
    var servicePlaylistItemIDs: [String: [String: String]] = [:]
    var savedViews: [SavedViewSummary] = []
    var inbox: [InboxItem] = SampleData.inbox
    var activity: [String: Date] = [:]                // ref id → last opened
    var syncState: WorkspaceSyncState = .ready
    var syncMessage: String = "Local library"
    var lastSavedAt: Date?
    @ObservationIgnored private var draftIDs: Set<String> = []

    func touch(_ ref: String) { activity[ref] = Date(); persist() }

    /// Taggable workspace members.
    let members = ["PomPom", "Liz Rose", "Mira Tan", "Hudson", "Alex", "TB"]

    private let notesKey = "wl.notes.v1"
    private let currentKey = "wl.current.v1"
    private let titlesKey = "wl.titles.v1"
    private let pinsKey = "wl.pins.v1"
    private let playlistsKey = "wl.playlists.v1"
    private let customRoomsKey = "wl.customRooms.v1"
    private let customTracksKey = "wl.customTracks.v1"
    private let inboxKey = "wl.inbox.v1"
    private let activityKey = "wl.activity.v1"

    // MARK: tracks

    var isUsingServiceLibrary: Bool { !serviceTracks.isEmpty || syncState == .synced || syncState == .syncing }
    var tracks: [Track] {
        if isUsingServiceLibrary { return customTracks.map(\.track) + serviceTracks }
        return customTracks.map(\.track) + SampleData.tracks
    }
    var playlists: [Playlist] {
        if isUsingServiceLibrary {
            var merged = localPlaylists
            for playlist in servicePlaylists where !merged.contains(where: { $0.id == playlist.id }) {
                merged.append(playlist)
            }
            return merged
        }
        return localPlaylists
    }
    var rooms: [Room] {
        if isUsingServiceLibrary {
            return customRooms + serviceRooms.filter { service in !customRooms.contains(where: { $0.id == service.id }) }
        }
        return customRooms + SampleData.rooms.filter { sample in !customRooms.contains(where: { $0.id == sample.id }) }
    }

    func track(_ id: String) -> Track? {
        customTracks.first { $0.id == id }?.track
            ?? serviceTracks.first { $0.id == id }
            ?? SampleData.track(id)
    }

    @MainActor
    func refreshFromService() async {
        guard Config.useRemoteAPI else { return }
        syncState = .syncing
        syncMessage = "Syncing library"
        do {
            async let library = ServiceClient.shared.library()
            async let playlists = ServiceClient.shared.playlists()
            async let views = ServiceClient.shared.savedViews()

            let libraryItems = try await library
            let playlistSummaries = try await playlists
            let savedViewItems = (try? await views) ?? []

            var details: [ServiceClient.APIPlaylistDetail] = []
            for playlist in playlistSummaries {
                if let detail = try? await ServiceClient.shared.playlist(playlist.playlist_id) {
                    details.append(detail)
                }
            }

            adoptService(library: libraryItems, playlistDetails: details, savedViews: savedViewItems)
            lastSavedAt = Date()
            syncState = .synced
            syncMessage = "Synced with cloud"
        } catch {
            syncState = isUsingServiceLibrary ? .offline : .ready
            syncMessage = "Cloud sync unavailable"
        }
    }

    @MainActor
    func uploadImportedSong(
        title: String,
        artist: String,
        project: String,
        versionLabel: String,
        durationMs: Int,
        importedAudioPath: String?,
        sourceFileName: String?,
        importedArtworkPath: String?,
        artworkPalette: [UInt]?
    ) async -> Track {
        guard Config.useRemoteAPI,
              let importedAudioPath,
              let audioURL = importedFileURL(importedAudioPath)
        else {
            return createTrack(
                title: title,
                artist: artist,
                project: project,
                versionLabel: versionLabel,
                durationMs: durationMs,
                importedAudioPath: importedAudioPath,
                sourceFileName: sourceFileName,
                importedArtworkPath: importedArtworkPath,
                artworkPalette: artworkPalette
            )
        }

        syncState = .syncing
        syncMessage = "Uploading song"
        do {
            let result = try await ServiceClient.shared.uploadNewSong(
                audioURL: audioURL,
                title: title,
                artist: artist,
                project: project,
                versionLabel: versionLabel,
                durationMs: durationMs,
                artworkPath: importedArtworkPath
            )
            await refreshFromService()
            if let synced = track(result.songExternalId) { return synced }
            syncState = .synced
            syncMessage = "Uploaded"
        } catch {
            syncState = .offline
            syncMessage = "Saved locally; upload failed"
        }

        return createTrack(
            title: title,
            artist: artist,
            project: project,
            versionLabel: versionLabel,
            durationMs: durationMs,
            importedAudioPath: importedAudioPath,
            sourceFileName: sourceFileName,
            importedArtworkPath: importedArtworkPath,
            artworkPalette: artworkPalette
        )
    }

    func createTrack(
        title: String,
        artist: String,
        project: String,
        versionLabel: String,
        durationMs: Int,
        importedAudioPath: String? = nil,
        sourceFileName: String? = nil,
        importedArtworkPath: String? = nil,
        artworkPalette: [UInt]? = nil
    ) -> Track {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVersion = versionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = "song-\(Self.slug(trimmedTitle.isEmpty ? "untitled" : trimmedTitle))-\(UUID().uuidString.prefix(5))"
        let versionID = "\(id)-v1"
        let stored = StoredTrack(
            id: id,
            title: trimmedTitle.isEmpty ? "Untitled Song" : trimmedTitle,
            artist: trimmedArtist.isEmpty ? "Unknown Artist" : trimmedArtist,
            label: trimmedProject.isEmpty ? "Unfiled" : trimmedProject,
            versionLabel: trimmedVersion.isEmpty ? "Demo v1" : trimmedVersion,
            catalog: nextCatalog(),
            durationMs: max(15_000, durationMs),
            importedAudioPath: importedAudioPath,
            sourceFileName: sourceFileName,
            importedArtworkPath: importedArtworkPath,
            meshHexes: Self.normalizedPalette(artworkPalette) ?? Self.palette(for: customTracks.count)
        )
        customTracks.insert(stored, at: 0)
        versionsByTrack[id] = [Version(id: versionID, label: stored.versionLabel, loudness: "Not analyzed")]
        currentByTrack[id] = versionID
        addTrackToProject(trackID: id, project: stored.label, artist: stored.artist)
        persist()
        return stored.track
    }

    @MainActor
    func updateTrack(
        _ id: String,
        title: String,
        artist: String,
        project: String,
        versionLabel: String,
        importedArtworkPath: String?,
        artworkPalette: [UInt]? = nil,
        artworkChanged: Bool = false
    ) async throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVersion = versionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = customTracks.firstIndex(where: { $0.id == id }) else {
            try await updateServiceTrack(
                id,
                title: trimmedTitle,
                artist: trimmedArtist,
                project: trimmedProject,
                versionLabel: trimmedVersion,
                importedArtworkPath: importedArtworkPath,
                artworkChanged: artworkChanged
            )
            return
        }
        let previousArtwork = customTracks[i].importedArtworkPath

        customTracks[i].title = trimmedTitle.isEmpty ? "Untitled Song" : trimmedTitle
        customTracks[i].artist = trimmedArtist.isEmpty ? "Unknown Artist" : trimmedArtist
        customTracks[i].label = trimmedProject.isEmpty ? "Unfiled" : trimmedProject
        customTracks[i].versionLabel = trimmedVersion.isEmpty ? "Demo v1" : trimmedVersion
        customTracks[i].importedArtworkPath = importedArtworkPath
        if let palette = Self.normalizedPalette(artworkPalette) {
            customTracks[i].meshHexes = palette
        }

        if previousArtwork != importedArtworkPath {
            deleteImportedFile(at: previousArtwork)
        }
        addTrackToProject(trackID: id, project: customTracks[i].label, artist: customTracks[i].artist)
        persist()
    }

    @MainActor
    private func updateServiceTrack(
        _ id: String,
        title: String,
        artist: String,
        project: String,
        versionLabel: String,
        importedArtworkPath: String?,
        artworkChanged: Bool
    ) async throws {
        guard let i = serviceTracks.firstIndex(where: { $0.id == id }) else { return }
        let nextTitle = title.isEmpty ? serviceTracks[i].title : title
        let nextArtist = artist.isEmpty ? serviceTracks[i].artist : artist
        let nextProject = project.isEmpty ? serviceTracks[i].label : project
        let nextVersion = versionLabel.isEmpty ? serviceTracks[i].versionLabel : versionLabel
        serviceTracks[i].title = nextTitle
        serviceTracks[i].artist = nextArtist
        serviceTracks[i].label = nextProject
        serviceTracks[i].versionLabel = nextVersion
        if artworkChanged {
            serviceTracks[i].importedArtworkPath = importedArtworkPath
            if importedArtworkPath == nil {
                serviceTracks[i].remoteArtworkURL = nil
            }
        }
        syncState = .syncing
        syncMessage = "Syncing edits"

        do {
            _ = try await ServiceClient.shared.patchSong(
                id,
                title: nextTitle,
                artist: nextArtist,
                project: nextProject,
                artworkPath: importedArtworkPath,
                artworkChanged: artworkChanged
            )
            if let versionID = serviceTracks[i].remoteVersionID {
                try await ServiceClient.shared.patchVersion(versionID, versionLabel: nextVersion)
            }
            await refreshFromService()
            syncState = .synced
            syncMessage = "Synced with cloud"
            lastSavedAt = Date()
        } catch {
            syncState = .offline
            syncMessage = "Edit saved locally"
            throw error
        }
    }

    private func adoptService(
        library: [ServiceClient.APILibraryItem],
        playlistDetails: [ServiceClient.APIPlaylistDetail],
        savedViews: [ServiceClient.APISavedView]
    ) {
        let tracks = library.map { item in serviceTrack(from: item) }
        serviceTracks = tracks

        var grouped: [String: (title: String, artist: String, ids: [String])] = [:]
        for item in library {
            guard let room = item.room else { continue }
            var value = grouped[room.room_id] ?? (room.title, item.song.artist_display_name ?? "", [])
            value.ids.append(item.song.song_id)
            grouped[room.room_id] = value
        }
        serviceRooms = grouped.map { id, value in
            Room(id: id, title: value.title, artist: value.artist.isEmpty ? "Workspace" : value.artist, trackIDs: value.ids)
        }
        .sorted { $0.title < $1.title }

        var itemIDsByPlaylist: [String: [String: String]] = [:]
        servicePlaylists = playlistDetails.map { detail in
            let entries = detail.items.sorted { $0.item.position < $1.item.position }
            itemIDsByPlaylist[detail.playlist.playlist_id] = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
                guard let songID = entry.song?.song_id ?? entry.current_version?.song_id else { return nil }
                return (songID, entry.item.playlist_item_id)
            })
            return Playlist(
                id: detail.playlist.playlist_id,
                title: detail.playlist.title,
                subtitle: detail.playlist.description ?? "",
                trackIDs: entries.compactMap { $0.song?.song_id ?? $0.current_version?.song_id }
            )
        }
        servicePlaylistItemIDs = itemIDsByPlaylist

        self.savedViews = savedViews.map { view in
            SavedViewSummary(
                id: view.view_id,
                name: view.name,
                detail: view.filter?.map { "\($0.key): \($0.value)" }.joined(separator: " · ") ?? "Smart view"
            )
        }
    }

    private func serviceTrack(from item: ServiceClient.APILibraryItem) -> Track {
        let song = item.song
        let version = item.current_version
        let asset = item.asset
        let colors = Self.palette(for: abs(song.song_id.hashValue))
        return Track(
            id: song.song_id,
            remoteAudioURL: serviceURL(asset?.playback_url),
            remoteVersionID: version?.version_id,
            remoteArtworkURL: serviceURL(song.artwork_url),
            title: song.title,
            artist: song.artist_display_name ?? "Unknown Artist",
            label: item.room?.title ?? song.project_name ?? "Cloud Library",
            versionLabel: version?.version_label ?? "Current",
            catalog: catalogLabel(song.song_id),
            durationMs: max(15_000, asset?.duration_ms ?? 180_000),
            credits: [
                Credit(key: "Key · Tempo", value: keyTempo(song)),
                Credit(key: "Source", value: "Cloud library"),
            ],
            mesh: colors.map { Color(hex: $0) }
        )
    }

    private func serviceURL(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") {
            return URL(string: raw, relativeTo: Config.apiBaseURL)?.absoluteString
        }
        return raw
    }

    private func keyTempo(_ song: ServiceClient.APISong) -> String {
        let key = song.song_key ?? "Unknown"
        if let bpm = song.bpm { return "\(key) · \(bpm)" }
        return key
    }

    private func catalogLabel(_ id: String) -> String {
        let hash = abs(id.hashValue % 9000) + 1000
        return "PB ·\(hash)"
    }

    func isCustomTrack(_ id: String) -> Bool {
        customTracks.contains { $0.id == id }
    }

    func isEditableTrack(_ id: String) -> Bool {
        isCustomTrack(id) || serviceTracks.contains { $0.id == id }
    }

    func deleteTrack(_ id: String) {
        guard let i = customTracks.firstIndex(where: { $0.id == id }) else { return }
        let removed = customTracks.remove(at: i)
        localPlaylists.indices.forEach { localPlaylists[$0].trackIDs.removeAll { $0 == id } }
        customRooms.indices.forEach { customRooms[$0].trackIDs.removeAll { $0 == id } }
        pins.removeAll {
            guard let ref = PinRef($0) else { return false }
            return ref.kind == .song && ref.targetID == id
        }
        inbox.removeAll { $0.trackID == id }
        notesByTrack[id] = nil
        currentByTrack[id] = nil
        versionsByTrack[id] = nil
        titleOverrides[id] = nil
        activity.removeValue(forKey: PinRef(kind: .song, targetID: id).id)
        deleteImportedFile(at: removed.importedAudioPath)
        deleteImportedFile(at: removed.importedArtworkPath)
        persist()
    }

    // MARK: pins

    func isPinned(_ ref: String) -> Bool { pins.contains(ref) }
    func togglePin(_ ref: String) {
        if let i = pins.firstIndex(of: ref) { pins.remove(at: i) } else { pins.append(ref) }
        persist()
    }
    func movePin(from: IndexSet, to: Int) { pins.move(fromOffsets: from, toOffset: to); persist() }

    // MARK: playlists (mutable; drafts aren't persisted until kept)

    func playlist(_ id: String) -> Playlist? {
        localPlaylists.first { $0.id == id } ?? servicePlaylists.first { $0.id == id }
    }
    func isDraft(_ id: String) -> Bool { draftIDs.contains(id) }

    func createPlaylist(trackIDs: [String], title: String = "New Playlist") -> Playlist {
        let pl = Playlist(id: "pl-\(UUID().uuidString.prefix(6))", title: title, subtitle: "Draft", trackIDs: trackIDs)
        localPlaylists.insert(pl, at: 0)
        draftIDs.insert(pl.id)
        return pl
    }
    func createKeptPlaylist(title: String, trackIDs: [String]) -> Playlist {
        let pl = createPlaylist(trackIDs: trackIDs, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Playlist" : title)
        keepPlaylist(pl.id)
        syncCreatedPlaylist(localID: pl.id, title: pl.title, trackIDs: trackIDs)
        return playlist(pl.id) ?? pl
    }
    func keepPlaylist(_ id: String, title: String? = nil) {
        if let title, let i = localPlaylists.firstIndex(where: { $0.id == id }) {
            localPlaylists[i].title = title; localPlaylists[i].subtitle = ""
        } else if let i = localPlaylists.firstIndex(where: { $0.id == id }) {
            localPlaylists[i].subtitle = ""
        }
        draftIDs.remove(id)
        persist()
    }
    func discardPlaylist(_ id: String) {
        localPlaylists.removeAll { $0.id == id }
        draftIDs.remove(id)
        persist()
    }
    func addTrack(_ trackID: String, toPlaylist id: String) {
        if let i = localPlaylists.firstIndex(where: { $0.id == id }) {
            guard !localPlaylists[i].trackIDs.contains(trackID) else { return }
            localPlaylists[i].trackIDs.append(trackID)
            if !isDraft(id) { persist() }
            syncAddedTrack(trackID, toPlaylist: id)
            return
        }
        guard let i = servicePlaylists.firstIndex(where: { $0.id == id }),
              !servicePlaylists[i].trackIDs.contains(trackID)
        else { return }
        servicePlaylists[i].trackIDs.append(trackID)
        syncAddedTrack(trackID, toPlaylist: id)
    }
    func addTrack(_ trackID: String, toProject id: String) {
        if let i = customRooms.firstIndex(where: { $0.id == id }) {
            if !customRooms[i].trackIDs.contains(trackID) {
                customRooms[i].trackIDs.insert(trackID, at: 0)
                persist()
            }
            return
        }
        guard let sample = SampleData.rooms.first(where: { $0.id == id }) else { return }
        var updated = sample
        if !updated.trackIDs.contains(trackID) { updated.trackIDs.insert(trackID, at: 0) }
        customRooms.insert(updated, at: 0)
        persist()
    }
    func removeTrack(_ trackID: String, fromProject id: String) {
        if let i = customRooms.firstIndex(where: { $0.id == id }) {
            customRooms[i].trackIDs.removeAll { $0 == trackID }
            persist()
            return
        }

        if let i = serviceRooms.firstIndex(where: { $0.id == id }) {
            serviceRooms[i].trackIDs.removeAll { $0 == trackID }
            syncMessage = "Project change saved locally"
            return
        }

        guard var room = SampleData.rooms.first(where: { $0.id == id }) else { return }
        room.trackIDs.removeAll { $0 == trackID }
        customRooms.insert(room, at: 0)
        persist()
    }
    func reorderPlaylist(_ id: String, _ trackIDs: [String]) {
        if let i = localPlaylists.firstIndex(where: { $0.id == id }) {
            localPlaylists[i].trackIDs = trackIDs
            if !isDraft(id) { persist() }
            return
        }
        guard let i = servicePlaylists.firstIndex(where: { $0.id == id }) else { return }
        servicePlaylists[i].trackIDs = trackIDs
        syncReorderedPlaylist(id, trackIDs)
    }
    func removeTrack(_ trackID: String, fromPlaylist id: String) {
        if let i = localPlaylists.firstIndex(where: { $0.id == id }) {
            localPlaylists[i].trackIDs.removeAll { $0 == trackID }
            if !isDraft(id) { persist() }
            return
        }
        guard let i = servicePlaylists.firstIndex(where: { $0.id == id }) else { return }
        servicePlaylists[i].trackIDs.removeAll { $0 == trackID }
        syncRemovedTrack(trackID, fromPlaylist: id)
    }

    private func syncCreatedPlaylist(localID: String, title: String, trackIDs: [String]) {
        guard Config.useRemoteAPI else { return }
        syncState = .syncing
        syncMessage = "Syncing playlist"
        Task {
            do {
                let remote = try await ServiceClient.shared.createPlaylist(title: title)
                for trackID in trackIDs {
                    _ = try? await ServiceClient.shared.addToPlaylist(playlistID: remote.playlist_id, songID: trackID)
                }
                await MainActor.run {
                    self.localPlaylists.removeAll { $0.id == localID }
                    self.persist()
                }
                await refreshFromService()
            } catch {
                await MainActor.run {
                    self.syncState = .offline
                    self.syncMessage = "Playlist saved locally"
                }
            }
        }
    }

    private func syncReorderedPlaylist(_ id: String, _ trackIDs: [String]) {
        guard Config.useRemoteAPI,
              servicePlaylists.contains(where: { $0.id == id }),
              let itemIDsBySong = servicePlaylistItemIDs[id]
        else { return }
        let itemIDs = trackIDs.compactMap { itemIDsBySong[$0] }
        guard itemIDs.count == trackIDs.count else { return }
        syncState = .syncing
        syncMessage = "Syncing playlist order"
        Task {
            do {
                try await ServiceClient.shared.reorderPlaylist(playlistID: id, itemIDs: itemIDs)
                await refreshFromService()
            } catch {
                await MainActor.run {
                    self.syncState = .offline
                    self.syncMessage = "Playlist order saved locally"
                }
            }
        }
    }

    private func syncRemovedTrack(_ trackID: String, fromPlaylist id: String) {
        guard Config.useRemoteAPI,
              servicePlaylists.contains(where: { $0.id == id }),
              let itemID = servicePlaylistItemIDs[id]?[trackID]
        else { return }
        syncState = .syncing
        syncMessage = "Syncing playlist"
        Task {
            do {
                try await ServiceClient.shared.removeFromPlaylist(playlistID: id, itemID: itemID)
                await refreshFromService()
            } catch {
                await MainActor.run {
                    self.syncState = .offline
                    self.syncMessage = "Playlist change saved locally"
                }
            }
        }
    }

    @MainActor
    func createShareLink(for track: Track, allowDownload: Bool = false) async throws -> String {
        try await createShareLinkDetails(for: track, allowDownload: allowDownload).url
    }

    @MainActor
    func createShareLinkDetails(for track: Track, allowDownload: Bool = false) async throws -> CreatedShareLinkSummary {
        syncState = .syncing
        syncMessage = allowDownload ? "Preparing export link" : "Creating share link"
        do {
            let created = try await ServiceClient.shared.createShareLink(targetType: "song", targetID: track.id, allowDownload: allowDownload)
            syncState = .synced
            syncMessage = allowDownload ? "Export link ready" : "Share link ready"
            lastSavedAt = Date()
            return CreatedShareLinkSummary(linkID: created.link.link_id, url: Config.shareURL(token: created.token))
        } catch {
            syncState = .offline
            syncMessage = allowDownload ? "Export link unavailable" : "Share link unavailable"
            throw error
        }
    }

    @MainActor
    func inviteRecipients(
        linkID: String,
        recipients: [(email: String, displayName: String?, role: String)]
    ) async throws -> ServiceClient.APIInviteRecipientsResult {
        syncState = .syncing
        syncMessage = "Sending invites"
        do {
            let result = try await ServiceClient.shared.inviteRecipients(linkID: linkID, recipients: recipients)
            syncState = .synced
            syncMessage = result.delivery == "queued" ? "Invites sent" : "Invites saved"
            lastSavedAt = Date()
            return result
        } catch {
            syncState = .offline
            syncMessage = "Invites unavailable"
            throw error
        }
    }

    @MainActor
    func changeRecipientRole(linkID: String, recipientID: String, role: String) async throws -> ServiceClient.APIShareRecipient {
        try await ServiceClient.shared.patchRecipient(linkID: linkID, recipientID: recipientID, role: role)
    }

    @MainActor
    func revokeRecipient(linkID: String, recipientID: String) async throws -> ServiceClient.APIShareRecipient {
        try await ServiceClient.shared.revokeRecipient(linkID: linkID, recipientID: recipientID)
    }

    private func syncAddedTrack(_ trackID: String, toPlaylist id: String) {
        guard Config.useRemoteAPI,
              servicePlaylists.contains(where: { $0.id == id })
        else { return }
        syncState = .syncing
        syncMessage = "Syncing playlist"
        Task {
            do {
                _ = try await ServiceClient.shared.addToPlaylist(playlistID: id, songID: trackID)
                await refreshFromService()
            } catch {
                await MainActor.run {
                    self.syncState = .offline
                    self.syncMessage = "Playlist change saved locally"
                }
            }
        }
    }

    func createProject(title: String, artist: String) -> Room {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectTitle = trimmedTitle.isEmpty ? "New Project" : trimmedTitle
        let projectArtist = trimmedArtist.isEmpty ? "Unknown Artist" : trimmedArtist

        if let existing = rooms.first(where: { $0.title.caseInsensitiveCompare(projectTitle) == .orderedSame }) {
            return existing
        }

        let room = Room(
            id: "rm-\(Self.slug(projectTitle))-\(UUID().uuidString.prefix(5))",
            title: projectTitle,
            artist: projectArtist,
            trackIDs: []
        )
        customRooms.insert(room, at: 0)
        persist()
        return room
    }

    // MARK: inbox

    var inboxNewCount: Int { inbox.filter(\.isNew).count }

    func markInboxHeard(_ id: String) {
        guard let i = inbox.firstIndex(where: { $0.id == id }) else { return }
        inbox[i].isNew = false
        persist()
    }

    func markAllInboxHeard() {
        for i in inbox.indices { inbox[i].isNew = false }
        persist()
    }

    func toggleInboxNew(_ id: String) {
        guard let i = inbox.firstIndex(where: { $0.id == id }) else { return }
        inbox[i].isNew.toggle()
        persist()
    }

    func displayTitle(_ id: String, _ fallback: String) -> String {
        titleOverrides[id] ?? fallback
    }

    func rename(_ id: String, _ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { titleOverrides[id] = nil } else { titleOverrides[id] = t }
        persist()
    }

    init() {
        seed()
        loadPersisted()
    }

    func versions(_ track: String) -> [Version] {
        if let versions = versionsByTrack[track] { return versions }
        if let stored = customTracks.first(where: { $0.id == track }) {
            return [Version(id: "\(stored.id)-v1", label: stored.versionLabel, loudness: "Not analyzed")]
        }
        return []
    }

    func currentVersion(_ track: String) -> Version? {
        let id = currentByTrack[track]
        return versions(track).first { $0.id == id } ?? versions(track).last
    }

    func notes(_ track: String) -> [Note] {
        (notesByTrack[track] ?? []).sorted {
            ($0.positionMs ?? Int.max) < ($1.positionMs ?? Int.max)
        }
    }

    func openCount(_ track: String) -> Int { notes(track).filter { !$0.resolved }.count }

    func setCurrent(_ track: String, _ versionID: String) {
        currentByTrack[track] = versionID
        persist()
    }

    func addNote(track: String, positionMs: Int?, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let v = currentVersion(track)?.label ?? "—"
        let note = Note(id: UUID(), positionMs: positionMs, author: "TB", body: trimmed, resolved: false, versionLabel: v)
        notesByTrack[track, default: []].append(note)
        persist()
    }

    func toggleResolved(_ track: String, _ id: UUID) {
        guard var arr = notesByTrack[track], let i = arr.firstIndex(where: { $0.id == id }) else { return }
        arr[i].resolved.toggle()
        notesByTrack[track] = arr
        persist()
    }

    func updateNote(_ track: String, _ id: UUID, body: String, positionMs: Int?) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var arr = notesByTrack[track], let i = arr.firstIndex(where: { $0.id == id }) else { return }
        let old = arr[i]
        arr[i] = Note(id: old.id, positionMs: positionMs, author: old.author, body: trimmed, resolved: old.resolved, versionLabel: old.versionLabel)
        notesByTrack[track] = arr
        persist()
    }

    func deleteNote(_ track: String, _ id: UUID) {
        notesByTrack[track]?.removeAll { $0.id == id }
        persist()
    }

    // MARK: persistence (local; real API later)

    private func persist() {
        syncState = .saving
        let enc = JSONEncoder()
        if let d = try? enc.encode(notesByTrack) { UserDefaults.standard.set(d, forKey: notesKey) }
        if let d = try? enc.encode(currentByTrack) { UserDefaults.standard.set(d, forKey: currentKey) }
        if let d = try? enc.encode(titleOverrides) { UserDefaults.standard.set(d, forKey: titlesKey) }
        if let d = try? enc.encode(pins) { UserDefaults.standard.set(d, forKey: pinsKey) }
        let keep = localPlaylists.filter { !draftIDs.contains($0.id) }
        if let d = try? enc.encode(keep) { UserDefaults.standard.set(d, forKey: playlistsKey) }
        if let d = try? enc.encode(customRooms) { UserDefaults.standard.set(d, forKey: customRoomsKey) }
        if let d = try? enc.encode(customTracks) { UserDefaults.standard.set(d, forKey: customTracksKey) }
        if let d = try? enc.encode(inbox) { UserDefaults.standard.set(d, forKey: inboxKey) }
        if let d = try? enc.encode(activity) { UserDefaults.standard.set(d, forKey: activityKey) }
        lastSavedAt = Date()
        syncState = .ready
        syncMessage = "Saved locally"
    }

    private func loadPersisted() {
        let dec = JSONDecoder()
        if let d = UserDefaults.standard.data(forKey: notesKey),
           let v = try? dec.decode([String: [Note]].self, from: d) {
            notesByTrack = v
        }
        if let d = UserDefaults.standard.data(forKey: currentKey),
           let v = try? dec.decode([String: String].self, from: d) {
            currentByTrack = v
        }
        if let d = UserDefaults.standard.data(forKey: titlesKey),
           let v = try? dec.decode([String: String].self, from: d) {
            titleOverrides = v
        }
        if let d = UserDefaults.standard.data(forKey: pinsKey),
           let v = try? dec.decode([String].self, from: d) {
            pins = v
        }
        if let d = UserDefaults.standard.data(forKey: playlistsKey),
           let v = try? dec.decode([Playlist].self, from: d), !v.isEmpty {
            localPlaylists = v
        }
        if let d = UserDefaults.standard.data(forKey: customRoomsKey),
           let v = try? dec.decode([Room].self, from: d) {
            customRooms = v
        }
        if let d = UserDefaults.standard.data(forKey: customTracksKey),
           let v = try? dec.decode([StoredTrack].self, from: d) {
            customTracks = v
        }
        if let d = UserDefaults.standard.data(forKey: inboxKey),
           let v = try? dec.decode([InboxItem].self, from: d) {
            inbox = v
        }
        if let d = UserDefaults.standard.data(forKey: activityKey),
           let v = try? dec.decode([String: Date].self, from: d) {
            activity = v
        }
    }

    private func nextCatalog() -> String {
        String(format: "PB ·%04d", 300 + customTracks.count + 1)
    }

    private func addTrackToProject(trackID: String, project: String, artist: String) {
        if let i = customRooms.firstIndex(where: { $0.title.caseInsensitiveCompare(project) == .orderedSame }) {
            if !customRooms[i].trackIDs.contains(trackID) { customRooms[i].trackIDs.insert(trackID, at: 0) }
            return
        }
        if let sample = SampleData.rooms.first(where: { $0.title.caseInsensitiveCompare(project) == .orderedSame }) {
            var updated = sample
            if !updated.trackIDs.contains(trackID) { updated.trackIDs.insert(trackID, at: 0) }
            customRooms.insert(updated, at: 0)
            return
        }
        let room = Room(
            id: "rm-\(Self.slug(project))-\(UUID().uuidString.prefix(5))",
            title: project,
            artist: artist,
            trackIDs: [trackID]
        )
        customRooms.insert(room, at: 0)
    }

    private func deleteImportedFile(at path: String?) {
        guard let path else { return }
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(path)
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func importedFileURL(_ path: String) -> URL? {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(path)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func slug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return text.lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .reduce("") { partial, char in
                if char == "-", partial.last == "-" { return partial }
                return partial + String(char)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func palette(for index: Int) -> [UInt] {
        let palettes: [[UInt]] = [
            [0x4663E8, 0x6E86EC, 0xEDB29B, 0x35499E, 0xC2566F, 0xF0A85A, 0x1F2C6E, 0xB13F72, 0xE8C87A],
            [0x5FD08A, 0xAFDBC3, 0xBAC3EC, 0x2E7A57, 0x4663E8, 0xE0A22E, 0x1D4F3A, 0x6E86EC, 0xEDB29B],
            [0xB1417E, 0xD0466A, 0xF07A6A, 0x6E4BD6, 0xE14B6A, 0xF0A85A, 0x3A2C7A, 0xB13F72, 0xE8B84A],
        ]
        return palettes[index % palettes.count]
    }

    private static func normalizedPalette(_ palette: [UInt]?) -> [UInt]? {
        guard let palette, !palette.isEmpty else { return nil }
        if palette.count == 9 { return palette }
        if palette.count > 9 { return Array(palette.prefix(9)) }
        return palette + Array(repeating: palette.last ?? 0x16110C, count: 9 - palette.count)
    }

    private func seed() {
        versionsByTrack = [
            "first-night": [
                Version(id: "fn1", label: "Rough v1", loudness: "−7.9 LUFS"),
                Version(id: "fn2", label: "Mix v2", loudness: "−8.4 LUFS", approved: true),
                Version(id: "fn3", label: "Mix v3", loudness: "−9.2 LUFS"),
            ],
            "lighting-the-fuse": [
                Version(id: "lf1", label: "Demo v1", loudness: "−8.1 LUFS"),
                Version(id: "lf2", label: "Mix v3", loudness: "−9.0 LUFS"),
            ],
            "duel": [
                Version(id: "du1", label: "Rough v1", loudness: "−7.5 LUFS"),
                Version(id: "du2", label: "Clean v3", loudness: "−12.7 LUFS"),
            ],
            "best-of-me": [
                Version(id: "bm1", label: "Mix v1", loudness: "−8.8 LUFS"),
                Version(id: "bm2", label: "Mix v2", loudness: "−9.4 LUFS"),
            ],
        ]
        currentByTrack = ["first-night": "fn3", "lighting-the-fuse": "lf2", "duel": "du2", "best-of-me": "bm2"]
        notesByTrack = [
            "first-night": [
                Note(id: UUID(), positionMs: 48_000, author: "Liz Rose", body: "The pre-chorus lift still feels early — give it one more bar before the drop.", resolved: false, versionLabel: "Mix v3"),
                Note(id: UUID(), positionMs: 92_000, author: "TB", body: "Vocal sits a touch hot in the second chorus — pull it 1 dB and we’re there.", resolved: false, versionLabel: "Mix v3"),
                Note(id: UUID(), positionMs: 130_000, author: "TB", body: "Snare was clipping into the bridge — fixed.", resolved: true, versionLabel: "Mix v3"),
            ],
            "duel": [
                Note(id: UUID(), positionMs: 64_000, author: "Mira Tan", body: "Love the clean master direction. Ship-adjacent.", resolved: false, versionLabel: "Clean v3"),
            ],
        ]
    }
}
