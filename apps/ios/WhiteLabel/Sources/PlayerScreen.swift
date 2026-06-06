import SwiftUI

/// Two stacked full-height pages: Now Playing on top, the workspace directly
/// beneath. Swipe up and the whole player slides up to reveal the workspace;
/// it snaps page-to-page. Tapping either handle jumps between them.
struct PlayerScreen: View {
    var player: Player
    var workspace: WorkspaceStore
    @State private var markerMs: Int? = nil
    @State private var composeToken = 0

    var body: some View {
        ZStack {
            WL.black.ignoresSafeArea()
            GeometryReader { geo in
                let top = geo.safeAreaInsets.top
                let bottom = geo.safeAreaInsets.bottom
                let fullHeight = geo.size.height + top + bottom
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            NowPlayingView(
                                player: player, safeTop: top, safeBottom: bottom,
                                onPull: { jump(proxy, "workspace") },
                                onQuickNote: {
                                    markerMs = player.positionMs
                                    composeToken += 1
                                    jump(proxy, "workspace")
                                }
                            )
                            .frame(height: fullHeight)
                            .id("nowplaying")

                            WorkspacePage(
                                player: player, store: workspace, safeTop: top, safeBottom: bottom,
                                markerMs: $markerMs, composeToken: composeToken,
                                onCollapse: { jump(proxy, "nowplaying") }
                            )
                            .frame(minHeight: fullHeight, alignment: .top)
                            .background(WL.black)
                            .id("workspace")
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.immediately)
                    .ignoresSafeArea()
                    .onAppear {
                        if CommandLine.arguments.contains("-openWorkspace") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                jump(proxy, "workspace")
                            }
                        }
                    }
                }
            }
        }
    }

    private func jump(_ proxy: ScrollViewProxy, _ id: String) {
        withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(id, anchor: .top) }
    }
}
