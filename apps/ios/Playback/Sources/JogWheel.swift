import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The heart of the app: a physical jog wheel. Tap the hub to play/pause;
/// drag around the rim to scrub. A machined metal disc with a recessed,
/// fine-lined center and a progress ring tracking playback.
struct JogWheel: View {
    var progress: Double
    var isPlaying: Bool
    var onToggle: () -> Void
    var onScrub: (Double) -> Void

    @State private var scrubbing = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let r = size / 2
            ZStack {
                // progress track + arc
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 2)
                    .padding(3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(PB.cream, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)

                WheelFace(isPlaying: isPlaying)
                    .padding(size * 0.13)
                    .scaleEffect(scrubbing ? 0.985 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: scrubbing)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let dx = Double(v.location.x - r)
                        let dy = Double(v.location.y - r)
                        // ignore the dead-zone hub so a tap there reads as play/pause
                        if hypot(dx, dy) < Double(size) * 0.22 { return }
                        scrubbing = true
                        var frac = atan2(dx, -dy) / (2 * .pi)
                        if frac < 0 { frac += 1 }
                        onScrub(frac)
                    }
                    .onEnded { v in
                        let dx = Double(v.location.x - r)
                        let dy = Double(v.location.y - r)
                        if !scrubbing && hypot(dx, dy) < Double(size) * 0.5 {
                            haptic(.rigid)
                            onToggle()
                        }
                        scrubbing = false
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }
}

/// The metal disc itself — machined rings around a recessed, fine-lined hub.
private struct WheelFace: View {
    var isPlaying: Bool

    var body: some View {
        ZStack {
            // brushed-metal body
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0xE9E3D4), Color(hex: 0xBFB8A8), Color(hex: 0x8E8678)],
                        center: .init(x: 0.38, y: 0.32),
                        startRadius: 2,
                        endRadius: 150
                    )
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1).blendMode(.screen))
                .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 10)

            // machined concentric rings
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let maxR = sz.width / 2
                var rr = maxR * 0.92
                while rr > maxR * 0.40 {
                    let path = Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
                    ctx.stroke(path, with: .color(.black.opacity(0.06)), lineWidth: 0.6)
                    rr -= maxR * 0.045
                }
            }

            // recessed hub with fine radial grille
            GeometryReader { g in
                let s = min(g.size.width, g.size.height)
                let hub = s * 0.46
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(hex: 0x201C16), Color(hex: 0x3A352B)],
                                center: .center, startRadius: 1, endRadius: hub
                            )
                        )
                        .frame(width: hub, height: hub)
                        .overlay(
                            Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
                                .frame(width: hub, height: hub)
                        )
                    Canvas { ctx, sz in
                        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                        let inner = hub * 0.12, outer = hub * 0.46
                        let lines = 72
                        for i in 0..<lines {
                            let a = Double(i) / Double(lines) * 2 * .pi
                            var p = Path()
                            p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                            p.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
                            ctx.stroke(p, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                        }
                    }
                    .frame(width: hub, height: hub)

                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: s * 0.10, weight: .medium))
                        .foregroundStyle(PB.cream.opacity(0.92))
                        .offset(x: isPlaying ? 0 : s * 0.012)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
    }
}
