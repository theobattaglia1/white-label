import SwiftUI

@main
struct WhiteLabelApp: App {
    @State private var player = Player(queue: SampleData.tracks)
    @State private var workspace = WorkspaceStore()

    var body: some Scene {
        WindowGroup {
            PlayerScreen(player: player, workspace: workspace)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
