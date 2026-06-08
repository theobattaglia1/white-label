import SwiftUI

enum AppTab: String, CaseIterable { case home, library, explore, inbox, profile }

private struct IncomingAudioImport: Identifiable {
    let id = UUID()
    let url: URL
    let deleteAfterImport: Bool
}

/// App shell: a bottom nav, a persistent mini-player,
/// and the full player presented over everything.
struct AppShell: View {
    @State private var player = Player(queue: SampleData.tracks)
    @State private var workspace = WorkspaceStore()
    @State private var auth = PlaybackAuthSession.shared
    @State private var tab: AppTab = .home
    @State private var showPlayer = false
    @State private var libPath = NavigationPath()
    @State private var incomingAudio: IncomingAudioImport?

    private let importableAudioExtensions: Set<String> = [
        "aac", "aif", "aiff", "caf", "flac", "m4a", "mp3", "wav"
    ]

    private func openSong(_ id: String) {
        openSong(id, in: workspace.tracks)
    }

    private func openSong(_ id: String, in queue: [Track]) {
        player.replaceQueue(queue.isEmpty ? workspace.tracks : queue)
        player.open(id)
        workspace.touch(PinRef(kind: .song, targetID: id).id)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { showPlayer = true }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            PB.black.ignoresSafeArea()

            Group {
                switch tab {
                case .home:
                    NavigationStack {
                        HomeView(player: player, store: workspace, openSong: openSong)
                            .navDestinations(player: player, store: workspace, openSong: openSong) { id, queue in
                                openSong(id, in: queue)
                            }
                    }
                case .library:
                    NavigationStack(path: $libPath) {
                        LibraryView(player: player, store: workspace, openSong: openSong,
                                    onDropOnSong: { dropped, target in
                                        let pl = workspace.createPlaylist(trackIDs: [target, dropped])
                                        libPath.append(pl)
                                    },
                                    onOpenPlaylist: { playlist in
                                        libPath.append(playlist)
                                    })
                            .navDestinations(player: player, store: workspace, openSong: openSong) { id, queue in
                                openSong(id, in: queue)
                            }
                    }
                case .explore:
                    NavigationStack {
                        ExploreView(player: player, store: workspace, openSong: openSong) { id, queue in
                            openSong(id, in: queue)
                        }
                        .navDestinations(player: player, store: workspace, openSong: openSong) { id, queue in
                            openSong(id, in: queue)
                        }
                    }
                case .inbox:
                    NavigationStack {
                        InboxView(player: player, store: workspace, openSong: openSong)
                            .navDestinations(player: player, store: workspace, openSong: openSong) { id, queue in
                                openSong(id, in: queue)
                            }
                    }
                case .profile:
                    NavigationStack { ProfileView(player: player, store: workspace, auth: auth) }
                }
            }
            .tint(PB.cobalt)
            .accessibilityHidden(showPlayer)

            VStack(spacing: 0) {
                if player.started && !showPlayer {
                    MiniPlayerBar(player: player, store: workspace) {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { showPlayer = true }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                TabBar(tab: $tab, inboxNew: workspace.inboxNewCount)
            }
            .accessibilityHidden(showPlayer)

            if showPlayer {
                PlayerScreen(player: player, workspace: workspace) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { showPlayer = false }
                }
                .transition(.move(edge: .bottom))
                .zIndex(2)
            }

            if Config.useRealAuth && !auth.isSignedIn {
                SignInView(auth: auth)
                    .transition(.opacity)
                    .zIndex(5)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .sheet(item: $incomingAudio) { item in
            AddSongSheet(
                store: workspace,
                player: player,
                initialAudioURL: item.url,
                deleteInitialAudioAfterImport: item.deleteAfterImport
            )
        }
        .onOpenURL { url in
            handleIncomingAudioURL(url)
        }
        .onAppear {
            player.replaceQueue(workspace.tracks)
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
        .task {
            if Config.useRealAuth {
                await auth.bootstrap()
                guard auth.isSignedIn else { return }
            }
            await workspace.refreshFromService()
            player.replaceQueue(workspace.tracks)
        }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            guard Config.useRealAuth, signedIn else { return }
            Task {
                await auth.refreshProfile()
                await workspace.refreshFromService()
                player.replaceQueue(workspace.tracks)
            }
        }
        .onChange(of: auth.activeWorkspaceID) { _, _ in
            guard Config.useRealAuth, auth.isSignedIn else { return }
            Task {
                await workspace.refreshFromService()
                player.replaceQueue(workspace.tracks)
            }
        }
    }

    private func handleIncomingAudioURL(_ url: URL) {
        if url.scheme == "playback" {
            handlePlaybackURL(url)
            return
        }

        let ext = url.pathExtension.lowercased()
        guard url.isFileURL, importableAudioExtensions.contains(ext) else { return }
        showPlayer = false
        tab = .library
        incomingAudio = IncomingAudioImport(url: url, deleteAfterImport: false)
    }

    private func handlePlaybackURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "import-audio",
              let fileName = components.queryItems?.first(where: { $0.name == "file" })?.value
        else { return }
        let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Config.appGroupIdentifier) else { return }
        let incomingURL = container
            .appendingPathComponent("IncomingAudio", isDirectory: true)
            .appendingPathComponent(safeFileName)
        guard FileManager.default.fileExists(atPath: incomingURL.path) else { return }
        showPlayer = false
        tab = .library
        incomingAudio = IncomingAudioImport(url: incomingURL, deleteAfterImport: true)
    }
}

extension View {
    /// Shared detail destinations for playlists and rooms.
    func navDestinations(
        player: Player,
        store: WorkspaceStore,
        openSong: @escaping (String) -> Void,
        openQueue: @escaping (String, [Track]) -> Void
    ) -> some View {
        self
            .navigationDestination(for: Playlist.self) { pl in
                PlaylistDetailView(playlist: pl, player: player, store: store, openSong: openSong, openQueue: openQueue)
            }
            .navigationDestination(for: Room.self) { rm in
                RoomDetailView(room: rm, player: player, store: store, openSong: openSong, openQueue: openQueue)
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
                    Rectangle().fill(PB.cream).frame(width: g.size.width * player.progress)
                }
            }
            .frame(height: 1.5)

            HStack(spacing: 12) {
                TrackArtwork(track: t, cornerRadius: 6)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.displayTitle(t.id, t.title)).font(PB.display(15)).foregroundStyle(PB.cream).lineLimit(1)
                    MonoLabel(t.artist, color: PB.pencil, size: 9, tracking: 1.2)
                }
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16)).foregroundStyle(PB.cream)
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
            item(.explore, "magnifyingglass", "Explore")
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
                        Circle().fill(PB.redline).frame(width: 7, height: 7).offset(x: 6, y: -2)
                    }
                }
                .frame(height: 20)
                Text(label.uppercased()).font(PB.mono(8)).tracking(1.4)
            }
            .foregroundStyle(tab == t ? PB.cream : PB.pencil)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
