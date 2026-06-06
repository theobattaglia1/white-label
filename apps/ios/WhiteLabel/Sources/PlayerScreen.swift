import SwiftUI

/// Two stacked full-height pages: Now Playing on top, the workspace directly
/// beneath. Swipe up and the whole player slides up to reveal the workspace;
/// it snaps page-to-page. Tapping either handle jumps between them.
struct PlayerScreen: View {
    var player: Player
    var workspace: WorkspaceStore

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
                            NowPlayingView(player: player, safeTop: top, safeBottom: bottom) {
                                withAnimation(.easeInOut(duration: 0.45)) {
                                    proxy.scrollTo("workspace", anchor: .top)
                                }
                            }
                            .frame(height: fullHeight)
                            .id("nowplaying")

                            WorkspacePage(player: player, store: workspace, safeTop: top, safeBottom: bottom) {
                                withAnimation(.easeInOut(duration: 0.45)) {
                                    proxy.scrollTo("nowplaying", anchor: .top)
                                }
                            }
                            .frame(height: fullHeight)
                            .id("workspace")
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .ignoresSafeArea()
                    .onAppear {
                        // Debug hook: launch with -openWorkspace to land on the workspace page.
                        if CommandLine.arguments.contains("-openWorkspace") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                proxy.scrollTo("workspace", anchor: .top)
                            }
                        }
                    }
                }
            }
        }
    }
}
