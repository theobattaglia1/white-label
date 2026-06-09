import SwiftUI

@main
struct PlaybackApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                PB.black.ignoresSafeArea()
                AppShell()
            }
            .preferredColorScheme(.dark)
        }
    }
}
