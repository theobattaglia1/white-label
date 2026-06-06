import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Old-school hardware transport: round, greyscale dot-matrix keys that press
/// in, plus a cobalt quick-note key on the right. The active mode latches down.
struct TransportBar: View {
    var isPlaying: Bool
    var onBack: () -> Void
    var onPlay: () -> Void
    var onPause: () -> Void
    var onForward: () -> Void
    var onNote: () -> Void

    private let greyTop = Color(hex: 0xDAD6CC), greyBottom = Color(hex: 0xBCB8AE)
    private let noteTop = Color(hex: 0x8597EE), noteBottom = Color(hex: 0x556FE3)
    private let darkInk = Color(hex: 0x33302B)

    var body: some View {
        HStack(spacing: 13) {
            key(.back, held: false, top: greyTop, bottom: greyBottom, ink: darkInk, onBack)
            key(.play, held: isPlaying, top: greyTop, bottom: greyBottom, ink: darkInk, onPlay)
            key(.pause, held: !isPlaying, top: greyTop, bottom: greyBottom, ink: darkInk, onPause)
            key(.forward, held: false, top: greyTop, bottom: greyBottom, ink: darkInk, onForward)
            key(.note, held: false, top: noteTop, bottom: noteBottom, ink: WL.cream, onNote)
        }
        .frame(maxWidth: .infinity)
    }

    private func key(_ glyph: DotGlyphKind, held: Bool, top: Color, bottom: Color, ink: Color, _ action: @escaping () -> Void) -> some View {
        Button {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            #endif
            action()
        } label: {
            DotGlyph(kind: glyph, color: ink)
        }
        .buttonStyle(RaisedKeyStyle(top: top, bottom: bottom, held: held))
    }
}

// MARK: - Raised key

private struct RaisedKeyStyle: ButtonStyle {
    var top: Color
    var bottom: Color
    var held: Bool = false
    var side: CGFloat = 54

    func makeBody(configuration: Configuration) -> some View {
        let down = held || configuration.isPressed
        return configuration.label
            .frame(width: side, height: side)
            .background {
                if down {
                    Circle().fill(
                        LinearGradient(colors: [bottom, top], startPoint: .top, endPoint: .bottom)
                            .shadow(.inner(color: .black.opacity(0.50), radius: 5, x: 0, y: 3))
                            .shadow(.inner(color: .white.opacity(0.20), radius: 2, x: 0, y: -2))
                    )
                } else {
                    Circle()
                        .fill(
                            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
                                .shadow(.drop(color: .black.opacity(0.38), radius: 7, x: 1, y: 6))
                        )
                        .overlay(
                            Circle().strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.04)],
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
    case play, pause, back, forward, note
    var rows: [String] {
        switch self {
        case .play:    return ["X...", "XX..", "XXX.", "XXXX", "XXX.", "XX..", "X..."]
        case .pause:   return ["XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX"]
        case .back:    return ["X....X", "X...XX", "X..XXX", "X.XXXX", "X..XXX", "X...XX", "X....X"]
        case .forward: return ["X....X", "XX...X", "XXX..X", "XXXX.X", "XXX..X", "XX...X", "X....X"]
        case .note:    return ["..X..", "..X..", "XXXXX", "..X..", "..X.."]
        }
    }
}

private struct DotGlyph: View {
    let kind: DotGlyphKind
    var color: Color = Color(hex: 0x33302B)
    var pitch: CGFloat = 3.0

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
