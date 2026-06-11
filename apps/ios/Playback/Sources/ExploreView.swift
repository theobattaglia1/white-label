import SwiftUI

/// Global search for the workspace.
struct ExploreView: View {
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void
    var openQueue: (String, [Track]) -> Void = { _, _ in }
    @State private var query = ""
    @State private var bulkMode: BulkSelectionMode?
    @State private var selectedTrackIDs: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var exploreNotice: PlaylistEditNotice?
    @State private var springboardPlaylist: Playlist?
    @State private var selectionDragTargets: [SelectionDragTarget] = []
    @FocusState private var searchFocused: Bool

    /// Most recently played/opened songs — backs the "Recently played"
    /// section (mirrors Home's activity ordering).
    private var reviewTracks: [Track] {
        let sorted = store.tracks.enumerated().sorted { lhs, rhs in
            let lhsDate = store.activity[PinRef(kind: .song, targetID: lhs.element.id).id]
                ?? Date(timeIntervalSince1970: TimeInterval(1000 - lhs.offset))
            let rhsDate = store.activity[PinRef(kind: .song, targetID: rhs.element.id).id]
                ?? Date(timeIntervalSince1970: TimeInterval(1000 - rhs.offset))
            return lhsDate > rhsDate
        }
        return Array(sorted.map(\.element).prefix(5))
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasQuery: Bool { !trimmedQuery.isEmpty }

    /// Query folded once per filter pass instead of once per compared field.
    private var queryKey: String {
        trimmedQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private var matchingArtists: [ArtistSummary] {
        guard hasQuery else { return store.artistSummaries }
        let key = queryKey
        return store.artistSummaries.filter { matches($0.name, key) }
    }

    private var matchingPlaylists: [Playlist] {
        guard hasQuery else { return store.playlists }
        let key = queryKey
        return store.playlists.filter { matches($0.title, key) || matches($0.subtitle, key) }
    }

    private var matchingProjects: [Room] {
        guard hasQuery else { return store.rooms }
        let key = queryKey
        return store.rooms.filter { matches($0.title, key) || matches($0.artist, key) }
    }

    private var matchingTracks: [Track] {
        guard hasQuery else { return store.tracks }
        let key = queryKey
        return store.tracks.filter {
            matches(store.displayTitle($0.id, $0.title), key)
                || matches($0.artist, key)
                || matches($0.label, key)
                || matches($0.versionLabel, key)
                || matches($0.catalog, key)
        }
    }

    private var matchingSavedViews: [SavedViewSummary] {
        guard hasQuery else { return store.savedViews }
        let key = queryKey
        return store.savedViews.filter { matches($0.name, key) || matches($0.detail, key) }
    }

    private var hasResults: Bool {
        !matchingArtists.isEmpty
            || !matchingPlaylists.isEmpty
            || !matchingProjects.isEmpty
            || !matchingTracks.isEmpty
            || !matchingSavedViews.isEmpty
    }

    private var visibleInteractionTracks: [Track] {
        hasQuery ? matchingTracks : reviewTracks
    }

    private var selectedTracks: [Track] {
        store.tracks.filter { selectedTrackIDs.contains($0.id) }
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                scrollToTopMarker()
                VStack(alignment: .leading, spacing: 24) {
                    AppScreenHeader(title: "Search", isPlaying: player.isPlaying) {
                        if !visibleInteractionTracks.isEmpty {
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
                    }
                    searchField
                    syncStrip
                    if let exploreNotice {
                        editNotice(exploreNotice)
                    }

                    if hasQuery {
                        resultSections
                    } else {
                        indexSections
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 150)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background {
                PB.black.ignoresSafeArea()
                // Observes position ticks in its own body — keeps this screen
                // from re-laying-out 20×/sec while audio plays (search lag).
                AmbientPlayerBackdrop(player: player)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
            .overlay(alignment: .top) {
                TopTapScrollHotspot { scrollToTop(scrollProxy) }
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { searchFocused = false }
                        .font(PB.mono(13))
                        .foregroundStyle(PB.cobalt)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    searchFocused = true
                }
            }
            .onPreferenceChange(SelectionDragTargetKey.self) { targets in
                selectionDragTargets = targets
            }
            .twoFingerSelection(
                enabled: !visibleInteractionTracks.isEmpty,
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
            .sheet(item: $springboardPlaylist) { playlist in
                PlaylistDetailView(playlist: playlist, player: player, store: store, openSong: openSong, openQueue: openQueue)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PB.pencil)
            TextField("Search everything", text: $query)
                .font(PB.text(18))
                .foregroundStyle(PB.cream)
                .tint(PB.cobalt)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PB.pencil)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            if searchFocused {
                Button {
                    searchFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PB.pencil)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss keyboard")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private var indexSections: some View {
        if !matchingSavedViews.isEmpty {
            section("Smart views") {
                ForEach(matchingSavedViews.prefix(4)) { view in
                    NavigationLink {
                        SavedViewDetailView(summary: view, player: player, store: store, openQueue: openQueue)
                    } label: {
                        exploreRow(icon: "line.3.horizontal.decrease.circle", title: view.name, detail: view.detail)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !reviewTracks.isEmpty {
            section("Recently played") {
                ForEach(reviewTracks) { track in
                    exploreSongItem(track, queue: reviewTracks,
                                    trailing: store.openCount(track.id) > 0 ? "\(store.openCount(track.id)) open" : nil)
                }
            }
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        // Bind each result list once per render — the computed properties
        // re-filter on every access, which multiplies per-keystroke work.
        let artists = matchingArtists
        let playlists = matchingPlaylists
        let projects = matchingProjects
        let tracks = matchingTracks
        let savedViews = matchingSavedViews
        if artists.isEmpty && playlists.isEmpty && projects.isEmpty && tracks.isEmpty && savedViews.isEmpty {
            noResults
        } else {
            if !artists.isEmpty {
                section("Artists") {
                    ForEach(artists) { artist in
                        NavigationLink {
                            ArtistDetailView(artist: artist, player: player, store: store, openQueue: openQueue)
                        } label: {
                            artistResultRow(artist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !playlists.isEmpty {
                section("Playlists") {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: playlist) {
                            exploreRow(icon: "text.badge.plus", title: playlist.title, detail: "\(playlist.trackIDs.count) tracks")
                        }
                        .buttonStyle(.plain)
                        .pinMenu(store, PinRef(kind: .playlist, targetID: playlist.id))
                    }
                }
            }

            if !projects.isEmpty {
                section("Projects") {
                    ForEach(projects) { room in
                        NavigationLink(value: room) {
                            exploreRow(icon: "folder", title: room.title, detail: "\(room.artist) · \(room.trackIDs.count) songs")
                        }
                        .buttonStyle(.plain)
                        .pinMenu(store, PinRef(kind: .room, targetID: room.id))
                    }
                }
            }

            if !tracks.isEmpty {
                section("Songs") {
                    ForEach(tracks) { track in
                        exploreSongItem(track, queue: tracks)
                    }
                }
            }

            if !savedViews.isEmpty {
                section("Smart views") {
                    ForEach(savedViews) { view in
                        NavigationLink {
                            SavedViewDetailView(summary: view, player: player, store: store, openQueue: openQueue)
                        } label: {
                            exploreRow(icon: "line.3.horizontal.decrease.circle", title: view.name, detail: view.detail)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var noResults: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("No matches").font(PB.display(20)).foregroundStyle(PB.cream)
            MonoLabel(trimmedQuery, color: PB.pencil, size: 9, tracking: 1.2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
    }

    private func matches(_ value: String, _ key: String) -> Bool {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(key)
    }

    private func exploreSongItem(_ track: Track, queue: [Track], trailing: String? = nil) -> some View {
        InteractiveSongItem(
            track: track,
            store: store,
            bulkMode: $bulkMode,
            selectedTrackIDs: $selectedTrackIDs,
            selectedTracks: selectedTracks,
            onOpen: { openQueue(track.id, queue) },
            onSpringboardDrop: handleSpringboardDrop
        ) {
            songResultRow(track, trailing: trailing)
        } idleAccessory: {
            EmptyView()
        }
    }

    private func handleSpringboardDrop(_ ids: [String]) {
        guard ids.count >= 2 else { return }
        let tracks = ids.compactMap { store.track($0) }
        let title = tracks.count == 2
            ? "\(tracks[0].title) + \(tracks[1].title)"
            : "\(tracks[0].title) + \(tracks.count - 1) more"
        let playlist = store.createKeptPlaylist(title: title, trackIDs: ids)
        clearSelection()
        withAnimation(.easeInOut(duration: 0.18)) { springboardPlaylist = playlist }
    }

    private func selectDuringDrag(_ id: String) {
        if bulkMode == nil { bulkMode = .selecting }
        selectedTrackIDs.insert(id)
    }

    private func clearSelection() {
        selectedTrackIDs.removeAll()
        bulkMode = nil
    }

    private func createPlaylistFromSelection() {
        guard !selectedTracks.isEmpty else { return }
        _ = store.createKeptPlaylist(title: "Search Selection", trackIDs: selectedTracks.map(\.id))
        showNotice("Playlist created")
        clearSelection()
    }

    private func addSelection(to playlist: Playlist) {
        selectedTracks.forEach { store.addTrack($0.id, toPlaylist: playlist.id) }
        showNotice("Added to \(playlist.title)")
        clearSelection()
    }

    private func addSelection(to room: Room) {
        selectedTracks.forEach { store.addTrack($0.id, toProject: room.id) }
        showNotice("Added to \(room.title)")
        clearSelection()
    }

    private func shareSelection() {
        guard copyShareLinks(selectedTracks, store: store) else { return }
        showNotice(Config.useRemoteAPI ? "Titles copied" : "Share links copied")
        clearSelection()
    }

    private func deleteSelectedSongs() {
        let ids = selectedTrackIDs
        let deleted = ids.reduce(0) { count, id in
            count + (store.deleteTrack(id) ? 1 : 0)
        }
        if !store.tracks.isEmpty { player.replaceQueue(store.tracks) }
        showNotice(deleted == 0 ? "Nothing deleted" : "Deleted \(deleted)")
        clearSelection()
    }

    private func showNotice(_ message: String) {
        let notice = PlaylistEditNotice(message: message)
        withAnimation(.easeInOut(duration: 0.18)) { exploreNotice = notice }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if exploreNotice?.id == notice.id {
                withAnimation(.easeInOut(duration: 0.18)) { exploreNotice = nil }
            }
        }
    }

    private func editNotice(_ notice: PlaylistEditNotice) -> some View {
        MonoLabel(notice.message, color: PB.green, size: 10, tracking: 1.4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.green.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(PB.green.opacity(0.32), lineWidth: 1))
    }

    private func syncStripLabel(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(plural)"
    }

    private func artistResultRow(_ artist: ArtistSummary) -> some View {
        let cover = artist.trackIDs.compactMap { store.track($0) }.first
        let songText = syncStripLabel(artist.trackIDs.count, singular: "song", plural: "songs")
        let projectText = syncStripLabel(artist.projectIDs.count, singular: "project", plural: "projects")
        return HStack(spacing: 13) {
            if let cover {
                TrackArtwork(track: cover, cornerRadius: 7)
                    .frame(width: 46, height: 46)
            } else {
                InitialsCover(id: artist.id, name: artist.name, size: 46, cornerRadius: 7)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(PB.display(17))
                    .foregroundStyle(PB.cream)
                MonoLabel("\(songText) · \(projectText)", color: PB.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(PB.pencil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 69)
        }
    }

    private func songResultRow(_ track: Track, trailing: String? = nil) -> some View {
        HStack(spacing: 13) {
            TrackArtwork(track: track, cornerRadius: 7)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayTitle(track.id, track.title))
                    .font(PB.display(17))
                    .foregroundStyle(PB.cream)
                MonoLabel("\(track.artist) · \(track.versionLabel)", color: PB.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            if let trailing {
                MonoLabel(trailing, color: PB.redline, size: 9, tracking: 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 69)
        }
    }

    private var syncStrip: some View {
        // Cloud status detail lives on Profile — this strip stays a plain
        // library count so the same state isn't reported in two places.
        HStack(spacing: 10) {
            MonoLabel("Library", color: PB.pencil, size: 9, tracking: 1.2)
            Spacer()
            MonoLabel("\(store.tracks.count) songs", color: PB.cream.opacity(0.7), size: 9, tracking: 1.2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.panel))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MonoLabel(title, color: PB.pencil, size: 10, tracking: 2)
            // Lazy: broad queries match hundreds of songs — only build the
            // rows that scroll into view instead of the whole list per keystroke.
            LazyVStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel.opacity(0.72)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
        }
    }

    private func exploreRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(PB.cream)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PB.cream.opacity(0.08)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel(detail, color: PB.pencil, size: 9, tracking: 1.1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(PB.pencil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 69)
        }
    }
}

struct SavedViewDetailView: View {
    var summary: SavedViewSummary
    var player: Player
    var store: WorkspaceStore
    var openQueue: (String, [Track]) -> Void
    @State private var bulkMode: BulkSelectionMode?
    @State private var selectedTrackIDs: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var savedViewNotice: PlaylistEditNotice?
    @State private var springboardPlaylist: Playlist?
    @State private var selectionDragTargets: [SelectionDragTarget] = []

    private var tracks: [Track] {
        let descriptor = "\(summary.name) \(summary.detail)".lowercased()
        if descriptor.contains("open") || descriptor.contains("review") || descriptor.contains("needs") {
            let filtered = store.tracks.filter { store.openCount($0.id) > 0 }
            return filtered.isEmpty ? store.tracks : filtered
        }
        return store.tracks
    }
    private var selectedTracks: [Track] { tracks.filter { selectedTrackIDs.contains($0.id) } }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                scrollToTopMarker()
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            MonoLabel("Smart view", color: PB.pencil, size: 10, tracking: 2)
                            Text(summary.name).font(PB.display(32)).foregroundStyle(PB.cream)
                            MonoLabel("\(tracks.count) songs · \(summary.detail)", color: PB.pencil, size: 10, tracking: 1.1)
                        }
                        Spacer(minLength: 10)
                        if !tracks.isEmpty {
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
                    }
                    .padding(.top, 40)

                    if let savedViewNotice {
                        editNotice(savedViewNotice)
                    }

                    VStack(spacing: 0) {
                        ForEach(tracks) { track in
                            savedViewSongItem(track)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 150)
            }
            .scrollIndicators(.hidden)
            .background {
                PB.black.ignoresSafeArea()
                AmbientPlayerBackdrop(player: player)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                TopTapScrollHotspot { scrollToTop(scrollProxy) }
            }
            .overlay(alignment: .topLeading) { BackButton().padding(.leading, 16).padding(.top, 6) }
            .onPreferenceChange(SelectionDragTargetKey.self) { targets in
                selectionDragTargets = targets
            }
            .twoFingerSelection(
                enabled: !tracks.isEmpty,
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
            .sheet(item: $springboardPlaylist) { playlist in
                PlaylistDetailView(playlist: playlist, player: player, store: store,
                                   openSong: { id in openQueue(id, store.tracks) }, openQueue: openQueue)
            }
        }
    }

    private func savedViewSongItem(_ track: Track) -> some View {
        InteractiveSongItem(
            track: track,
            store: store,
            bulkMode: $bulkMode,
            selectedTrackIDs: $selectedTrackIDs,
            selectedTracks: selectedTracks,
            onOpen: { openQueue(track.id, tracks) },
            onSpringboardDrop: handleSpringboardDrop
        ) {
            SongRow(track: track, store: store,
                    trailing: store.openCount(track.id) > 0 ? "\(store.openCount(track.id)) open" : nil,
                    trailingColor: PB.redline)
        } idleAccessory: {
            EmptyView()
        }
    }

    private func handleSpringboardDrop(_ ids: [String]) {
        guard ids.count >= 2 else { return }
        let tracks = ids.compactMap { store.track($0) }
        let title = tracks.count == 2
            ? "\(tracks[0].title) + \(tracks[1].title)"
            : "\(tracks[0].title) + \(tracks.count - 1) more"
        let playlist = store.createKeptPlaylist(title: title, trackIDs: ids)
        clearSelection()
        withAnimation(.easeInOut(duration: 0.18)) { springboardPlaylist = playlist }
    }

    private func selectDuringDrag(_ id: String) {
        if bulkMode == nil { bulkMode = .selecting }
        selectedTrackIDs.insert(id)
    }

    private func clearSelection() {
        selectedTrackIDs.removeAll()
        bulkMode = nil
    }

    private func createPlaylistFromSelection() {
        guard !selectedTracks.isEmpty else { return }
        _ = store.createKeptPlaylist(title: "\(summary.name) Selection", trackIDs: selectedTracks.map(\.id))
        showNotice("Playlist created")
        clearSelection()
    }

    private func addSelection(to playlist: Playlist) {
        selectedTracks.forEach { store.addTrack($0.id, toPlaylist: playlist.id) }
        showNotice("Added to \(playlist.title)")
        clearSelection()
    }

    private func addSelection(to room: Room) {
        selectedTracks.forEach { store.addTrack($0.id, toProject: room.id) }
        showNotice("Added to \(room.title)")
        clearSelection()
    }

    private func shareSelection() {
        guard copyShareLinks(selectedTracks, store: store) else { return }
        showNotice(Config.useRemoteAPI ? "Titles copied" : "Share links copied")
        clearSelection()
    }

    private func deleteSelectedSongs() {
        let ids = selectedTrackIDs
        let deleted = ids.reduce(0) { count, id in
            count + (store.deleteTrack(id) ? 1 : 0)
        }
        if !store.tracks.isEmpty { player.replaceQueue(store.tracks) }
        showNotice(deleted == 0 ? "Nothing deleted" : "Deleted \(deleted)")
        clearSelection()
    }

    private func showNotice(_ message: String) {
        let notice = PlaylistEditNotice(message: message)
        withAnimation(.easeInOut(duration: 0.18)) { savedViewNotice = notice }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if savedViewNotice?.id == notice.id {
                withAnimation(.easeInOut(duration: 0.18)) { savedViewNotice = nil }
            }
        }
    }

    private func editNotice(_ notice: PlaylistEditNotice) -> some View {
        MonoLabel(notice.message, color: PB.green, size: 10, tracking: 1.4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.green.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(PB.green.opacity(0.32), lineWidth: 1))
    }
}
