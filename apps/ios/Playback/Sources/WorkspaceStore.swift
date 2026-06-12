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

/// One row of Home's "On your desk" list: what surfaced and why.
struct DeskEntry: Identifiable {
    let ref: PinRef
    let score: Double
    /// Live reason ("3 open notes", "Shared by Maya") — nil means the row
    /// falls back to its static subtitle.
    let reason: String?
    var id: String { ref.id }
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
    /// Persistent FIFO upload queue — the only path into the library for
    /// imported audio. Engine lives in UploadQueue.swift.
    var uploadJobs: [UploadJob] = []
    /// jobID → 0…1, runtime-only; fed by the upload task delegate.
    var uploadProgressByJob: [String: Double] = [:]
    @ObservationIgnored var uploadWorker: Task<Void, Never>?
    @ObservationIgnored var isUploadTransferInFlight = false
    @ObservationIgnored var networkObserver: NetworkRegainObserver?
    var serviceTracks: [Track] = []
    var serviceRooms: [Room] = []
    var servicePlaylists: [Playlist] = []
    var servicePlaylistItemIDs: [String: [String: String]] = [:]
    var savedViews: [SavedViewSummary] = []
    var inbox: [InboxItem] = SampleData.inbox
    var accessRequests: [AccessRequest] = []          // pending only, newest first
    var activity: [String: Date] = [:]                // ref id → last opened
    var deletedTrackIDs: Set<String> = []
    var syncState: WorkspaceSyncState = .ready
    var syncMessage: String = "Local library"
    var lastSavedAt: Date?
    var isLibraryLoaded: Bool = false
    @ObservationIgnored private var draftIDs: Set<String> = []
    @ObservationIgnored private var pendingRemoteDeletedIDs: Set<String> = []
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var pinsPushTask: Task<Void, Never>?
    @ObservationIgnored private var pinsNeedPush = false

    func touch(_ ref: String) { activity[Self.canonicalPinID(ref)] = Date(); persist() }

    /// Taggable workspace members — populated from API; falls back to an empty list.
    var members: [String] = []

    private let notesKey = "wl.notes.v1"
    private let currentKey = "wl.current.v1"
    private let titlesKey = "wl.titles.v1"
    private let pinsKey = "wl.pins.v1"
    private let pinsMigratedKey = "wl.pins.migrated.v1"
    private let playlistsKey = "wl.playlists.v1"
    private let customRoomsKey = "wl.customRooms.v1"
    private let customTracksKey = "wl.customTracks.v1"
    let uploadJobsKey = "wl.uploadJobs.v1"
    private let inboxKey = "wl.inbox.v1"
    private let activityKey = "wl.activity.v1"
    private let deletedTracksKey = "wl.deletedTracks.v1"

    // MARK: tracks

