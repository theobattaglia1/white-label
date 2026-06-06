import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The core heart — Now Playing. Full-bleed living gradient, big Univers title
/// pinned high, a label/credits block, the scrubber, and the transport. Pull up
/// to reveal the workspace (versions + timestamped notes) without leaving here.
struct NowPlayingView: View {
    @Bindable var player: Player
    var store: WorkspaceStore
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0
    var onPull: () -> Void = {}
    var onExit: () -> Void = {}
    var onQuickNote: () -> Void = {}
    private var track: Track { player.track }

    var body: some View {
        ZStack {
            WL.black

            MeshCover(colors: track.mesh)
                .overlay(legibilityScrim)
                // re-render the gradient when the track changes
                .id(track.id)

            VStack(alignment: .leading, spacing: 0) {
                statusRow
                    .padding(.top, safeTop + 6)

                titleBlock
                    .padding(.top, 64)

                Spacer(minLength: 24)

                lowerCluster

                pullHandle
                    .padding(.top, 16)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, safeBottom + 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .foregroundStyle(WL.cream)
        .preferredColorScheme(.dark)
    }

    /// Pull-up hint — the pager handles the actual swipe; a tap jumps up too.
    private var pullHandle: some View {
        VStack(spacing: 6) {
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WL.cream.opacity(0.5))
            MonoLabel("Notes & Versions", color: WL.cream.opacity(0.5), size: 9, tracking: 1.6)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onPull() }
    }

    // MARK: status bar

    private var statusRow: some View {
        // centered exit grabber — tap to leave; swipe down hard also exits
        VStack(spacing: 3) {
            Capsule().fill(WL.cream.opacity(0.32)).frame(width: 34, height: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(WL.cream.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture { onExit() }
    }

    // MARK: title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(store.displayTitle(track.id, track.title))
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

            TransportBar(
                isPlaying: player.isPlaying,
                onBack: { player.prev() },
                onPlay: { player.play() },
                onPause: { player.pause() },
                onForward: { player.next() },
                onNote: { onQuickNote() }
            )
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
    }
}
