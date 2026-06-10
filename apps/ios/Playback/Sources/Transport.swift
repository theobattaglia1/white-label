import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Old-school hardware transport: round keys with a flat top and a sharp,
/// extruded side-wall. They sit raised and drop flush when pressed. Greyscale
/// dot-matrix media keys plus a cobalt quick-note key on the right.
struct TransportBar: View {
    var isPlaying: Bool
    var onBack: () -> Void
    var onToggle: () -> Void
    var onForward: () -> Void
    var onNote: () -> Void

    private let greyFace = Color(hex: 0xD3CFC5), greyWall = Color(hex: 0x8C887D)
    private let noteFace = Color(hex: 0x6E86EC), noteWall = Color(hex: 0x3A52C4)
    private let darkInk = Color(hex: 0x33302B)

    var body: some View {
        HStack(spacing: 13) {
            key(.back, held: false, face: greyFace, wall: greyWall, ink: darkInk, onBack)
            // single play/pause toggle — pause glyph while playing, latched down
            key(isPlaying ? .pause : .play, held: isPlaying, face: greyFace, wall: greyWall, ink: darkInk, onToggle)
            key(.forward, held: false, face: greyFace, wall: greyWall, ink: darkInk, onForward)
            key(.note, held: false, face: noteFace, wall: noteWall, ink: PB.cream, onNote)
        }
        .frame(maxWidth: .infinity)
    }

    private func key(_ glyph: DotGlyphKind, held: Bool, face: Color, wall: Color, ink: Color, _ action: @escaping () -> Void) -> some View {
        Button {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            #endif
            action()
        } label: {
            DotGlyph(kind: glyph, color: ink)
        }
        .buttonStyle(FlatKeyStyle(face: face, wall: wall, held: held))
        .accessibilityLabel(glyph.accessibilityLabel)
    }
}

// MARK: - Flat extruded key

/// Head-on flat key. Raised at rest: a flat top with a crisp rim and an even
/// (non-directional) shadow. Pressed/held: the face recesses — an inner shadow
/// makes it read as a well punched into the screen.
private struct FlatKeyStyle: ButtonStyle {
    var face: Color
    var wall: Color   // recessed (pressed) fill — a darker shade of the face
    var held: Bool = false
    var side: CGFloat = 54

    func makeBody(configuration: Configuration) -> some View {
        let down = held || configuration.isPressed
        return ZStack {
            Circle().fill(
                down
                ? AnyShapeStyle(
                    wall
                        .shadow(.inner(color: .black.opacity(0.55), radius: 4, x: 0, y: 2))
                        .shadow(.inner(color: .white.opacity(0.10), radius: 3, x: 0, y: -2))
                  )
                : AnyShapeStyle(face)
            )
            Circle().strokeBorder(.black.opacity(0.32), lineWidth: 1)
            configuration.label
                .opacity(down ? 0.85 : 1)
        }
        .frame(width: side, height: side)
        // even, top-down shadow when raised; none when recessed
        .shadow(color: .black.opacity(down ? 0 : 0.22), radius: down ? 0 : 5, x: 0, y: 0)
        // push-in; momentary keys bounce back on release, latched keys settle in
        .scaleEffect(down ? 0.92 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.5), value: down)
    }
}

// MARK: - Dot-matrix glyphs

enum DotGlyphKind {
    case play, pause, back, forward, note
    var accessibilityLabel: String {
        switch self {
        case .play: return "Play"
        case .pause: return "Pause"
        case .back: return "Previous track"
        case .forward: return "Next track"
        case .note: return "Add note"
        }
    }

    var rows: [String] {
        switch self {
        case .play:    return ["X...", "XX..", "XXX.", "XXXX", "XXX.", "XX..", "X..."]
        case .pause:   return ["XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX", "XX.XX"]
        case .back:    return ["X....X", "X...XX", "X..XXX", "X.XXXX", "X..XXX", "X...XX", "X....X"]
        case .forward: return ["X....X", "XX...X", "XXX..X", "XXXX.X", "XXX..X", "XX...X", "X....X"]
        // a note (text lines) with a small + beside it = "add note"
        case .note:    return ["XXXXX....",
                               ".......X.",
                               "XXXXX.XXX",
                               ".......X.",
                               "XXX......"]
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
