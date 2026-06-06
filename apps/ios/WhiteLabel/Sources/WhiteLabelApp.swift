import SwiftUI

@main
struct WhiteLabelApp: App {
    @State private var player = Player(queue: SampleData.tracks)

    var body: some Scene {
        WindowGroup {
            NowPlayingView(player: player)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
