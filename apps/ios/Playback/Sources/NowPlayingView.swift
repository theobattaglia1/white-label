import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Now Playing — the screen is a registered print.
/// The 1×1 art is a frame seated on the page: inset 32pt each side,
/// hairline keyline, registration seam below, caption block, controls.
/// The background is transparent — AmbientDotField in AppShell shows through.
struct NowPlayingView: View {
    @Bindable var player: Player
    var store: WorkspaceStore
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0
    var onPull: () -> Void = {}
    var onExit: () -> Void = {}
    var onMenu: () -> Void = {}
    var onQuickNote: () -> Void = {}
    private var track: Track { player.track }

    private let horizontalMargin: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            let frameWidth = geo.size.width - horizontalMargin * 2
            VStack(alignment: .leading, spacing: 0) {
                statusRow
                    .padding(.top, safeTop + 6)
                    .padding(.horizontal, horizontalMargin)

                Spacer(minLength: 20)

                artFrame(size: frameWidth)
                    .padding(.horizontal, horizontalMargin)

                registrationSeam
                    .padding(.horizontal, horizontalMargin)
                    .padding(.top, 10)

                captionBlock
                    .padding(.horizontal, horizontalMargin)
                    .padding(.top, 14)

                Spacer(minLength: 20)

                ScrubberRow(player: player)
                    .padding(.horizontal, horizontalMargin)

                TransportBar(
                    isPlaying: player.isPlaying,
                    onBack:    { player.prev() },
                    onToggle:  { player.toggle() },
                    onForward: { player.next() },
                    onNote:    { onQuickNote() }
                )
                .padding(.horizontal, horizontalMargin)
                .padding(.top, 18)

                pullHandle
                    .padding(.top, 12)
                    .padding(.bottom, safeBottom + 8)
            }
            // Dismiss chevron overlays the top-trailing corner. Its hit area
            // extends 70pt downward because the OS defers touches in the top
            // strip of a status-bar-hidden full-screen view; the lower half
            // of this frame sits in undeferred territory and catches the tap.
            .overlay(alignment: .topTrailing) {
                Button { onExit() } label: {
                    VStack(spacing: 0) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PB.cream.opacity(0.6))
                            .frame(width: 44, height: 26)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 44, height: 96, alignment: .top)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close player")
                .padding(.top, safeTop + 6)
                .padding(.trailing, horizontalMargin - 10)
            }
        }
        .foregroundStyle(PB.cream)
        .preferredColorScheme(.dark)
    }

    // MARK: - Art frame

    @ViewBuilder
    private func artFrame(size: CGFloat) -> some View {
        ZStack {
            if track.coverArt != nil || track.importedArtworkPath != nil {
                TrackArtwork(track: track, cornerRadius: 0, showsKeyline: false)
                    .scaleEffect(1.04)
                    .blur(radius: 18)
                    .opacity(0.18)
            }
            TrackArtwork(track: track, cornerRadius: 0, showsKeyline: false)
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(Rectangle().strokeBorder(PB.cream.opacity(0.18), lineWidth: 0.75))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cover art for \(store.displayTitle(track.id, track.title))")
    }

    // MARK: - Registration seam

    private var registrationSeam: some View {
        HStack(spacing: 10) {
            Rectangle().fill(PB.cream.opacity(0.15)).frame(height: 0.5)
            MonoLabel(
                "\(track.catalog)  ·  \(track.versionLabel.uppercased())",
                color: PB.cream.opacity(0.4), size: 9, tracking: 1.8
            )
        }
    }

    // MARK: - Caption block

    private var captionBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(store.displayTitle(track.id, track.title))
                .font(PB.display(34)).tracking(-0.5)
                .lineLimit(2).minimumScaleFactor(0.72)
                .foregroundStyle(PB.cream)
            HStack(spacing: 0) {
                Text("— ").font(PB.display(14)).foregroundStyle(PB.cream.opacity(0.5))
                    .accessibilityHidden(true)
                MonoLabel(
                    track.artist.uppercased()
                    + track.credits.prefix(1).map { "  ·  " + $0.value }.joined(),
                    color: PB.cream.opacity(0.5), size: 10, tracking: 1.6
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(track.artist + track.credits.prefix(1).map { ", \($0.value)" }.joined())
        }
    }

    // MARK: - Status row

    // Buttons live OUTSIDE the timeline views: rebuilding the whole row at
    // display refresh rate starved their tap recognition (inert chevron).
    private var statusRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button { onMenu() } label: {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let angle = (ctx.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 9) / 9) * 360
                    ZStack {
                        Circle().fill(PB.cream.opacity(0.92))
                        Circle().strokeBorder(PB.cream.opacity(0.25), lineWidth: 0.75)
                        Text("P").font(.custom("HelveticaNeue-Bold", size: 13))
                            .foregroundStyle(PB.black)
                    }
                    .frame(width: 26, height: 26)
                    .rotationEffect(.degrees(angle))
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open player menu")
            TimelineView(.everyMinute) { ctx in
                Text(ctx.date.formatted(.dateTime.hour().minute()))
                    .font(PB.mono(12)).tracking(1)
            }
            .accessibilityHidden(true)
            Spacer()
            // Dismiss control lives at the trailing edge — centered it sat
            // directly beneath the Dynamic Island, whose expanded hit region
            // swallowed taps (and HIG says keep controls clear of the island).
            // Honest state: device-local song — quiet dim cream, no alarm.
            if store.isLocalOnlyTrack(track.id) {
                MonoLabel("Not synced", color: PB.cream.opacity(0.45), size: 9, tracking: 1.4)
            }
            MonoLabel(
                track.versionLabel.uppercased(),
                color: PB.cream.opacity(0.6), size: 10, tracking: 1.4
            )
            // Dismiss chevron rendered as a top-trailing overlay on the main
            // VStack (see body) — leave trailing space for it here.
            Color.clear.frame(width: 36, height: 1)
        }
        .foregroundStyle(PB.cream.opacity(0.85))
        .frame(height: 26)
    }

    // MARK: - Scrubber

    /// Observes position ticks in its own body (same pattern as
    /// AmbientPlayerBackdrop): the player's 50ms position ticks invalidate
    /// only this row. When `positionMs`/`progress` were read directly in
    /// NowPlayingView's body, the entire view — status row included — was
    /// rebuilt 20×/sec, which starved tap recognition for the header buttons
    /// (the dismiss chevron never fired even though its action was correct).
    private struct ScrubberRow: View {
        var player: Player

        var body: some View {
            VStack(alignment: .leading, spacing: 7) {
                if player.audioUnavailable {
                    MonoLabel("AUDIO UNAVAILABLE", color: PB.redline, size: 9, tracking: 1.6)
                }
                HStack(spacing: 12) {
                    Text(player.positionMs.clock)
                        .font(PB.mono(10)).foregroundStyle(PB.cream.opacity(0.5)).monospacedDigit()
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(PB.cream.opacity(0.14)).frame(height: 0.75)
                            Rectangle().fill(PB.cream)
                                .frame(width: g.size.width * player.progress, height: 0.75)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            player.seek(to: v.location.x / g.size.width)
                        })
                    }
                    .frame(height: 16)
                    Text(player.durationMs.clock)
                        .font(PB.mono(10)).foregroundStyle(PB.cream.opacity(0.5)).monospacedDigit()
                }
            }
        }
    }

    // MARK: - Pull handle

    private var pullHandle: some View {
        Button { onPull() } label: {
            VStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PB.cream.opacity(0.4))
                MonoLabel("Notes & Versions", color: PB.cream.opacity(0.4), size: 9, tracking: 1.6)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open notes and versions")
    }
}
