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
    private let heroAdvance = Timer.publish(every: 12, on: .main, in: .common).autoconnect()

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
    private var heroTracks: [Track] {
        let pinned = store.pins
            .compactMap { PinRef($0) }
            .compactMap { pinnedCover($0, store) }
        return uniqueTracks(pinned + recentTracks).prefix(5).map { $0 }
    }
    private var currentHero: Track {
        let tracks = heroTracks
        guard !tracks.isEmpty else { return featured }
        return tracks[min(heroIndex, tracks.count - 1)]
    }
    private var heroTrackIDs: [String] { heroTracks.map(\.id) }
    private var hasPins: Bool { store.pins.contains { PinRef($0) != nil } }
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

    private func uniqueTracks(_ tracks: [Track]) -> [Track] {
        var seen: Set<String> = []
        return tracks.filter { track in
            guard !seen.contains(track.id) else { return false }
            seen.insert(track.id)
            return true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                homeHeader

                if isLibraryEmpty {
                    startPanel
                } else {
                    heroCluster
                }

                if !needsEar.isEmpty {
                    section("Needs your ear") {
                        VStack(spacing: 0) {
                            ForEach(needsEar) { t in
                                Button { openSong(t.id) } label: { trackRow(t, showOpen: true) }
                                    .buttonStyle(.plain)
                                    .songActionsMenu(store, t)
                            }
                        }
                    }
                }

                if !recents.isEmpty {
                    section("Recent") {
                        VStack(spacing: 0) {
                            ForEach(recents, id: \.id) { ref in
                                recentRow(ref)
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
        .overlay(alignment: .top) { TopScrollFade() }
        .foregroundStyle(PB.cream)
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(heroAdvance) { _ in
            advanceHero(1)
        }
        .onChange(of: heroTrackIDs) { _, ids in
            if heroIndex >= ids.count { heroIndex = max(0, ids.count - 1) }
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
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PB.cream)
                .frame(width: 44, height: 44)
                .background(Circle().fill(PB.panel))
                .overlay(Circle().strokeBorder(PB.cream.opacity(0.1), lineWidth: 1))
        }
        .accessibilityLabel("Add")
    }

    private var homeHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            PlaybackWordmark(capSize: 22, fontSize: 24, isPlaying: player.isPlaying)
                .frame(width: 156, height: 26, alignment: .leading)
            Spacer(minLength: 0)
            addMenu
        }
        .frame(height: 44, alignment: .center)
    }

    private var heroCluster: some View {
        let refs = store.pins.compactMap { PinRef($0) }
        return VStack(alignment: .leading, spacing: 0) {
            hero
            if !refs.isEmpty {
                pinnedOverlap(refs)
                    .padding(.top, -116)
            }
        }
    }

    private var hero: some View {
        let active = currentHero
        let width = heroFrameWidth
        let height = heroFrameHeight
        return Button { openSong(active.id) } label: {
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
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .highPriorityGesture(
            DragGesture(minimumDistance: 28)
                .onEnded { value in
                    guard abs(value.translation.width) > 40 else { return }
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
        TrackArtwork(track: track, cornerRadius: 18, showsKeyline: false)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func pinnedOverlap(_ refs: [PinRef]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MonoLabel("Pinned", color: PB.pencil, size: 11, tracking: 2)
                Spacer()
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(refs) { ref in pinCard(ref) }
                }
                .padding(.horizontal, 1)
                .padding(.bottom, 2)
            }
        }
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

    /// Playlists + projects, ordered by recent activity (untouched fall to a
    /// stable default order so Home is never empty).
    private var recents: [PinRef] {
        var entries: [(PinRef, Date)] = []
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
        let cover = pinnedCover(ref, store) ?? featured
        let sub: String = {
            switch ref.kind {
            case .playlist: return "Playlist · \(store.playlist(ref.targetID)?.trackIDs.count ?? 0) tracks"
            case .room: return "Project · \(store.rooms.first { $0.id == ref.targetID }?.artist ?? "")"
            case .song: return "Song"
            }
        }()
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

    @ViewBuilder private func pinCard(_ ref: PinRef) -> some View {
        let cover = pinnedCover(ref, store) ?? featured
        let card = ZStack(alignment: .topTrailing) {
            TrackArtwork(track: cover, cornerRadius: 12)
                .frame(width: pinCardSize, height: pinCardSize)
            Image(systemName: "pin.fill").font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.85))
                .padding(8)
        }
        .frame(width: pinCardSize)

        Group {
            switch ref.kind {
            case .song:
                Button { openSong(ref.targetID) } label: { card }.buttonStyle(.plain)
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
