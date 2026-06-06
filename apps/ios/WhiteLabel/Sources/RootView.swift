import SwiftUI

/// App root: Home/Library as the base, with the player presented over it as a
/// layer that slides up (tap a track) and down (exit).
struct RootView: View {
    @State private var player = Player(queue: SampleData.tracks)
    @State private var workspace = WorkspaceStore()
    @State private var showPlayer = false

    var body: some View {
        ZStack {
            HomeView(player: player, store: workspace) { index in
                player.index = index
                player.positionMs = 0
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { showPlayer = true }
            }

            if showPlayer {
                PlayerScreen(player: player, workspace: workspace) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { showPlayer = false }
                }
                .transition(.move(edge: .bottom))
                .zIndex(1)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear {
            if CommandLine.arguments.contains("-openPlayer") { showPlayer = true }
        }
    }
}
