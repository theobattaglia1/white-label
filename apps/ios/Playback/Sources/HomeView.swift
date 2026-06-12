import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private enum HomeCreationSheet: Identifiable {
    case song, playlist, project

    var id: String {
        switch self {
        case .song: return "song"
        case .playlist: return "playlist"
        case .project: return "project"
        }
    }
}

/// Home — what to play, and what needs your ear.
struct HomeView: View {
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void
    var openQueue: (String, [Track]) -> Void = { _, _ in }
    var openLibrary: () -> Void = {}
    @State private var creationSheet: HomeCreationSheet?
    @State private var bulkMode: BulkSelectionMode?
    @State private var selectedTrackIDs: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var homeNotice: String?
    @State private var selectionDragTargets: [SelectionDragTarget] = []
    @State private var springboardPlaylist: Playlist?
    @State private var shelfPlaylist: Playlist?
    @State private var shelfRoom: Room?

    private let maxDeskCount = 6
    private var featured: Track { store.tracks.first ?? player.track }
    private var isLibraryEmpty: Bool {
        store.tracks.isEmpty && store.playlists.isEmpty && store.rooms.isEmpty
    }
    private var needsEar: [Track] { store.tracks.filter { store.openCount($0.id) > 0 } }
    /// THE SHELF's slot list — up to 10 pins (user order), then recents
    /// newest-first, capped at 15. Pure logic lives in ShelfSlots.swift.
    private var shelfSlots: [ShelfItem] {
        ShelfSlots.build(
            pins: ShelfSlots.resolvePins(
                refs: store.pins,
                tracks: store.tracks,
                playlists: store.playlists,
                rooms: store.rooms,
                titleOverrides: store.titleOverrides
            ),
            recents: ShelfSlots.recents(
                tracks: store.tracks,
                playlists: store.playlists,
                activity: store.activity,
                titleOverrides: store.titleOverrides
            )
        )
    }
    /// Scored attention list, deduped against the shelf and topped up
    /// with plain recency so Home is never empty. Capped at `maxDeskCount`.
    private var deskItems: [DeskEntry] {
        let excluded = Set(shelfSlots.map(\.id))
        var items = store.deskEntries(limit: maxDeskCount, excluding: excluded)
        if items.count < maxDeskCount {
            let seen = Set(items.map(\.id))
            for ref in recents where !seen.contains(ref.id) && !excluded.contains(ref.id) {
                items.append(DeskEntry(ref: ref, score: 0, reason: nil))
                if items.count == maxDeskCount { break }
            }
        }
        return items
    }
    private var selectedTracks: [Track] {
        store.tracks.filter { selectedTrackIDs.contains($0.id) }
    }
    private func beginSelection(with id: String, mode: BulkSelectionMode) {
        bulkMode = mode
        selectedTrackIDs.insert(id)
    }

    private func toggleSelection(_ id: String) {
        if bulkMode == nil { bulkMode = .selecting }
        if selectedTrackIDs.contains(id) {
            selectedTrackIDs.remove(id)
            if selectedTrackIDs.isEmpty { bulkMode = .selecting }
        } else {
            selectedTrackIDs.insert(id)
        }
    }

    private func clearSelection() {
        selectedTrackIDs.removeAll()
        bulkMode = nil
    }

