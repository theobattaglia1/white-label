import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Old-school hardware transport: round, greyscale dot-matrix keys that press
/// in. The active mode latches down — while playing, the play key stays
/// recessed; while paused, the pause key does.
struct TransportBar: View {
    var isPlaying: Bool
    var onBack: () -> Void
    var onPlay: () -> Void
    var onPause: () -> Void
    var onForward: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            key(.back, held: false, onBack)
            key(.play, held: isPlaying, onPlay)
            key(.pause, held: !isPlaying, onPause)
            key(.forward, held: false, onForward)
        }
        .frame(maxWidth: .infinity)
    }

    private func key(_ glyph: DotGlyphKind, held: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            #endif
            action()
        } label: {
            DotGlyph(kind: glyph)
        }
        .buttonStyle(RaisedKeyStyle(held: held))
    }
}

// MARK: - Raised key

/// A round physical key: raised (domed grey + light top edge) at rest,
/// recessed (inner shadow + shrink) while pressed OR while latched `held`.
private struct RaisedKeyStyle: ButtonStyle {
    var held: Bool = false
    var side: CGFloat = 58

    func makeBody(configuration: Configuration) -> some View {
        let down = held || configuration.isPressed
        return configuration.label
            .frame(width: side, height: side)
            .background {
                if down {
                    Circle().fill(
                        LinearGradient(colors: [Color(hex: 0xAEAAA1), Color(hex: 0xC4C0B6)],
                                       startPoint: .top, endPoint: .bottom)
                            .shadow(.inner(color: .black.opacity(0.50), radius: 5, x: 0, y: 3))
                            .shadow(.inner(color: .white.opacity(0.22), radius: 2, x: 0, y: -2))
                    )
                } else {
                    Circle()
                        .fill(
                            LinearGradient(colors: [Color(hex: 0xDAD6CC), Color(hex: 0xBCB8AE)],
                                           startPoint: .top, endPoint: .bottom)
                                .shadow(.drop(color: .black.opacity(0.38), radius: 7, x: 1, y: 6))
                        )
                        .overlay(
                            Circle().strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.04)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 1
                            )
                        )
                }
            }
            .scaleEffect(down ? 0.95 : 1)
            .animation(.spring(response: 0.16, dampingFraction: 0.6), value: down)
    }
}

// MARK: - Dot-matrix glyphs

enum DotGlyphKind {
    case play, pause, back, forward
    var rows: [String] {
        switch self {
        case .play:    return ["X...", "XX..", "XXX.", "XXXX", "XXX.", "XX..", "X..."]
        case .pause:   return ["XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX"]
        case .back:    return ["X....X", "X...XX", "X..XXX", "X.XXXX", "X..XXX", "X...XX", "X....X"]
        case .forward: return ["X....X", "XX...X", "XXX..X", "XXXX.X", "XXX..X", "XX...X", "X....X"]
        }
    }
}

private struct DotGlyph: View {
    let kind: DotGlyphKind
    var color: Color = Color(hex: 0x33302B)
    var pitch: CGFloat = 3.1

    var body: some View {
        let rows = kind.rows
        let cols = rows.map(\.count).max() ?? 1
        Canvas { ctx, size in
            let cw = size.width / CGFloat(cols)
            let ch = size.height / CGFloat(rows.count)
            let r = min(cw, ch) * 0.36
            for (ri, row) in rows.enumerated() {
                for (ci, char) in row.enumerated() where char == "X" {
                    let cx = (CGFloat(ci) + 0.5) * cw
                    let cy = (CGFloat(ri) + 0.5) * ch
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                             with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(cols) * pitch, height: CGFloat(rows.count) * pitch)
    }
}
