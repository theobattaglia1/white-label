import SwiftUI

enum AppTab: String, CaseIterable { case home, library, inbox, profile }

/// App shell: a bottom nav (Home / Library / Inbox), a persistent mini-player,
/// and the full player presented over everything.
struct AppShell: View {
    @State private var player = Player(queue: SampleData.tracks)
    @State private var workspace = WorkspaceStore()
    @State private var tab: AppTab = .home
    @State private var showPlayer = false
    @State private var libPath = NavigationPath()

    private func openSong(_ id: String) {
        player.open(id)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { showPlayer = true }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            WL.black.ignoresSafeArea()

            Group {
                switch tab {
                case .home:
                    NavigationStack {
                        HomeView(player: player, store: workspace, openSong: openSong)
                            .navDestinations(player: player, store: workspace, openSong: openSong)
                    }
                case .library:
                    NavigationStack(path: $libPath) {
                        LibraryView(player: player, store: workspace, openSong: openSong,
                                    onDropOnSong: { dropped, target in
                                        let pl = workspace.createPlaylist(trackIDs: [target, dropped])
                                        libPath.append(pl)
                                    })
                            .navDestinations(player: player, store: workspace, openSong: openSong)
                    }
                case .inbox:
                    NavigationStack {
                        InboxView(player: player, store: workspace, openSong: openSong)
                            .navDestinations(player: player, store: workspace, openSong: openSong)
                    }
                case .profile:
                    NavigationStack { ProfileView() }
                }
            }
            .tint(WL.cobalt)

            VStack(spacing: 0) {
                if player.started && !showPlayer {
                    MiniPlayerBar(player: player, store: workspace) {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { showPlayer = true }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                TabBar(tab: $tab, inboxNew: SampleData.inbox.filter { $0.isNew }.count)
            }

            if showPlayer {
                PlayerScreen(player: player, workspace: workspace) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { showPlayer = false }
                }
                .transition(.move(edge: .bottom))
                .zIndex(2)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear {
            if CommandLine.arguments.contains("-openPlayer") { openSong("first-night") }
            if CommandLine.arguments.contains("-mini") { player.open("duel") }
            if CommandLine.arguments.contains("-playlist") { tab = .library; libPath.append(workspace.playlists[0]) }
            if CommandLine.arguments.contains("-draft") {
                tab = .library
                let pl = workspace.createPlaylist(trackIDs: ["first-night", "duel"])
                libPath.append(pl)
            }
            if CommandLine.arguments.contains("-seedpins") {
                ["song:first-night", "playlist:pl-friday", "room:rm-hudson"].forEach {
                    if !workspace.isPinned($0) { workspace.togglePin($0) }
                }
            }
            if let i = CommandLine.arguments.firstIndex(of: "-tab"),
               i + 1 < CommandLine.arguments.count,
               let t = AppTab(rawValue: CommandLine.arguments[i + 1]) { tab = t }
        }
    }
}

extension View {
    /// Shared detail destinations for playlists and rooms.
    func navDestinations(player: Player, store: WorkspaceStore, openSong: @escaping (String) -> Void) -> some View {
        self
            .navigationDestination(for: Playlist.self) { pl in
                PlaylistDetailView(playlist: pl, player: player, store: store, openSong: openSong)
            }
            .navigationDestination(for: Room.self) { rm in
                RoomDetailView(room: rm, player: player, store: store, openSong: openSong)
            }
    }
}

// MARK: - Mini player

struct MiniPlayerBar: View {
    @Bindable var player: Player
    var store: WorkspaceStore
    var onTap: () -> Void

    var body: some View {
        let t = player.track
        VStack(spacing: 0) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.12))
                    Rectangle().fill(WL.cream).frame(width: g.size.width * player.progress)
                }
            }
            .frame(height: 1.5)

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [t.mesh[0], t.mesh[4], t.mesh[8]],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.displayTitle(t.id, t.title)).font(WL.display(15)).foregroundStyle(WL.cream).lineLimit(1)
                    MonoLabel(t.artist, color: WL.pencil, size: 9, tracking: 1.2)
                }
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16)).foregroundStyle(WL.cream)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - Tab bar

struct TabBar: View {
    @Binding var tab: AppTab
    var inboxNew: Int

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            item(.home, "house.fill", "Home")
            item(.library, "square.stack.3d.up.fill", "Library")
            item(.inbox, "tray.fill", "Inbox", badge: inboxNew)
            item(.profile, "person.fill", "Profile")
        }
        .padding(.top, 11)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    private func item(_ t: AppTab, _ icon: String, _ label: String, badge: Int = 0) -> some View {
        Button { tab = t } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon).font(.system(size: 18))
                    if badge > 0 {
                        Circle().fill(WL.redline).frame(width: 7, height: 7).offset(x: 6, y: -2)
                    }
                }
                .frame(height: 20)
                Text(label.uppercased()).font(WL.mono(8)).tracking(1.4)
            }
            .foregroundStyle(tab == t ? WL.cream : WL.pencil)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