    private func selectDuringDrag(_ id: String) {
        if bulkMode == nil { bulkMode = .selecting }
        selectedTrackIDs.insert(id)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                scrollToTopMarker()
                VStack(alignment: .leading, spacing: 30) {
                    homeHeader

                    if let homeNotice {
                        MonoLabel(homeNotice, color: PB.green, size: 9, tracking: 1.2)
                            .transition(.opacity)
                    }

                    if isLibraryEmpty && !store.isLibraryLoaded && Config.useRemoteAPI {
                        loadingPanel
                    } else if isLibraryEmpty {
                        startPanel
                    } else if !shelfSlots.isEmpty {
                        // THE SHELF — full-bleed band where the hero was.
                        ShelfView(items: shelfSlots, store: store, onOpen: openShelfItem)
                            .padding(.horizontal, -24)
                    }

                    if !needsEar.isEmpty {
                        section("Needs your attention") {
                            VStack(spacing: 0) {
                                ForEach(needsEar) { t in
                                    homeTrackItem(t, showOpen: true)
                                }
                            }
                        }
                    }

                    if !deskItems.isEmpty {
                        section("Recent") {
                            VStack(spacing: 0) {
                                ForEach(deskItems) { entry in
                                    deskRow(entry)
                                }

                                moreRecentsButton
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 150)
            }
            .scrollIndicators(.hidden)
            .background {
                PB.black.ignoresSafeArea()
                AmbientPlayerBackdrop(player: player)
                    .allowsHitTesting(false).ignoresSafeArea()
            }
            .overlay(alignment: .top) {
                TopTapScrollHotspot { scrollToTop(scrollProxy) }
            }
            .foregroundStyle(PB.cream)
            .toolbar(.hidden, for: .navigationBar)
            .onPreferenceChange(SelectionDragTargetKey.self) { targets in
                selectionDragTargets = targets
            }
            .twoFingerSelection(
                enabled: !store.tracks.isEmpty,
                targets: selectionDragTargets,
                onSelect: selectDuringDrag
            )
            .overlay(alignment: .bottom) {
                if let bulkMode, !selectedTrackIDs.isEmpty {
                    BulkSongActionBar(
                        count: selectedTrackIDs.count,
                        mode: bulkMode,
                        playlists: store.playlists,
                        rooms: store.rooms,
                        projectLabel: "Project",
                        canDelete: true,
                        removeLabel: nil,
                        onNewPlaylist: createPlaylistFromSelection,
                        onAddToPlaylist: addSelection(to:),
                        onMoveToProject: addSelection(to:),
                        onShare: shareSelection,
                        onDelete: { confirmBulkDelete = true },
                        onRemove: nil,
                        onClear: clearSelection
                    )
                    .padding(.horizontal, 18)
                    .padding(.bottom, 94)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: selectedTrackIDs)
            .confirmationDialog(
                "Delete selected songs?",
                isPresented: $confirmBulkDelete,
                titleVisibility: .visible
            ) {
                Button("Delete \(selectedTrackIDs.count) \(selectedTrackIDs.count == 1 ? "song" : "songs")", role: .destructive) {
                    deleteSelectedSongs()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the selected songs from your Playback library. Imported audio and artwork files on this device will be deleted.")
            }
            .sheet(item: $creationSheet) { sheet in
                switch sheet {
                case .song:
                    AddSongSheet(store: store, player: player)
                case .playlist:
                    NewPlaylistSheet(store: store, player: player) { _ in }
                case .project:
                    NewProjectSheet(store: store)
                }
            }
            .sheet(item: $springboardPlaylist) { pl in
                PlaylistDetailView(playlist: pl, player: player, store: store,
                                   openSong: openSong)
            }
            // Shelf step-3 destinations — the same detail screens the
            // NavigationLink rows push (see navDestinations in RootView).
            .navigationDestination(item: $shelfPlaylist) { pl in
                PlaylistDetailView(playlist: pl, player: player, store: store,
                                   openSong: openSong, openQueue: openQueue)
            }
            .navigationDestination(item: $shelfRoom) { rm in
                RoomDetailView(room: rm, player: player, store: store,
                               openSong: openSong, openQueue: openQueue)
            }
        }
    }

    /// Step 3 of the shelf's tap progression — open via the EXISTING Home
    /// behaviors: songs play and present Now Playing (RootView's openSong),
    /// playlists and projects push their detail screens.
    private func openShelfItem(_ item: ShelfItem) {
        switch item.ref.kind {
        case .song:
            openSong(item.ref.targetID)
        case .playlist:
            if let pl = store.playlist(item.ref.targetID) { shelfPlaylist = pl }
        case .room:
            if let rm = store.rooms.first(where: { $0.id == item.ref.targetID }) { shelfRoom = rm }
        }
    }

    private func handleSpringboardDrop(_ ids: [String]) {
        guard ids.count >= 2 else { return }
        let tracks = ids.compactMap { store.track($0) }
        let title = tracks.count == 2
            ? "\(tracks[0].title) + \(tracks[1].title)"
            : "\(tracks[0].title) + \(tracks.count - 1) more"
        let pl = store.createKeptPlaylist(title: title, trackIDs: ids)
        clearSelection()
        withAnimation(.easeInOut(duration: 0.18)) { springboardPlaylist = pl }
    }

    private var addMenu: some View {
        Menu {
            Button { creationSheet = .song } label: {
                Label("Song", systemImage: "music.note")
            }
            Button { creationSheet = .playlist } label: {
                Label("Playlist", systemImage: "text.badge.plus")
            }
            Button { creationSheet = .project } label: {
                Label("Project", systemImage: "folder.badge.plus")
            }
        } label: {
            HeaderCircleIcon(systemName: "plus")
        }
        .accessibilityLabel("Add")
    }

    private var homeHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            PlaybackWordmark(capSize: 22, fontSize: 24, isPlaying: player.isPlaying)
                .frame(width: 156, height: 26, alignment: .leading)
            if let num = PlaybackAuthSession.shared.profile?.user.member_number {
                MonoLabel(String(format: "PB · %03d", num), color: PB.pencil.opacity(0.55), size: 9, tracking: 1.8)
            }
            Spacer(minLength: 0)
            if !isLibraryEmpty {
                Button {
                    if bulkMode == nil {
                        bulkMode = .selecting
                    } else {
                        clearSelection()
                    }
                } label: {
                    HeaderCircleIcon(systemName: bulkMode == nil ? "checkmark.circle" : "xmark.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bulkMode == nil ? "Select songs" : "Done selecting")
            }
            addMenu
        }
        .frame(height: 44, alignment: .center)
    }

    private var loadingPanel: some View {
        HStack(spacing: 14) {
            ProgressView().tint(PB.pencil)
            MonoLabel("Loading library", color: PB.pencil, size: 10, tracking: 1.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PB.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
    }

    private var startPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start your library").font(PB.display(22)).foregroundStyle(PB.cream)
                    MonoLabel("Add music · shape a list · open a project", color: PB.pencil, size: 9, tracking: 1)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                startButton("music.note", "Song") { creationSheet = .song }
                startButton("text.badge.plus", "Playlist") { creationSheet = .playlist }
                startButton("folder.badge.plus", "Project") { creationSheet = .project }
            }
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PB.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
    }

    private func startButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                MonoLabel(label, color: PB.cream, size: 9, tracking: 1)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.black.opacity(0.36)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                MonoLabel(title, color: PB.pencil, size: 11, tracking: 2)
                Spacer()
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            }
            content()
        }
    }

