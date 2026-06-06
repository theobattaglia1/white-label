import SwiftUI

/// Minimal home/library — the catalog you exit the player back to. Tap a track
/// to slide the player up.
struct HomeView: View {
    var player: Player
    var store: WorkspaceStore
    var onOpen: (Int) -> Void

    var body: some View {
        ZStack {
            WL.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WHITE LABEL").font(WL.mono(11)).tracking(2.5).foregroundStyle(WL.pencil)
                        Text("Library").font(WL.display(40)).foregroundStyle(WL.cream)
                    }
                    .padding(.bottom, 22)

                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { i, t in
                        Button { onOpen(i) } label: { row(t) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(WL.cream)
    }

    private func row(_ t: Track) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [t.mesh[0], t.mesh[4], t.mesh[8]],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 48, height: 48)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayTitle(t.id, t.title)).font(WL.display(18)).foregroundStyle(WL.cream)
                MonoLabel("\(t.artist) · \(t.versionLabel)", color: WL.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            if store.openCount(t.id) > 0 {
                MonoLabel("\(store.openCount(t.id))", color: WL.redline, size: 10, tracking: 1)
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.055)).frame(height: 1)
        }
        .contentShape(Rectangle())
    }
}
