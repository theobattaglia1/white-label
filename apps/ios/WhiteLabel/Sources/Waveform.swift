import SwiftUI

/// Deterministic stand-in waveform for a track (real peaks come with audio).
func wavePeaks(_ seed: String, count: Int = 72) -> [CGFloat] {
    let phase = Double(seed.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 100) * 0.13
    return (0..<count).map { i in
        let x = Double(i)
        let v = abs(sin(x * 0.5 + phase)) * 0.58
              + abs(sin(x * 0.17 + phase * 1.3)) * 0.30
              + 0.14
        return CGFloat(min(1, v))
    }
}

struct NoteMark: Identifiable {
    let id: UUID
    let fraction: Double
    let resolved: Bool
}

/// A scrubbable waveform with the live playhead, a draggable note marker, and a
/// dot for every existing note.
struct WaveStrip: View {
    var peaks: [CGFloat]
    var progress: Double            // 0…1 live playhead
    var marker: Double              // 0…1 note marker
    var noteMarks: [NoteMark] = []  // existing notes
    var onScrub: (Double) -> Void   // drag → set marker fraction

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    let n = peaks.count
                    let gap: CGFloat = 2
                    let bw = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                    for (i, p) in peaks.enumerated() {
                        let x = CGFloat(i) * (bw + gap)
                        let bh = max(2, p * size.height)
                        let y = (size.height - bh) / 2
                        let played = Double(i) / Double(n) <= progress
                        let rect = CGRect(x: x, y: y, width: bw, height: bh)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: bw / 2),
                                 with: .color(.white.opacity(played ? 0.85 : 0.26)))
                    }
                }
                // existing-note dots, along the bottom edge
                ForEach(noteMarks) { m in
                    Circle()
                        .fill(m.resolved ? WL.green : WL.redline)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(WL.black.opacity(0.4), lineWidth: 0.5))
                        .offset(x: w * m.fraction - 3, y: h / 2 - 1)
                }
                // playhead
                Rectangle().fill(.white.opacity(0.7)).frame(width: 1.5, height: h)
                    .offset(x: w * progress - 0.75)
                // note marker
                ZStack {
                    Rectangle().fill(WL.cobalt).frame(width: 2, height: h)
                    Circle().fill(WL.cobalt).frame(width: 9, height: 9).offset(y: -h / 2)
                    Circle().fill(WL.cobalt).frame(width: 9, height: 9).offset(y: h / 2)
                }
                .offset(x: w * marker - 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    onScrub(min(1, max(0, v.location.x / w)))
                }
            )
        }
    }
}