    private func trackRow(_ t: Track, showOpen: Bool, subtitle: String? = nil) -> some View {
        HStack(spacing: 13) {
            swatch(t, 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayTitle(t.id, t.title)).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel(subtitle ?? "\(t.artist) · \(t.versionLabel)", color: PB.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            // Honest state: device-local song — dim cream, not an alert.
            if store.isLocalOnlyTrack(t.id) {
                MonoLabel("Not synced", color: PB.cream.opacity(0.45), size: 8, tracking: 1.4)
            }
            if showOpen, store.openCount(t.id) > 0 {
                MonoLabel("\(store.openCount(t.id)) open", color: PB.redline, size: 9, tracking: 1)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())
    }

    private func homeTrackItem(_ t: Track, showOpen: Bool, subtitle: String? = nil) -> some View {
        InteractiveSongItem(
            track: t,
            store: store,
            bulkMode: $bulkMode,
            selectedTrackIDs: $selectedTrackIDs,
            selectedTracks: selectedTracks,
            onOpen: { openSong(t.id) },
            onSpringboardDrop: handleSpringboardDrop
        ) {
            trackRow(t, showOpen: showOpen, subtitle: subtitle)
        } idleAccessory: {
            EmptyView()
        }
    }

    private func createPlaylistFromSelection() {
        let tracks = selectedTracks
        guard !tracks.isEmpty else { return }
        let playlist = store.createKeptPlaylist(
            title: tracks.count == 1 ? "\(tracks[0].title) List" : "Home Selection",
            trackIDs: tracks.map(\.id)
        )
        store.touch(PinRef(kind: .playlist, targetID: playlist.id).id)
        showHomeNotice("Playlist created")
        clearSelection()
    }

    private func addSelection(to playlist: Playlist) {
        selectedTracks.forEach { store.addTrack($0.id, toPlaylist: playlist.id) }
        store.touch(PinRef(kind: .playlist, targetID: playlist.id).id)
        showHomeNotice("Added to \(playlist.title)")
        clearSelection()
    }

    private func addSelection(to room: Room) {
        selectedTracks.forEach { store.addTrack($0.id, toProject: room.id) }
        store.touch(PinRef(kind: .room, targetID: room.id).id)
        showHomeNotice("Added to \(room.title)")
        clearSelection()
    }

    private func shareSelection() {
        guard copyShareLinks(selectedTracks, store: store) else { return }
        showHomeNotice(Config.useRemoteAPI ? "Titles copied" : "Share links copied")
        clearSelection()
    }

    private func deleteSelectedSongs() {
        let ids = selectedTrackIDs
        let deleted = ids.reduce(0) { count, id in
            count + (store.deleteTrack(id) ? 1 : 0)
        }
        if !store.tracks.isEmpty { player.replaceQueue(store.tracks) }
        showHomeNotice(deleted == 0 ? "Nothing deleted" : "Deleted \(deleted)")
        clearSelection()
    }

    private func showHomeNotice(_ message: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            homeNotice = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if homeNotice == message {
                withAnimation(.easeInOut(duration: 0.18)) {
                    homeNotice = nil
                }
            }
        }
    }

    private var moreRecentsButton: some View {
        Button {
            openLibrary()
        } label: {
            HStack(spacing: 8) {
                MonoLabel("More", color: PB.cobalt, size: 10, tracking: 1.6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PB.cobalt)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open library")
    }

    /// Songs, playlists, and projects ordered by recent activity (untouched
    /// items fall to a stable default order so Home is never empty).
    private var recents: [PinRef] {
        var entries: [(PinRef, Date)] = []
        for (i, track) in store.tracks.enumerated() {
            let ref = PinRef(kind: .song, targetID: track.id)
            entries.append((ref, store.activity[ref.id] ?? Date(timeIntervalSince1970: TimeInterval(800 - i))))
        }
        for (i, pl) in store.playlists.enumerated() {
            let ref = PinRef(kind: .playlist, targetID: pl.id)
            entries.append((ref, store.activity[ref.id] ?? Date(timeIntervalSince1970: TimeInterval(1000 - i))))
        }
        for (i, rm) in store.rooms.enumerated() {
            let ref = PinRef(kind: .room, targetID: rm.id)
            entries.append((ref, store.activity[ref.id] ?? Date(timeIntervalSince1970: TimeInterval(900 - i))))
        }
        return entries.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    @ViewBuilder private func deskRow(_ entry: DeskEntry) -> some View {
        if entry.ref.kind == .song, let track = store.track(entry.ref.targetID) {
            homeTrackItem(track, showOpen: false, subtitle: entry.reason)
        } else {
            recentNavigationRow(entry.ref, reason: entry.reason)
        }
    }

    @ViewBuilder private func recentNavigationRow(_ ref: PinRef, reason: String? = nil) -> some View {
        let cover = pinnedCover(ref, store) ?? featured
        let sub = reason ?? pinnedSubtitle(ref)
        let row = HStack(spacing: 13) {
            TrackArtwork(track: cover, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(pinnedTitle(ref, store)).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel(sub, color: PB.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(PB.pencil)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())

        Group {
            switch ref.kind {
            case .playlist:
                if let pl = store.playlist(ref.targetID) { NavigationLink(value: pl) { row }.buttonStyle(.plain) } else { row }
            case .room:
                if let rm = store.rooms.first(where: { $0.id == ref.targetID }) { NavigationLink(value: rm) { row }.buttonStyle(.plain) } else { row }
            case .song:
                Button { openSong(ref.targetID) } label: { row }.buttonStyle(.plain)
            }
        }
        .pinMenu(store, ref)
    }

    private func pinnedSubtitle(_ ref: PinRef) -> String {
        switch ref.kind {
        case .song:
            return "Song"
        case .playlist:
            let count = store.playlist(ref.targetID)?.trackIDs.count ?? 0
            return "Playlist · \(count) \(count == 1 ? "track" : "tracks")"
        case .room:
            let artist = store.rooms.first { $0.id == ref.targetID }?.artist ?? ""
            return artist.isEmpty ? "Project" : "Project · \(artist)"
        }
    }

    private func playlistCard(_ pl: Playlist) -> some View {
        let cover = pl.trackIDs.compactMap { store.track($0) }.first ?? featured
        return VStack(alignment: .leading, spacing: 9) {
            TrackArtwork(track: cover, cornerRadius: 12)
                .frame(width: 150, height: 150)
            Text(pl.title).font(PB.display(16)).foregroundStyle(PB.cream).lineLimit(1)
            MonoLabel("\(pl.trackIDs.count) tracks", color: PB.pencil, size: 9, tracking: 1.2)
        }
        .frame(width: 150)
    }

    private func roomRow(_ rm: Room) -> some View {
        let tracks = store.roomTracks(rm)
        let songText = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        // Skip the artist prefix when the project is self-titled — repeating
        // the title as the subtitle reads as duplicate context.
        let selfTitled = rm.title.compare(rm.artist, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        return HStack(spacing: 13) {
            if let cover = tracks.first {
                TrackArtwork(track: cover, cornerRadius: 8)
                    .frame(width: 44, height: 44)
            } else {
                InitialsCover(id: rm.id, name: rm.title, size: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(rm.title).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel(selfTitled ? songText : "\(rm.artist) · \(songText)", color: PB.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(PB.pencil)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())
    }

    private func swatch(_ t: Track, _ s: CGFloat) -> some View {
        TrackArtwork(track: t, cornerRadius: 8)
            .frame(width: s, height: s)
    }
}
