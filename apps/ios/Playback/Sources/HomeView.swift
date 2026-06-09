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
    @State private var creationSheet: HomeCreationSheet?
    @State private var heroIndex = 0
    @State private var recentVisibleCount = 12
    @State private var bulkMode: BulkSelectionMode?
    @State private var selectedTrackIDs: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var homeNotice: String?
    @State private var selectionDragTargets: [SelectionDragTarget] = []
    @State private var pinnedPageID: Int? = 0
    @State private var springboardPlaylist: Playlist?
    private let heroAdvance = Timer.publish(every: 12, on: .main, in: .common).autoconnect()

    private let recentCountStep = 5
    private let maxRecentCount = 30
    private let pinsPerPage = 3
    private let heroAspectRatio: CGFloat = 3.0 / 4.0
    private var heroFrameWidth: CGFloat {
        #if canImport(UIKit)
        return max(0, UIScreen.main.bounds.width - 48)
        #else
        return 345
        #endif
    }
    private var heroFrameHeight: CGFloat { heroFrameWidth / heroAspectRatio }
    private var featured: Track { store.tracks.first ?? player.track }
    private var isLibraryEmpty: Bool {
        store.tracks.isEmpty && store.playlists.isEmpty && store.rooms.isEmpty
    }
    private var needsEar: [Track] { store.tracks.filter { store.openCount($0.id) > 0 } }
    private let pinCardSize: CGFloat = 104
    private let pinCardSpacing: CGFloat = 14
    private var pinnedCarouselHeight: CGFloat { pinCardSize + 48 }
    private var pinnedRefs: [PinRef] {
        var seen: Set<String> = []
        return store.pins.compactMap { PinRef($0) }.filter { ref in
            guard seen.insert(ref.id).inserted else { return false }
            switch ref.kind {
            case .song:
                return store.track(ref.targetID) != nil
            case .playlist:
                return store.playlist(ref.targetID) != nil
            case .room:
                return store.rooms.contains { $0.id == ref.targetID }
            }
        }
    }
    private var heroTracks: [Track] {
        let pinned = pinnedRefs
            .compactMap { pinnedCover($0, store) }
        return uniqueTracks(pinned + recentTracks).prefix(5).map { $0 }
    }
    private var currentHero: Track {
        let tracks = heroTracks
        guard !tracks.isEmpty else { return featured }
        return tracks[min(heroIndex, tracks.count - 1)]
    }
    private var heroTrackIDs: [String] { heroTracks.map(\.id) }
    private var hasPins: Bool { !pinnedRefs.isEmpty }
    private var recentTracks: [Track] {
        store.tracks.enumerated().sorted { lhs, rhs in
            let lhsRef = PinRef(kind: .song, targetID: lhs.element.id).id
            let rhsRef = PinRef(kind: .song, targetID: rhs.element.id).id
            let lhsActivity = store.activity[lhsRef] ?? Date(timeIntervalSince1970: TimeInterval(1000 - lhs.offset))
            let rhsActivity = store.activity[rhsRef] ?? Date(timeIntervalSince1970: TimeInterval(1000 - rhs.offset))
            return lhsActivity > rhsActivity
        }
        .map(\.element)
    }
    private var displayedRecents: [PinRef] {
        Array(recents.prefix(min(recentVisibleCount, maxRecentCount)))
    }
    private var canShowMoreRecents: Bool {
        displayedRecents.count < recents.count && displayedRecents.count < maxRecentCount
    }
    private var selectedTracks: [Track] {
        store.tracks.filter { selectedTrackIDs.contains($0.id) }
    }
    private func uniqueTracks(_ tracks: [Track]) -> [Track] {
        var seen: Set<String> = []
        return tracks.filter { track in
            guard !seen.contains(track.id) else { return false }
            seen.insert(track.id)
            return true
        }
    }

    private func showMoreRecents() {
        recentVisibleCount = min(recentVisibleCount + recentCountStep, maxRecentCount, recents.count)
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
                    } else {
                        heroCluster
                    }

                    if !needsEar.isEmpty {
                        section("Needs your ear") {
                            VStack(spacing: 0) {
                                ForEach(needsEar) { t in
                                    homeTrackItem(t, showOpen: true)
                                }
                            }
                        }
                    }

                    if !recents.isEmpty {
                        section("Recent") {
                            VStack(spacing: 0) {
                                ForEach(displayedRecents, id: \.id) { ref in
                                    recentRow(ref)
                                }

                                if canShowMoreRecents {
                                    moreRecentsButton
                                }
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
                AmbientDotField(isPlaying: player.isPlaying, positionMs: player.positionMs)
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
            .onReceive(heroAdvance) { _ in
                advanceHero(1)
            }
            .onChange(of: heroTrackIDs) { _, ids in
                if heroIndex >= ids.count { heroIndex = max(0, ids.count - 1) }
            }
            .onChange(of: pinnedRefs.map(\.id)) { _, _ in
                pinnedPageID = 0
            }
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

    private var heroCluster: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            if hasPins {
                pinnedOverlap(pinnedRefs)
                    .padding(.top, -116)
            }
        }
    }

    private var hero: some View {
        let active = currentHero
        let width = heroFrameWidth
        let height = heroFrameHeight
        return Button {
            if bulkMode != nil {
                toggleSelection(active.id)
            } else {
                openSong(active.id)
            }
        } label: {
            ZStack {
                Color.clear
                ForEach(Array(heroTracks.enumerated()), id: \.element.id) { index, track in
                    heroArtworkSurface(track)
                        .frame(width: width, height: height)
                        .opacity(index == heroIndex ? 1 : 0)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(PB.cream.opacity(0.14), lineWidth: 0.75))
            .animation(.easeInOut(duration: 0.7), value: heroIndex)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        MonoLabel("Latest · \(active.versionLabel)", color: .white.opacity(0.8), size: 9, tracking: 1.8)
                        Text(store.displayTitle(active.id, active.title))
                            .font(PB.display(30)).foregroundStyle(.white)
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill").font(.system(size: 11))
                            MonoLabel("Play", color: .white, size: 11, tracking: 1.5)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.white.opacity(0.18)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, hasPins ? 142 : 20)
                }
                .overlay(alignment: .bottomTrailing) {
                    heroPageDots
                        .padding(18)
                }
                .overlay(alignment: .topLeading) {
                    if bulkMode != nil {
                        SelectionMark(isSelected: selectedTrackIDs.contains(active.id))
                            .padding(14)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
            beginSelection(with: active.id, mode: .holding)
        })
        .highPriorityGesture(
            DragGesture(minimumDistance: 28)
                .onEnded { value in
                    guard bulkMode == nil, abs(value.translation.width) > 40 else { return }
                    advanceHero(value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    private var heroPageDots: some View {
        HStack(spacing: 5) {
            ForEach(heroTracks.indices, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(index == heroIndex ? 0.86 : 0.28))
                    .frame(width: index == heroIndex ? 5.5 : 4, height: index == heroIndex ? 5.5 : 4)
            }
        }
        .opacity(heroTracks.count > 1 ? 1 : 0)
    }

    private func advanceHero(_ delta: Int) {
        let count = heroTracks.count
        guard count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.7)) {
            heroIndex = (heroIndex + delta + count) % count
        }
    }

    private func heroArtworkSurface(_ track: Track) -> some View {
        HeroArtwork(track: track, width: heroFrameWidth, height: heroFrameHeight)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func pinnedOverlap(_ refs: [PinRef]) -> some View {
        let pages = pinnedPages(refs)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MonoLabel("Pinned", color: PB.pencil, size: 11, tracking: 2)
                Spacer()
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                if pages.count > 1 {
                    pinnedPageDots(count: pages.count)
                }
            }
            GeometryReader { proxy in
                let cardSize = pinCardSize(for: proxy.size.width)
                let spacing = pinSpacing(for: proxy.size.width, cardSize: cardSize)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, page in
                            HStack(spacing: spacing) {
                                ForEach(page) { ref in
                                    pinCard(ref, size: cardSize)
                                }
                                if page.count < pinsPerPage {
                                    Spacer(minLength: 0)
                                }
                            }
                            .frame(width: proxy.size.width, alignment: .leading)
                            .id(pageIndex)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $pinnedPageID)
            }
            .frame(height: pinnedCarouselHeight)
        }
    }

    private func pinnedPages(_ refs: [PinRef]) -> [[PinRef]] {
        stride(from: 0, to: refs.count, by: pinsPerPage).map { start in
            Array(refs[start..<Swift.min(start + pinsPerPage, refs.count)])
        }
    }

    private func pinCardSize(for availableWidth: CGFloat) -> CGFloat {
        let compactSpacing: CGFloat = 12
        let fitted = (availableWidth - compactSpacing * CGFloat(pinsPerPage - 1)) / CGFloat(pinsPerPage)
        return min(pinCardSize, floor(fitted))
    }

    private func pinSpacing(for availableWidth: CGFloat, cardSize: CGFloat) -> CGFloat {
        let fitted = (availableWidth - cardSize * CGFloat(pinsPerPage)) / CGFloat(pinsPerPage - 1)
        return min(pinCardSpacing, max(10, fitted))
    }

    private func pinnedPageDots(count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(PB.pencil.opacity((pinnedPageID ?? 0) == index ? 0.95 : 0.36))
                    .frame(width: (pinnedPageID ?? 0) == index ? 5 : 4, height: (pinnedPageID ?? 0) == index ? 5 : 4)
            }
        }
        .frame(width: CGFloat(count) * 7, alignment: .trailing)
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

    private func trackRow(_ t: Track, showOpen: Bool) -> some View {
        HStack(spacing: 13) {
            swatch(t, 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayTitle(t.id, t.title)).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel("\(t.artist) · \(t.versionLabel)", color: PB.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            if showOpen, store.openCount(t.id) > 0 {
                MonoLabel("\(store.openCount(t.id)) open", color: PB.redline, size: 9, tracking: 1)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())
    }

    private func homeTrackItem(_ t: Track, showOpen: Bool) -> some View {
        let inHolding = bulkMode == .holding && !selectedTrackIDs.isEmpty
        let isSelected = selectedTrackIDs.contains(t.id)
        // In holding mode: selected rows carry the full pile; unselected rows are
        // drop targets so the user can "drop on a song to create playlist."
        let dragEnabled = bulkMode == nil || (inHolding && isSelected)
        let dropEnabled = bulkMode == nil || (inHolding && !isSelected)

        return HStack(spacing: 8) {
            if bulkMode != nil {
                Button { toggleSelection(t.id) } label: {
                    SelectionMark(isSelected: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected
                    ? "Deselect \(store.displayTitle(t.id, t.title))"
                    : "Select \(store.displayTitle(t.id, t.title))")
            }

            Button {
                if bulkMode != nil {
                    toggleSelection(t.id)
                } else {
                    openSong(t.id)
                }
            } label: {
                trackRow(t, showOpen: showOpen)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                beginSelection(with: t.id, mode: .holding)
            })

            // Pile badge — visible on selected rows in holding mode
            if inHolding && isSelected {
                PileBadge(count: selectedTrackIDs.count)
                    .padding(.trailing, 4)
            }
        }
        .springboardDraggable(trackID: t.id, track: t, store: store,
                              enabled: bulkMode == nil)
        .springboardPileDraggable(pileIDs: Array(selectedTrackIDs),
                                  pileTracks: selectedTracks,
                                  store: store,
                                  enabled: inHolding && isSelected)
        .springboardDropTarget(targetID: t.id, enabled: dropEnabled,
                               onDrop: handleSpringboardDrop)
        .songActionsMenu(store, t)
        .selectionDragTarget(id: t.id)
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
            showMoreRecents()
        } label: {
            HStack(spacing: 8) {
                MonoLabel("More", color: PB.cobalt, size: 10, tracking: 1.6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PB.cobalt)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show more recent items")
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

    @ViewBuilder private func recentRow(_ ref: PinRef) -> some View {
        if ref.kind == .song, let track = store.track(ref.targetID) {
            homeTrackItem(track, showOpen: false)
        } else {
            recentNavigationRow(ref)
        }
    }

    @ViewBuilder private func recentNavigationRow(_ ref: PinRef) -> some View {
        let cover = pinnedCover(ref, store) ?? featured
        let sub = pinnedSubtitle(ref)
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

    @ViewBuilder private func pinCard(_ ref: PinRef, size: CGFloat? = nil) -> some View {
        let size = size ?? pinCardSize
        let cover = pinnedCover(ref, store) ?? featured
        let card = VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                TrackArtwork(track: cover, cornerRadius: 12)
                    .frame(width: size, height: size)
                Image(systemName: "pin.fill").font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(8)
            }
            .overlay(alignment: .topLeading) {
                if bulkMode != nil, ref.kind == .song {
                    SelectionMark(isSelected: selectedTrackIDs.contains(ref.targetID))
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(pinnedTitle(ref, store))
                    .font(PB.display(13))
                    .foregroundStyle(PB.cream)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: size, alignment: .leading)
                MonoLabel(pinnedSubtitle(ref), color: PB.pencil, size: 8, tracking: 1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: size, alignment: .leading)
            }
        }
        .frame(width: size)

        Group {
            switch ref.kind {
            case .song:
                Button {
                    if bulkMode != nil {
                        toggleSelection(ref.targetID)
                    } else {
                        openSong(ref.targetID)
                    }
                } label: {
                    card
                }
                .buttonStyle(.plain)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                    beginSelection(with: ref.targetID, mode: .holding)
                })
            case .playlist:
                if let pl = store.playlist(ref.targetID) {
                    NavigationLink(value: pl) { card }.buttonStyle(.plain)
                } else { card }
            case .room:
                if let rm = store.rooms.first(where: { $0.id == ref.targetID }) {
                    NavigationLink(value: rm) { card }.buttonStyle(.plain)
                } else { card }
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
        HStack(spacing: 13) {
            let cover = rm.trackIDs.compactMap { store.track($0) }.first ?? featured
            TrackArtwork(track: cover, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(rm.title).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel("\(rm.artist) · \(rm.trackIDs.count) songs", color: PB.pencil, size: 9, tracking: 1.2)
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

/// Hero artwork that always fills the tall hero card.
///
/// `AsyncImage` collapses to its loaded image's aspect ratio inside the hero's
/// layout — a wide cover in the 3:4 card fills only the top and leaves the rest
/// black. Remote artwork is therefore loaded into a `UIImage` and drawn at an
/// explicitly computed cover scale (see `fill`), so it crops to fill the card
/// regardless of the image's aspect ratio.
private struct HeroArtwork: View {
    let track: Track
    let width: CGFloat
    let height: CGFloat
    #if canImport(UIKit)
    @State private var remoteImage: UIImage?
    #endif

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let local = TrackArtworkLoader.uiImage(for: track) {
                Image(uiImage: local).resizable().scaledToFill()
            } else if let remoteImage {
                Image(uiImage: remoteImage).resizable().scaledToFill()
            } else {
                MeshCover(colors: track.mesh, animate: true, fillsSafeArea: false)
            }
            #else
            MeshCover(colors: track.mesh, animate: true, fillsSafeArea: false)
            #endif
        }
        .frame(width: width, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        #if canImport(UIKit)
        .task(id: track.id) { await loadRemoteArtwork() }
        #endif
    }

    #if canImport(UIKit)
    private func loadRemoteArtwork() async {
        remoteImage = nil
        guard TrackArtworkLoader.uiImage(for: track) == nil,
              let raw = track.remoteArtworkURL,
              let url = URL(string: raw) else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        remoteImage = image
    }
    #endif
}
