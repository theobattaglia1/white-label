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

                if !needsEar.isEmpty {
                    section("Needs your ear") {
                        VStack(spacing: 0) {
                            ForEach(needsEar) { t in
                                Button { openSong(t.id) } label: { trackRow(t, showOpen: true) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }

                section("Playlists") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(SampleData.playlists) { pl in
                                NavigationLink(value: pl) { playlistCard(pl) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }

                section("Projects") {
                    VStack(spacing: 0) {
                        ForEach(SampleData.rooms) { rm in
                            NavigationLink(value: rm) { roomRow(rm) }
                                .buttonStyle(.plain)
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
