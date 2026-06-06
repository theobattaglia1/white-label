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
                    .padding(.top, 6)

                titleBlock
                    .padding(.top, 48)

                Spacer(minLength: 24)

                lowerCluster
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
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
        VStack(alignment: .leading, spacing: 1) {
            Text(track.title)
                .foregroundStyle(WL.cream)
            Text("— \(track.artist)")
                .foregroundStyle(WL.cream.opacity(0.9))
        }
        .font(WL.display(52))
        .tracking(0)
        .lineLimit(1)
        .minimumScaleFactor(0.55)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
    }

    // MARK: label + credits + scrubber + wheel

    private var lowerCluster: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(track.label)
                        .font(WL.display(18))
                        .foregroundStyle(WL.cream.opacity(0.92))
                    MonoLabel(track.catalog, color: WL.cream.opacity(0.5), size: 9, tracking: 1.4)
                }
                Spacer()
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .trailing, spacing: 4) {
                        MonoLabel(track.versionLabel, color: WL.cream.opacity(0.6), size: 9, tracking: 1.4)
                        ForEach(track.credits.prefix(2)) { c in
                            Text(c.value)
                                .font(WL.mono(10)).tracking(0.3)
                                .foregroundStyle(WL.cream.opacity(0.7))
                        }
                    }
                    Image(systemName: "triangle")
                        .font(.system(size: 10, weight: .light))
                        .rotationEffect(.degrees(90))
                        .foregroundStyle(WL.cream.opacity(0.5))
                        .padding(.bottom, 1)
                }
            }

            scrubber

            JogWheel(
                progress: player.progress,
                isPlaying: player.isPlaying,
                onToggle: { player.toggle() },
                onScrub: { player.seek(to: $0) }
            )
            .frame(width: 172, height: 172)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
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
