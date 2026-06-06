import SwiftUI

/// The living gradient cover — a slowly drifting MeshGradient that stands in for
/// generative artwork. Corners stay pinned; the inner + edge points wander on
/// gentle sine paths so the field breathes without ever looping obviously.
struct MeshCover: View {
    let colors: [Color]
    var animate: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3,
                height: 3,
                points: points(t),
                colors: colors,
                smoothsColors: true
            )
            .ignoresSafeArea()
        }
    }

    private func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        func d(_ i: Double, _ a: Double) -> Float { Float(sin(t * 0.18 + i) * a) }
        // row-major 3×3; corners fixed, edges + center drift
        return [
            SIMD2(0, 0),
            SIMD2(0.5 + d(0, 0.06), 0),
            SIMD2(1, 0),
            SIMD2(0, 0.5 + d(1, 0.06)),
            SIMD2(0.5 + d(2, 0.08), 0.5 + d(3, 0.08)),
            SIMD2(1, 0.5 + d(4, 0.06)),
            SIMD2(0, 1),
            SIMD2(0.5 + d(5, 0.06), 1),
            SIMD2(1, 1),
        ]
    }
}
