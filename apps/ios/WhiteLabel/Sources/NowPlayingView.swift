import SwiftUI

/// The core heart — Now Playing. Full-bleed living gradient, big Univers title
/// pinned high, a label/credits block, the scrubber, and the jog wheel.
struct NowPlayingView: View {
    @Bindable var player: Player
    private var track: Track { player.track }

    var body: some View {
        ZStack {
            WL.black.ignoresSafeArea()

            MeshCover(colors: track.mesh)
                .overlay(legibilityScrim)
                .ignoresSafeArea()
                // re-render the gradient when the track changes
                .id(track.id)

            VStack(alignment: .leading, spacing: 0) {
                statusRow
                    .padding(.top, 4)

                titleBlock
                    .padding(.top, 34)

                Spacer(minLength: 24)

                lowerCluster
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 18)
        }
        .foregroundStyle(WL.cream)
        .preferredColorScheme(.dark)
    }

    // MARK: status bar

    private var statusRow: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack {
                Circle()
                    .strokeBorder(WL.cream.opacity(0.7), lineWidth: 1.2)
                    .frame(width: 17, height: 17)
                    .overlay(Circle().fill(WL.cream.opacity(0.7)).frame(width: 4, height: 4))
                Text(ctx.date.formatted(.dateTime.hour().minute()))
                    .font(WL.mono(12)).tracking(1)
                Spacer()
                MonoLabel(ctx.date.formatted(.dateTime.day().month(.twoDigits).year()),
                          color: WL.cream.opacity(0.6), size: 10, tracking: 1.4)
            }
            .foregroundStyle(WL.cream.opacity(0.85))
        }
        .frame(height: 20)
    }

    // MARK: title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            MonoLabel("Now Playing · \(track.versionLabel)",
                      color: WL.cream.opacity(0.7), size: 10, tracking: 2.0)
            Text(track.title)
                .font(WL.display(46))
                .tracking(0)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            Text(track.artist)
                .font(WL.mono(12)).tracking(2)
                .foregroundStyle(WL.cream.opacity(0.8))
        }
    }

    // MARK: label + credits + scrubber + wheel

    private var lowerCluster: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.label)
                        .font(WL.display(17))
                        .foregroundStyle(WL.cream.opacity(0.92))
                    MonoLabel(track.catalog, color: WL.cream.opacity(0.55), size: 9, tracking: 1.4)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(track.credits) { c in
                        VStack(alignment: .trailing, spacing: 1) {
                            MonoLabel(c.key, color: WL.cream.opacity(0.45), size: 8, tracking: 1.2)
                            Text(c.value)
                                .font(WL.mono(10)).tracking(0.4)
                                .foregroundStyle(WL.cream.opacity(0.8))
                        }
                    }
                }
                .frame(maxWidth: 150, alignment: .trailing)
            }

            scrubber

            JogWheel(
                progress: player.progress,
                isPlaying: player.isPlaying,
                onToggle: { player.toggle() },
                onScrub: { player.seek(to: $0) }
            )
            .frame(width: 168, height: 168)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
    }

    private var scrubber: some View {
        HStack(spacing: 12) {
            Text(player.positionMs.clock)
                .font(WL.mono(11)).foregroundStyle(WL.cream.opacity(0.7))
                .monospacedDigit()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(WL.cream.opacity(0.18)).frame(height: 3)
                    Capsule().fill(WL.cream).frame(width: g.size.width * player.progress, height: 3)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { v in
                        player.seek(to: v.location.x / g.size.width)
                    }
                )
            }
            .frame(height: 16)
            Text(track.durationMs.clock)
                .font(WL.mono(11)).foregroundStyle(WL.cream.opacity(0.7))
                .monospacedDigit()
        }
    }

    private var legibilityScrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.28), .clear, .clear, .black.opacity(0.42)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