    var isUsingServiceLibrary: Bool { !serviceTracks.isEmpty || syncState == .synced }
    var tracks: [Track] {
        let base = isUsingServiceLibrary ? customTracks.map(\.track) + serviceTracks : customTracks.map(\.track) + SampleData.tracks
        return (pendingUploadTracks + base).filter { !deletedTrackIDs.contains($0.id) }
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
        guard !deletedTrackIDs.contains(id) else { return nil }
        return customTracks.first { $0.id == id }?.track
            ?? uploadJob(forTrack: id)?.track
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
            async let inboxItems = ServiceClient.shared.inbox()
            async let membersList = ServiceClient.shared.members()
            async let requests = ServiceClient.shared.accessRequests()

            let libraryItems = try await library
            let playlistSummaries = try await playlists
            let savedViewItems = (try? await views) ?? []
            let fetchedInbox = (try? await inboxItems) ?? []
            let fetchedMembers = (try? await membersList) ?? []
            let fetchedRequests = (try? await requests) ?? []

            var details: [ServiceClient.APIPlaylistDetail] = []
            for playlist in playlistSummaries {
                if let detail = try? await ServiceClient.shared.playlist(playlist.playlist_id) {
                    details.append(detail)
                }
            }

            adoptService(library: libraryItems, playlistDetails: details, savedViews: savedViewItems)
            adoptInbox(fetchedInbox)
            adoptAccessRequests(fetchedRequests)
            members = fetchedMembers.map(\.display_name).filter { !$0.isEmpty }
            await syncPinsWithServer()
            lastSavedAt = Date()
            syncState = .synced
            syncMessage = "Synced with cloud"
            isLibraryLoaded = true
        } catch {
            syncState = isUsingServiceLibrary ? .offline : .ready
            syncMessage = "Cloud sync unavailable"
            isLibraryLoaded = true  // stop spinner even on failure
        }
    }

    @MainActor
    func refreshNotes(for trackID: String) async {
        guard Config.useRemoteAPI, !isCustomTrack(trackID) else { return }
        guard let apiNotes = try? await ServiceClient.shared.notes(songID: trackID) else { return }
        let mapped = apiNotes.map { n -> Note in
            Note(
                id: UUID(),
                apiID: n.note_id,
                positionMs: n.timestamp_start_ms,
                author: n.author_display_name ?? n.author_guest_label ?? "Guest",
                body: n.body,
                resolved: n.status == "resolved",
                versionLabel: n.anchor_version_label ?? "—"
            )
        }
        // Keep notes that were composed locally and haven't synced yet (no apiID).
        let localOnly = (notesByTrack[trackID] ?? []).filter { $0.apiID == nil }
        notesByTrack[trackID] = localOnly + mapped
    }

    private func adoptInbox(_ items: [ServiceClient.APIInboxItem]) {
        // Preserve any "heard" state the user set locally.
        let heardIDs = Set(inbox.filter { !$0.isNew }.map(\.id))
        inbox = items.compactMap { item in
            InboxItem(
                id: item.song.song_id,
                trackID: item.song.song_id,
                sharedBy: item.shared_by,
                context: item.room?.title ?? "Workspace",
                isNew: heardIDs.contains(item.song.song_id) ? false : item.new_since_last_listen
            )
        }
    }

    private static let accessRequestDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let accessRequestPlainDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func adoptAccessRequests(_ items: [ServiceClient.APIAccessRequest]) {
        // Server returns pending-only, newest first — filter defensively anyway.
        accessRequests = items.filter { $0.status == "pending" }.map { item in
            AccessRequest(
                id: item.request_id,
                name: item.name,
                email: item.email,
                sourceSongTitle: item.source_song_title,
                createdAt: Self.accessRequestDateFormatter.date(from: item.created_at)
                    ?? Self.accessRequestPlainDateFormatter.date(from: item.created_at)
            )
        }
    }

    @MainActor
    private func refreshPlaylists() async {
        guard Config.useRemoteAPI else { return }
        do {
            let summaries = try await ServiceClient.shared.playlists()
            var details: [ServiceClient.APIPlaylistDetail] = []
            for playlist in summaries {
                if let detail = try? await ServiceClient.shared.playlist(playlist.playlist_id) {
                    details.append(detail)
                }
            }
            // Adopt playlists only — leave library, rooms, and members intact.
            var itemIDsByPlaylist: [String: [String: String]] = [:]
            servicePlaylists = details.map { detail in
                let entries = detail.items.sorted { $0.item.position < $1.item.position }
                itemIDsByPlaylist[detail.playlist.playlist_id] = Dictionary(
                    uniqueKeysWithValues: entries.compactMap { entry in
                        guard let songID = entry.song?.song_id ?? entry.current_version?.song_id else { return nil }
                        guard !deletedTrackIDs.contains(songID) else { return nil }
                        return (songID, entry.item.playlist_item_id)
                    })
                return Playlist(
                    id: detail.playlist.playlist_id,
                    title: detail.playlist.title,
                    subtitle: detail.playlist.description ?? "",
                    trackIDs: entries.compactMap { entry in
                        guard let songID = entry.song?.song_id ?? entry.current_version?.song_id else { return nil }
                        return deletedTrackIDs.contains(songID) ? nil : songID
                    }
                )
            }
            servicePlaylistItemIDs = itemIDsByPlaylist
        } catch {}
    }

    /// Import = enqueue, never fork. The optimistic pending row is visible
    /// instantly and the persistent queue owns the upload (backoff retries,
    /// survival across kills — see UploadQueue.swift). The old failure
    /// fallback that minted a normal-looking device-local track is gone: a
    /// song that exists in the UI exists in the cloud, or is visibly
    /// mid-upload.
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
              importedFileURL(importedAudioPath) != nil
        else {
            // Demo / sample-library mode only (no remote API): a plain local
            // track IS the library here, not a fork of it.
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

        return enqueueUpload(
            title: title,
            artist: artist,
            project: project,
            versionLabel: versionLabel,
            durationMs: durationMs,
            audioPath: importedAudioPath,
            sourceFileName: sourceFileName,
            artworkPath: importedArtworkPath,
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
        let serviceIDs = Set(library.map { $0.song.song_id })
        let staleLocalDeletes = deletedTrackIDs.intersection(serviceIDs).subtracting(pendingRemoteDeletedIDs)
        if !staleLocalDeletes.isEmpty {
            deletedTrackIDs.subtract(staleLocalDeletes)
        }

        let tracks = library
            .map { item in serviceTrack(from: item) }
            .filter { !deletedTrackIDs.contains($0.id) }
        serviceTracks = tracks

        var grouped: [String: (title: String, artist: String, ids: [String])] = [:]
        for item in library {
            guard !deletedTrackIDs.contains(item.song.song_id) else { continue }
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
                guard !deletedTrackIDs.contains(songID) else { return nil }
                return (songID, entry.item.playlist_item_id)
            })
            return Playlist(
                id: detail.playlist.playlist_id,
                title: detail.playlist.title,
                subtitle: detail.playlist.description ?? "",
                trackIDs: entries.compactMap { entry in
                    guard let songID = entry.song?.song_id ?? entry.current_version?.song_id else { return nil }
                    return deletedTrackIDs.contains(songID) ? nil : songID
                }
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
        // Stable per-song palette — `hashValue` is reseeded every launch,
        // which made fallback covers reshuffle between runs.
        let colors = MeshPalette.hexes(for: song.song_id)
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
        if raw.hasPrefix("/seed-audio/") {
            // Seed/demo audio is published by the web app's static site, not
            // the API — resolving against the API base 404s and stalls
            // every demo track.
            return Config.appURL + raw
        }
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

    /// Honest sync state: this track's id has never been seen by the cloud,
    /// so share links can never resolve it. True for pending uploads (the
    /// queue is still working) and for legacy device-local tracks.
    func isLocalOnlyTrack(_ id: String) -> Bool {
        Config.useRemoteAPI && (isCustomTrack(id) || isPendingUpload(id))
    }

    /// The import keeps the source audio in Documents (`importedAudioPath`),
    /// so the upload can be re-run — unless the file is gone, in which case
    /// re-upload is impossible and the UI must say so instead.
    func canRetryUpload(_ id: String) -> Bool {
        guard isLocalOnlyTrack(id),
              let stored = customTracks.first(where: { $0.id == id }),
              let path = stored.importedAudioPath
        else { return false }
        return importedFileURL(path) != nil
    }

    /// Manual retry — queue-backed now. Pending rows kick the worker
    /// immediately (skipping any backoff); a legacy local-only track with a
    /// retained file self-heals by enqueueing under its existing id, so the
    /// same adoption/remapping runs on success. Returns true when the
    /// upload was handed to the queue.
    @MainActor
    @discardableResult
    func retryUpload(_ id: String) async -> Bool {
        if isPendingUpload(id) {
            retryUploadNow(id)
            return true
        }
        guard Config.useRemoteAPI,
              let stored = customTracks.first(where: { $0.id == id }),
              let path = stored.importedAudioPath,
              importedFileURL(path) != nil
        else { return false }
        _ = enqueueUpload(
            title: stored.title,
            artist: stored.artist,
            project: stored.label,
            versionLabel: stored.versionLabel,
            durationMs: stored.durationMs,
            audioPath: path,
            sourceFileName: stored.sourceFileName,
            artworkPath: stored.importedArtworkPath,
            artworkPalette: stored.meshHexes,
            localTrackID: stored.id
        )
        return true
    }

    /// Swap a local-only track for its cloud identity after a successful
    /// upload: remap playlist/room/pin/note references and drop the local
    /// copy so the service track is the single identity going forward.
    func adoptUploadedTrack(localID: String, cloudID: String) {
        customTracks.removeAll { $0.id == localID }
        for i in localPlaylists.indices {
            localPlaylists[i].trackIDs = localPlaylists[i].trackIDs.map { $0 == localID ? cloudID : $0 }
        }
        for i in customRooms.indices {
            customRooms[i].trackIDs = customRooms[i].trackIDs.map { $0 == localID ? cloudID : $0 }
        }
        var pinsChanged = false
        pins = pins.map { ref in
            guard let pin = PinRef(ref), pin.kind == .song, pin.targetID == localID else { return ref }
            pinsChanged = true
            return PinRef(kind: .song, targetID: cloudID).id
        }
        if let notes = notesByTrack.removeValue(forKey: localID) {
            notesByTrack[cloudID] = (notesByTrack[cloudID] ?? []) + notes
        }
        if let title = titleOverrides.removeValue(forKey: localID) { titleOverrides[cloudID] = title }
        versionsByTrack[localID] = nil
        currentByTrack[localID] = nil
        if let date = activity.removeValue(forKey: PinRef(kind: .song, targetID: localID).id) {
            activity[PinRef(kind: .song, targetID: cloudID).id] = date
        }
        persist()
        if pinsChanged { schedulePinsPush() }
    }

    func isEditableTrack(_ id: String) -> Bool {
        isCustomTrack(id) || serviceTracks.contains { $0.id == id }
    }

    @discardableResult
    func deleteTrack(_ id: String) -> Bool {
        let wasCustom = customTracks.firstIndex(where: { $0.id == id })
        let wasService = serviceTracks.contains { $0.id == id }
        let wasSample = SampleData.track(id) != nil
        let wasPending = isPendingUpload(id)
        let wasVisible = tracks.contains { $0.id == id }
        guard wasCustom != nil || wasService || wasSample || wasPending || wasVisible else { return false }

        // Deleting a pending row drops its upload job too; if a transfer is
        // mid-flight the worker honors the delete on completion.
        let removedJob = removeUploadJob(forTrack: id)
        let removed = wasCustom.map { customTracks.remove(at: $0) }
        deletedTrackIDs.insert(id)
        serviceTracks.removeAll { $0.id == id }
        localPlaylists.indices.forEach { localPlaylists[$0].trackIDs.removeAll { $0 == id } }
        servicePlaylists.indices.forEach { servicePlaylists[$0].trackIDs.removeAll { $0 == id } }
        customRooms.indices.forEach { customRooms[$0].trackIDs.removeAll { $0 == id } }
        serviceRooms.indices.forEach { serviceRooms[$0].trackIDs.removeAll { $0 == id } }
        Array(servicePlaylistItemIDs.keys).forEach { key in
            servicePlaylistItemIDs[key]?[id] = nil
        }
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
        if let removed {
            deleteImportedFile(at: removed.importedAudioPath)
            deleteImportedFile(at: removed.importedArtworkPath)
        } else if let removedJob {
            deleteImportedFile(at: removedJob.audioPath)
            deleteImportedFile(at: removedJob.artworkPath)
        }
        persist()
        if wasService {
            syncDeletedTrack(id)
        }
        return true
    }

    // MARK: pins

    private static func canonicalPinID(_ ref: String) -> String {
        PinRef(ref)?.id ?? ref
    }

    private static func normalizedPins(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let canonical = canonicalPinID(value)
            guard seen.insert(canonical).inserted else { continue }
            result.append(canonical)
        }
        return result
    }

    func isPinned(_ ref: String) -> Bool {
        let canonical = Self.canonicalPinID(ref)
        return pins.contains { Self.canonicalPinID($0) == canonical }
    }

    func togglePin(_ ref: String) {
        let canonical = Self.canonicalPinID(ref)
        if let i = pins.firstIndex(where: { Self.canonicalPinID($0) == canonical }) {
            pins.remove(at: i)
        } else {
            pins.append(canonical)
        }
        pins = Self.normalizedPins(pins)
        persist()
        schedulePinsPush()
    }

    func movePin(from: IndexSet, to: Int) {
        pins = Self.normalizedPins(pins)
        pins.move(fromOffsets: from, toOffset: to)
        persist()
        schedulePinsPush()
    }

    /// Server pins sync — server wins on refresh; UserDefaults stays as the
    /// offline cache. Local edits debounce-push ~1s after the last change;
    /// a failed push is retried on the next refreshFromService.
    @MainActor
    private func syncPinsWithServer() async {
        guard Config.useRemoteAPI else { return }
        if pinsNeedPush {
            // A debounced push failed (or hasn't fired yet) — replay it
            // before adopting server state so the local edit isn't lost.
            pinsPushTask?.cancel()
            await pushPinsNow()
        }
        guard let serverPins = try? await ServiceClient.shared.getPins() else { return }
        let normalized = Self.normalizedPins(serverPins)
        if normalized.isEmpty, !pins.isEmpty, !UserDefaults.standard.bool(forKey: pinsMigratedKey) {
            // Migration: this device has pins the server has never seen.
            if await pushPinsNow(force: true) {
                UserDefaults.standard.set(true, forKey: pinsMigratedKey)
            }
            return
        }
        UserDefaults.standard.set(true, forKey: pinsMigratedKey)
        // Local edits queued mid-flight win until their push lands.
        guard !pinsNeedPush else { return }
        if pins != normalized {
            pins = normalized
            persist()
        }
    }

    private func schedulePinsPush() {
        guard Config.useRemoteAPI else { return }
        pinsNeedPush = true
        pinsPushTask?.cancel()
        pinsPushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.pushPinsNow()
        }
    }

    @MainActor
    @discardableResult
    private func pushPinsNow(force: Bool = false) async -> Bool {
        guard Config.useRemoteAPI, pinsNeedPush || force else { return false }
        let snapshot = Self.normalizedPins(pins)
        do {
            _ = try await ServiceClient.shared.putPins(snapshot)
            if Self.normalizedPins(pins) == snapshot { pinsNeedPush = false }
            return true
        } catch {
            pinsNeedPush = true  // retried on the next refreshFromService
            return false
        }
    }

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
                await refreshPlaylists()
                await MainActor.run { self.syncState = .synced; self.syncMessage = "Synced with cloud" }
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
                await refreshPlaylists()
                await MainActor.run { self.syncState = .synced; self.syncMessage = "Synced with cloud" }
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
                await refreshPlaylists()
                await MainActor.run { self.syncState = .synced; self.syncMessage = "Synced with cloud" }
            } catch {
                await MainActor.run {
                    self.syncState = .offline
                    self.syncMessage = "Playlist change saved locally"
                }
            }
        }
    }

    private func syncDeletedTrack(_ trackID: String) {
        guard Config.useRemoteAPI else { return }
        pendingRemoteDeletedIDs.insert(trackID)
        syncState = .syncing
        syncMessage = "Deleting song"
        Task {
            do {
                try await ServiceClient.shared.deleteSong(trackID)
                await MainActor.run {
                    self.pendingRemoteDeletedIDs.remove(trackID)
                    self.syncState = .synced
                    self.syncMessage = "Synced with cloud"
                }
            } catch {
                await MainActor.run {
                    self.pendingRemoteDeletedIDs.remove(trackID)
                    self.syncState = .offline
                    self.syncMessage = "Delete saved locally"
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
                await refreshPlaylists()
                await MainActor.run { self.syncState = .synced; self.syncMessage = "Synced with cloud" }
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

    var inboxNewCount: Int { inbox.filter(\.isNew).count + accessRequests.count }

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

    // MARK: access requests

    /// Approves a pending access request and returns the invite whose URL
    /// the caller copies to the pasteboard. On failure (e.g. 503 when
    /// invites need Supabase) the request stays pending server-side and in
    /// `accessRequests`, so the row can retry.
    @MainActor
    func approveAccessRequest(_ id: String) async throws -> ServiceClient.APIAccessInvite {
        let resolved = try await ServiceClient.shared.resolveAccessRequest(requestID: id, action: "approve")
        guard let invite = resolved.invite else { throw ServiceError.emptyResponse }
        accessRequests.removeAll { $0.id == id }
        return invite
    }

    @MainActor
    func dismissAccessRequest(_ id: String) async throws {
        _ = try await ServiceClient.shared.resolveAccessRequest(requestID: id, action: "dismiss")
        accessRequests.removeAll { $0.id == id }
    }

    // MARK: attention ("On your desk")

    /// Scored attention list backing Home's "On your desk" section.
    /// score = 3 × pending signal (new inbox share / open notes)
    ///       + 2 × recency of user touch (7-day linear decay)
    ///       + 1 × play frequency — approximated by the same recency until a
    ///         real play history exists. // TODO: true 7-day play frequency.
    func deskEntries(limit: Int = 6, excluding excludedRefIDs: Set<String> = []) -> [DeskEntry] {
        let now = Date()
        func recency(_ refID: String) -> Double {
            guard let date = activity[refID] else { return 0 }
            let days = now.timeIntervalSince(date) / 86_400
            return max(0, 1 - days / 7)
        }
        func noteReason(_ count: Int) -> String {
            "\(count) open \(count == 1 ? "note" : "notes")"
        }

        var entries: [DeskEntry] = []

        for track in tracks {
            let ref = PinRef(kind: .song, targetID: track.id)
            guard !excludedRefIDs.contains(ref.id) else { continue }
            var score = 0.0
            var reason: String?
            let openNotes = openCount(track.id)
            if openNotes > 0 {
                score += 3
                reason = noteReason(openNotes)
            }
            if let share = inbox.first(where: { $0.trackID == track.id && $0.isNew }) {
                score += 3
                if reason == nil { reason = "Shared by \(share.sharedBy)" }
            }
            // TODO: "Left off at m:ss" reason + score once per-track last
            // playback positions are persisted (none exist in the store yet).
            let touch = recency(ref.id)
            score += 2 * touch
            score += 1 * touch  // play-frequency stand-in, see header comment
            if score > 0 { entries.append(DeskEntry(ref: ref, score: score, reason: reason)) }
        }

        for playlist in playlists {
            let ref = PinRef(kind: .playlist, targetID: playlist.id)
            guard !excludedRefIDs.contains(ref.id) else { continue }
            var score = 0.0
            var reason: String?
            let openNotes = playlist.trackIDs.reduce(0) { $0 + openCount($1) }
            if openNotes > 0 {
                score += 3
                reason = noteReason(openNotes)
            }
            let unheard = playlist.trackIDs.filter { id in inbox.contains { $0.trackID == id && $0.isNew } }.count
            if unheard > 0, !playlist.trackIDs.isEmpty {
                score += 3
                if reason == nil {
                    reason = "\(playlist.trackIDs.count - unheard) of \(playlist.trackIDs.count) heard"
                }
            }
            let touch = recency(ref.id)
            score += 3 * touch
            if score > 0 { entries.append(DeskEntry(ref: ref, score: score, reason: reason)) }
        }

        for room in rooms {
            let ref = PinRef(kind: .room, targetID: room.id)
            guard !excludedRefIDs.contains(ref.id) else { continue }
            var score = 0.0
            var reason: String?
            let openNotes = room.trackIDs.reduce(0) { $0 + openCount($1) }
            if openNotes > 0 {
                score += 3
                reason = noteReason(openNotes)
            }
            let touch = recency(ref.id)
            score += 3 * touch
            if score > 0 { entries.append(DeskEntry(ref: ref, score: score, reason: reason)) }
        }

        return Array(entries.sorted { $0.score > $1.score }.prefix(limit))
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
        let note = Note(id: UUID(), positionMs: positionMs, author: "You", body: trimmed, resolved: false, versionLabel: v)
        notesByTrack[track, default: []].append(note)
        persist()

        guard Config.useRemoteAPI,
              let versionID = remoteVersionID(for: track) else { return }
        let noteLocalID = note.id
        Task { @MainActor in
            guard let api = try? await ServiceClient.shared.createNote(
                songID: track, versionID: versionID, body: trimmed, positionMs: positionMs
            ) else { return }
            if var arr = notesByTrack[track], let i = arr.firstIndex(where: { $0.id == noteLocalID }) {
                arr[i].apiID = api.note_id
                notesByTrack[track] = arr
            }
        }
    }

    func toggleResolved(_ track: String, _ id: UUID) {
        guard var arr = notesByTrack[track], let i = arr.firstIndex(where: { $0.id == id }) else { return }
        arr[i].resolved.toggle()
        let newStatus = arr[i].resolved ? "resolved" : "open"
        let apiID = arr[i].apiID
        notesByTrack[track] = arr
        persist()

        if Config.useRemoteAPI, let apiID {
            Task { try? await ServiceClient.shared.patchNote(noteID: apiID, status: newStatus, body: nil) }
        }
    }

    func updateNote(_ track: String, _ id: UUID, body: String, positionMs: Int?) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var arr = notesByTrack[track], let i = arr.firstIndex(where: { $0.id == id }) else { return }
        let old = arr[i]
        arr[i] = Note(id: old.id, apiID: old.apiID, positionMs: positionMs,
                      author: old.author, body: trimmed, resolved: old.resolved, versionLabel: old.versionLabel)
        notesByTrack[track] = arr
        persist()

        if Config.useRemoteAPI, let apiID = old.apiID {
            Task { try? await ServiceClient.shared.patchNote(noteID: apiID, status: nil, body: trimmed) }
        }
    }

    func deleteNote(_ track: String, _ id: UUID) {
        notesByTrack[track]?.removeAll { $0.id == id }
        persist()
        // No DELETE /notes endpoint — local removal only for now.
    }

    private func remoteVersionID(for trackID: String) -> String? {
        serviceTracks.first(where: { $0.id == trackID })?.remoteVersionID
    }

    // MARK: persistence (local; real API later)

    private func persist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.executePersist()
        }
    }

    private func executePersist() {
        // Honest state: a sticky .offline/.error notice ("Upload failed —
        // saved on this device only") must survive the routine local-save
        // flicker — don't let the debounce overwrite it with "Saved locally".
        let preserveNotice = syncState == .offline || syncState == .error
        if !preserveNotice { syncState = .saving }
        pins = Self.normalizedPins(pins)
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
        if let d = try? enc.encode(deletedTrackIDs) { UserDefaults.standard.set(d, forKey: deletedTracksKey) }
        lastSavedAt = Date()
        if !preserveNotice {
            syncState = .ready
            syncMessage = "Saved locally"
        }
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
            pins = Self.normalizedPins(v)
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
        if let d = UserDefaults.standard.data(forKey: deletedTracksKey),
           let v = try? dec.decode(Set<String>.self, from: d) {
            deletedTrackIDs = v
        }
        loadUploadJobs()
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

    func deleteImportedFile(at path: String?) {
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

    func importedFileURL(_ path: String) -> URL? {
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

    static func normalizedPalette(_ palette: [UInt]?) -> [UInt]? {
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

extension WorkspaceStore {
    var artistSummaries: [ArtistSummary] {
        var buckets: [String: (name: String, trackIDs: [String], projectIDs: [String])] = [:]

        for track in tracks {
            let name = Self.normalizedArtistName(track.artist)
            guard !name.isEmpty else { continue }
            let key = Self.artistLookupKey(name)
            var bucket = buckets[key] ?? (name: name, trackIDs: [], projectIDs: [])
            if !bucket.trackIDs.contains(track.id) {
                bucket.trackIDs.append(track.id)
            }
            buckets[key] = bucket
        }

        for room in rooms {
            let name = Self.normalizedArtistName(room.artist)
            guard !name.isEmpty else { continue }
            let key = Self.artistLookupKey(name)
            var bucket = buckets[key] ?? (name: name, trackIDs: [], projectIDs: [])
            if !bucket.projectIDs.contains(room.id) {
                bucket.projectIDs.append(room.id)
            }
            buckets[key] = bucket
        }

        return buckets.map { key, value in
            ArtistSummary(id: key, name: value.name, trackIDs: value.trackIDs, projectIDs: value.projectIDs)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func artistTracks(_ artist: ArtistSummary) -> [Track] {
        artist.trackIDs.compactMap { track($0) }
    }

    func artistProjects(_ artist: ArtistSummary) -> [Room] {
        artist.projectIDs.compactMap { id in rooms.first { $0.id == id } }
    }

    /// Tracks in a room that still resolve in the library — the single source
    /// of truth for project song counts. `room.trackIDs` can carry stale ids
    /// (deleted songs, static sample rooms), which made project counts drift
    /// from the artist counts computed from `tracks`.
    func roomTracks(_ room: Room) -> [Track] {
        room.trackIDs.compactMap { track($0) }
    }

    static func normalizedArtistName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return artistLookupKey(trimmed) == artistLookupKey("Unknown Artist") ? "" : trimmed
    }

    static func artistLookupKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
