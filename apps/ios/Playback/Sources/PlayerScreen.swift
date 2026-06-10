import SwiftUI

/// The player: Now Playing on top, workspace beneath (swipe up). A floating
/// menu button persists top-left; swipe down hard (or tap the top grabber) to
/// exit back to where you came from.
struct PlayerScreen: View {
    var player: Player
    var workspace: WorkspaceStore
    var onExit: () -> Void

    @State private var markerMs: Int? = nil
    @State private var composeToken = 0
    @State private var showMenu = false
    @State private var didExit = false
    @State private var activePage: PlayerPage = .nowPlaying

    var body: some View {
        ZStack {
            PB.black.ignoresSafeArea()
            // Observes position ticks in its own body so the whole player
            // doesn't re-evaluate every 50ms (kept taps from registering).
            AmbientPlayerBackdrop(player: player)
                .allowsHitTesting(false).ignoresSafeArea()
            GeometryReader { geo in
                let top = geo.safeAreaInsets.top
                let bottom = geo.safeAreaInsets.bottom
                let fullHeight = geo.size.height + top + bottom
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            NowPlayingView(
                                player: player, store: workspace, safeTop: top, safeBottom: bottom,
                                onPull: { jump(proxy, "workspace") },
                                onExit: { exit() },
                                onMenu: { showMenu = true },
                                onQuickNote: {
                                    markerMs = player.positionMs
                                    composeToken += 1
                                    jump(proxy, "workspace")
                                }
                            )
                            .frame(height: fullHeight)
                            .id("nowplaying")
                            .accessibilityHidden(activePage != .nowPlaying)

                            WorkspacePage(
                                player: player, store: workspace, safeTop: top, safeBottom: bottom,
                                markerMs: $markerMs, composeToken: composeToken,
                                onCollapse: { jump(proxy, "nowplaying") }
                            )
                            .frame(minHeight: fullHeight, alignment: .top)
                            .background(PB.black)
                            .id("workspace")
                            .accessibilityHidden(activePage != .workspace)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.immediately)
                    .ignoresSafeArea()
                    // swipe down hard at the top → exit
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                        if y < -95 && !didExit { didExit = true; exit() }
                        let nextPage: PlayerPage = y > fullHeight * 0.35 ? .workspace : .nowPlaying
                        if activePage != nextPage { activePage = nextPage }
                    }
                    .onAppear {
                        if CommandLine.arguments.contains("-openWorkspace") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { jump(proxy, "workspace") }
                        }
                        if CommandLine.arguments.contains("-openMenu") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showMenu = true }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showMenu) {
            MenuSheet(player: player, store: workspace)
        }
    }

    private func jump(_ proxy: ScrollViewProxy, _ id: String) {
        activePage = id == "workspace" ? .workspace : .nowPlaying
        withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(id, anchor: .top) }
    }

    private func exit() {
        onExit()
    }
}

private enum PlayerPage {
    case nowPlaying
    case workspace
}
