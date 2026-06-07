import SwiftUI

/// Home — what to play, and what needs your ear.
struct HomeView: View {
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void

    private var featured: Track { SampleData.tracks.first ?? player.track }
    private var needsEar: [Track] { SampleData.tracks.filter { store.openCount($0.id) > 0 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    MonoLabel("White Label", color: WL.pencil, size: 11, tracking: 2.5)
                    Text("Home").font(WL.display(40)).foregroundStyle(WL.cream)
                }

                hero

                let refs = store.pins.compactMap { PinRef($0) }
                if !refs.isEmpty {
                    section("Pinned") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(refs) { ref in pinCard(ref) }
                            }
                        }
                    }
                }

                if !needsEar.isEmpty {
                    section("Needs your ear") {
                        VStack(spacing: 0) {
                            ForEach(needsEar) { t in
                                Button { openSong(t.id) } label: { trackRow(t, showOpen: true) }
                                    .buttonStyle(.plain)
                                    .pinMenu(store, PinRef(kind: .song, targetID: t.id))
                            }
                        }
                    }
                }

                section("Recent") {
                    VStack(spacing: 0) {
                        ForEach(recents, id: \.id) { ref in
                            recentRow(ref)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 150)
        }
        .scrollIndicators(.hidden)
        .background(WL.black.ignoresSafeArea())
        .foregroundStyle(WL.cream)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var hero: some View {
        Button { openSong(featured.id) } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [featured.mesh[0], featured.mesh[4], featured.mesh[8]],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 200)
                    .overlay(
                        LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    )
                VStack(alignment: .leading, spacing: 8) {
                    MonoLabel("Latest · \(featured.versionLabel)", color: .white.opacity(0.8), size: 9, tracking: 1.8)
                    Text(store.displayTitle(featured.id, featured.title))
                        .font(WL.display(30)).foregroundStyle(.white)
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
                .padding(20)
            }
        }
        .buttonStyle(.plain)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                MonoLabel(title, color: WL.pencil, size: 11, tracking: 2)
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
                Text(store.displayTitle(t.id, t.title)).font(WL.display(17)).foregroundStyle(WL.cream)
                MonoLabel("\(t.artist) · \(t.versionLabel)", color: WL.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            if showOpen, store.openCount(t.id) > 0 {
                MonoLabel("\(store.openCount(t.id)) open", color: WL.redline, size: 9, tracking: 1)
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
        for (i, rm) in SampleData.rooms.enumerated() {
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
            case .room: return "Project · \(SampleData.rooms.first { $0.id == ref.targetID }?.artist ?? "")"
            case .song: return "Song"
            }
        }()
        let row = HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [cover.mesh[0], cover.mesh[4], cover.mesh[8]],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(pinnedTitle(ref, store)).font(WL.display(17)).foregroundStyle(WL.cream)
                MonoLabel(sub, color: WL.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(WL.pencil)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())

        Group {
            switch ref.kind {
            case .playlist:
                if let pl = store.playlist(ref.targetID) { NavigationLink(value: pl) { row }.buttonStyle(.plain) } else { row }
            case .room:
                if let rm = SampleData.rooms.first(where: { $0.id == ref.targetID }) { NavigationLink(value: rm) { row }.buttonStyle(.plain) } else { row }
            case .song:
                Button { openSong(ref.targetID) } label: { row }.buttonStyle(.plain)
            }
        }
        .pinMenu(store, ref)
    }

    @ViewBuilder private func pinCard(_ ref: PinRef) -> some View {
        let cover = pinnedCover(ref, store) ?? featured
        let card = VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [cover.mesh[0], cover.mesh[4], cover.mesh[8]],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 124, height: 124)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "pin.fill").font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.85)).padding(8)
                }
            Text(pinnedTitle(ref, store)).font(WL.display(15)).foregroundStyle(WL.cream)
                .lineLimit(1).frame(width: 124, alignment: .leading)
            MonoLabel(ref.kind.rawValue, color: WL.pencil, size: 8, tracking: 1.4)
        }
        .frame(width: 124)

        Group {
            switch ref.kind {
            case .song:
                Button { openSong(ref.targetID) } label: { card }.buttonStyle(.plain)
            case .playlist:
                if let pl = store.playlist(ref.targetID) {
                    NavigationLink(value: pl) { card }.buttonStyle(.plain)
                } else { card }
            case .room:
                if let rm = SampleData.rooms.first(where: { $0.id == ref.targetID }) {
                    NavigationLink(value: rm) { card }.buttonStyle(.plain)
                } else { card }
            }
        }
        .pinMenu(store, ref)
    }

    private func playlistCard(_ pl: Playlist) -> some View {
        let cover = pl.trackIDs.compactMap { SampleData.track($0) }.first ?? featured
        return VStack(alignment: .leading, spacing: 9) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [cover.mesh[0], cover.mesh[4], cover.mesh[8]],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 150, height: 150)
            Text(pl.title).font(WL.display(16)).foregroundStyle(WL.cream).lineLimit(1)
            MonoLabel("\(pl.trackIDs.count) tracks", color: WL.pencil, size: 9, tracking: 1.2)
        }
        .frame(width: 150)
    }

    private func roomRow(_ rm: Room) -> some View {
        HStack(spacing: 13) {
            let cover = rm.trackIDs.compactMap { SampleData.track($0) }.first ?? featured
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [cover.mesh[0], cover.mesh[4], cover.mesh[8]],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(rm.title).font(WL.display(17)).foregroundStyle(WL.cream)
                MonoLabel("\(rm.artist) · \(rm.trackIDs.count) songs", color: WL.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(WL.pencil)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())
    }

    private func swatch(_ t: Track, _ s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: [t.mesh[0], t.mesh[4], t.mesh[8]],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: s, height: s)
    }
}
