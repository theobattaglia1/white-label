import SwiftUI

/// Global search and index for the workspace.
struct ExploreView: View {
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void
    var openQueue: (String, [Track]) -> Void = { _, _ in }
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var reviewTracks: [Track] {
        let flagged = store.tracks.filter { store.openCount($0.id) > 0 }
        return Array((flagged.isEmpty ? store.tracks : flagged).prefix(5))
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasQuery: Bool { !trimmedQuery.isEmpty }

    private var matchingArtists: [ArtistSummary] {
        guard hasQuery else { return store.artistSummaries }
        return store.artistSummaries.filter { matches($0.name) }
    }

    private var matchingPlaylists: [Playlist] {
        guard hasQuery else { return store.playlists }
        return store.playlists.filter { matches($0.title) || matches($0.subtitle) }
    }

    private var matchingProjects: [Room] {
        guard hasQuery else { return store.rooms }
        return store.rooms.filter { matches($0.title) || matches($0.artist) }
    }

    private var matchingTracks: [Track] {
        guard hasQuery else { return store.tracks }
        return store.tracks.filter {
            matches(store.displayTitle($0.id, $0.title))
                || matches($0.artist)
                || matches($0.label)
                || matches($0.versionLabel)
                || matches($0.catalog)
        }
    }

    private var matchingSavedViews: [SavedViewSummary] {
        guard hasQuery else { return store.savedViews }
        return store.savedViews.filter { matches($0.name) || matches($0.detail) }
    }

    private var hasResults: Bool {
        !matchingArtists.isEmpty
            || !matchingPlaylists.isEmpty
            || !matchingProjects.isEmpty
            || !matchingTracks.isEmpty
            || !matchingSavedViews.isEmpty
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                scrollToTopMarker()
                VStack(alignment: .leading, spacing: 24) {
                    AppScreenHeader(title: "Search", isPlaying: player.isPlaying)
                    searchField
                    syncStrip

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
                AmbientDotField(isPlaying: player.isPlaying, positionMs: player.positionMs)
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
        section("Index") {
            indexRow(icon: "person.crop.circle", title: "Artists", detail: "\(store.artistSummaries.count)")
            indexRow(icon: "text.badge.plus", title: "Playlists", detail: "\(store.playlists.count)")
            indexRow(icon: "folder", title: "Projects", detail: "\(store.rooms.count)")
            indexRow(icon: "music.note", title: "Songs", detail: "\(store.tracks.count)")
        }

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
            section("Recent signals") {
                ForEach(reviewTracks) { track in
                    Button { openQueue(track.id, reviewTracks) } label: {
                        songResultRow(track, trailing: store.openCount(track.id) > 0 ? "\(store.openCount(track.id)) open" : nil)
                    }
                    .buttonStyle(.plain)
                    .songActionsMenu(store, track)
                }
            }
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        if !hasResults {
            noResults
        } else {
            if !matchingArtists.isEmpty {
                section("Artists") {
                    ForEach(matchingArtists) { artist in
                        NavigationLink {
                            ArtistDetailView(artist: artist, player: player, store: store, openQueue: openQueue)
                        } label: {
                            artistResultRow(artist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !matchingPlaylists.isEmpty {
                section("Playlists") {
                    ForEach(matchingPlaylists) { playlist in
                        NavigationLink(value: playlist) {
                            exploreRow(icon: "text.badge.plus", title: playlist.title, detail: "\(playlist.trackIDs.count) tracks")
                        }
                        .buttonStyle(.plain)
                        .pinMenu(store, PinRef(kind: .playlist, targetID: playlist.id))
                    }
                }
            }

            if !matchingProjects.isEmpty {
                section("Projects") {
                    ForEach(matchingProjects) { room in
                        NavigationLink(value: room) {
                            exploreRow(icon: "folder", title: room.title, detail: "\(room.artist) · \(room.trackIDs.count) songs")
                        }
                        .buttonStyle(.plain)
                        .pinMenu(store, PinRef(kind: .room, targetID: room.id))
                    }
                }
            }

            if !matchingTracks.isEmpty {
                section("Songs") {
                    ForEach(matchingTracks) { track in
                        Button { openQueue(track.id, matchingTracks) } label: {
                            songResultRow(track)
                        }
                        .buttonStyle(.plain)
                        .songActionsMenu(store, track)
                    }
                }
            }

            if !matchingSavedViews.isEmpty {
                section("Smart views") {
                    ForEach(matchingSavedViews) { view in
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

    private func matches(_ value: String) -> Bool {
        let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let queryKey = trimmedQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return key.contains(queryKey)
    }

    private func syncStripLabel(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(plural)"
    }

    private func indexRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(PB.cream)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PB.cream.opacity(0.08)))
            Text(title).font(PB.display(17)).foregroundStyle(PB.cream)
            Spacer()
            MonoLabel(detail, color: PB.pencil, size: 9, tracking: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 69)
        }
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
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PB.cream)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PB.cream.opacity(0.08)))
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

    private var syncColor: Color {
        switch store.syncState {
        case .synced: return PB.green
        case .syncing, .saving: return PB.cobalt
        case .offline, .error: return PB.redline
        default: return PB.pencil
        }
    }

    private var syncStrip: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(syncColor)
                .frame(width: 7, height: 7)
            MonoLabel(store.syncMessage, color: PB.pencil, size: 9, tracking: 1.2)
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
            VStack(spacing: 0) { content() }
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

    private var tracks: [Track] {
        let descriptor = "\(summary.name) \(summary.detail)".lowercased()
        if descriptor.contains("open") || descriptor.contains("review") || descriptor.contains("needs") {
            let filtered = store.tracks.filter { store.openCount($0.id) > 0 }
            return filtered.isEmpty ? store.tracks : filtered
        }
        return store.tracks
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                scrollToTopMarker()
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        MonoLabel("Smart view", color: PB.pencil, size: 10, tracking: 2)
                        Text(summary.name).font(PB.display(32)).foregroundStyle(PB.cream)
                        MonoLabel("\(tracks.count) songs · \(summary.detail)", color: PB.pencil, size: 10, tracking: 1.1)
                    }
                    .padding(.top, 40)

                    VStack(spacing: 0) {
                        ForEach(tracks) { track in
                            Button { openQueue(track.id, tracks) } label: {
                                SongRow(track: track, store: store,
                                        trailing: store.openCount(track.id) > 0 ? "\(store.openCount(track.id)) open" : nil,
                                        trailingColor: PB.redline)
                            }
                            .buttonStyle(.plain)
                            .songActionsMenu(store, track)
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
                AmbientDotField(isPlaying: player.isPlaying, positionMs: player.positionMs)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                TopTapScrollHotspot { scrollToTop(scrollProxy) }
            }
            .overlay(alignment: .topLeading) { BackButton().padding(.leading, 16).padding(.top, 6) }
        }
    }
}
