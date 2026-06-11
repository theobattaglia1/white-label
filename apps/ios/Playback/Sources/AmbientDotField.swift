import SwiftUI

/// Ambient dot field — the app's living background.
///
/// A regular grid of small cream dots on near-black. Each dot's radius and
/// opacity are driven by a sum of offset sine waves so no two columns are
/// ever in phase — the field reads as one continuous slow pressure-wave
/// moving through the screen, like sound moving through air.
///
/// The field is always alive; playback position only adds a subtle phase shift
/// while music is moving.
struct AmbientDotField: View {
    var isPlaying: Bool = false
    var positionMs: Int = 0        // drives playback-coupled phase
    @AppStorage("wl.reduceMotion") private var reduceMotion = false

    // Grid geometry
    private let spacing: CGFloat = 22   // pt between dot centres
    private let baseRadius: CGFloat = 1.4
    private let peakRadius: CGFloat = 3.2

    // Opacity range — barely there; only the wave crest lights dots
    private let baseOpacity: Double = 0.0
    private let peakOpacity: Double = 0.16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate
            // Playback phase — loosely ties wave to position without being
            // mechanical. Scale very small so it shifts, not drives.
            let playPhase = Double(positionMs) / 1000.0 * 0.06
            let amp: Double = 1.0

            let dotColor = Color(red: 0.953, green: 0.925, blue: 0.871)
            let rRange = peakRadius - baseRadius
            let oRange = peakOpacity - baseOpacity

            Canvas { context, size in
                let cols = Int(size.width  / spacing) + 2
                let rows = Int(size.height / spacing) + 2

                for row in 0..<rows {
                    for col in 0..<cols {
                        let cx = CGFloat(col) * spacing
                        let cy = CGFloat(row) * spacing
                        let x = Double(col)
                        let y = Double(row)

                        // Wave that travels diagonally across the screen.
                        // Product of two slow sine planes = localized crest
                        // that moves without repeating. Cube it so the valley
                        // stays invisible and only the peak lights dots.
                        let w1: Double = Foundation.sin(x * 0.28 + y * 0.19 + t * 0.31 + playPhase)
                        let w2: Double = Foundation.cos(x * 0.15 + y * 0.32 + t * 0.24)
                        let raw: Double = w1 * w2  // −1…1; rarely near 1
                        let clamped: Double = Swift.max(0.0, raw)    // kill valleys
                        let norm: Double = Swift.min(1.0, clamped * clamped * amp)

                        // Valleys are invisible — skip their path fills entirely
                        // (cuts the per-frame fill count by ~3-4x).
                        if norm < 0.02 { continue }
                        let r = CGFloat(baseRadius + norm * rRange)
                        let opacity = baseOpacity + norm * oRange

                        let dot = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                        context.fill(dot, with: .color(dotColor.opacity(opacity)))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Hosts the dot field and observes the player in its own body, so the
/// 50ms position ticks invalidate only this lightweight view — never the
/// whole screen that embeds it as a background.
struct AmbientPlayerBackdrop: View {
    var player: Player

    var body: some View {
        AmbientDotField(isPlaying: player.isPlaying, positionMs: player.positionMs)
    }
}

#Preview {
    ZStack {
        Color(hex: 0x0C0907).ignoresSafeArea()
        AmbientDotField(isPlaying: true, positionMs: 45_000)
    }
}
