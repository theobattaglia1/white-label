import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Old-school hardware transport: raised dot-matrix keys that press in.
/// Symbols are drawn as dot grids (the media glyphs aren't in the Ndot font)
/// so they read in the same dotted language as the rest of the system.
struct TransportBar: View {
    var isPlaying: Bool
    var onBack: () -> Void
    var onPlay: () -> Void
    var onPause: () -> Void
    var onForward: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            key(.back, WL.paleCobalt, onBack)
            key(.play, WL.cream, onPlay)
            key(.pause, WL.paleCoral, onPause)
            key(.forward, WL.paleGreen, onForward)
        }
        .frame(maxWidth: .infinity)
    }

    private func key(_ glyph: DotGlyphKind, _ fill: Color, _ action: @escaping () -> Void) -> some View {
        Button {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            #endif
            action()
        } label: {
            DotGlyph(kind: glyph)
        }
        .buttonStyle(RaisedKeyStyle(fill: fill))
    }
}

// MARK: - Raised key

/// A physical key: raised (soft drop + light top edge) at rest, recessed
/// (inner shadow + slight shrink) while pressed.
private struct RaisedKeyStyle: ButtonStyle {
    var fill: Color
    var side: CGFloat = 58

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return configuration.label
            .frame(width: side, height: side)
            .background {
                if pressed {
                    shape.fill(
                        fill.shadow(.inner(color: .black.opacity(0.45), radius: 5, x: 0, y: 3))
                            .shadow(.inner(color: .white.opacity(0.20), radius: 3, x: 0, y: -2))
                    )
                } else {
                    shape
                        .fill(fill.shadow(.drop(color: .black.opacity(0.40), radius: 7, x: 1, y: 6)))
                        .overlay(
                            shape.strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.04)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 1
                            )
                        )
                }
            }
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.spring(response: 0.16, dampingFraction: 0.6), value: pressed)
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
    var color: Color = WL.black
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
