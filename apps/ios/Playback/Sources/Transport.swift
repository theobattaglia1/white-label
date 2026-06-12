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
    var onMenu: () -> Void = {}

    private let greyFace = Color(hex: 0xD3CFC5), greyWall = Color(hex: 0x8C887D)
    private let noteFace = Color(hex: 0x6E86EC), noteWall = Color(hex: 0x3A52C4)
    private let darkInk = Color(hex: 0x33302B)

    var body: some View {
        // Two-tier hierarchy: 44pt bookends (menu / note) flank a 54pt
        // playback cluster. 10pt gaps inside the cluster, a wider 14pt gap
        // to each bookend so the trio reads as the primary unit.
        // Width: 2×44 + 3×54 + 2×10 + 2×14 = 298pt — clears the 32pt screen
        // margins on the narrowest supported phones (was 310pt at five 54s).
        HStack(spacing: 14) {
            // ⋯ — the app's context-menu affordance, rendered as a hardware
            // key so it reads as a control (the rotating P read as a logo).
            key(.menu, held: false, face: greyFace, wall: greyWall, ink: darkInk, side: 44, onMenu)
            HStack(spacing: 10) {
                key(.back, held: false, face: greyFace, wall: greyWall, ink: darkInk, onBack)
                // single play/pause toggle — pause glyph while playing, latched down
                key(isPlaying ? .pause : .play, held: isPlaying, face: greyFace, wall: greyWall, ink: darkInk, onToggle)
                key(.forward, held: false, face: greyFace, wall: greyWall, ink: darkInk, onForward)
            }
            key(.note, held: false, face: noteFace, wall: noteWall, ink: PB.cream, side: 44, onNote)
        }
        .frame(maxWidth: .infinity)
    }

    // `side` is the visual key diameter; never pass below 44 — that is the
    // minimum hit target and the visual circle is also the tappable area.
    private func key(_ glyph: DotGlyphKind, held: Bool, face: Color, wall: Color, ink: Color, side: CGFloat = 54, _ action: @escaping () -> Void) -> some View {
        Button {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            #endif
            action()
        } label: {
            DotGlyph(kind: glyph, color: ink)
        }
        .buttonStyle(FlatKeyStyle(face: face, wall: wall, held: held, side: side))
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
        // full square hit target — keeps ≥44pt tappable even on the smaller
        // 44pt bookend keys (HIG minimum)
        .contentShape(Rectangle())
        // even, top-down shadow when raised; none when recessed
        .shadow(color: .black.opacity(down ? 0 : 0.22), radius: down ? 0 : 5, x: 0, y: 0)
        // push-in; momentary keys bounce back on release, latched keys settle in
        .scaleEffect(down ? 0.92 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.5), value: down)
    }
}

// MARK: - Dot-matrix glyphs

enum DotGlyphKind {
    case play, pause, back, forward, note, menu
    var accessibilityLabel: String {
        switch self {
        case .play: return "Play"
        case .pause: return "Pause"
        case .back: return "Previous track"
        case .forward: return "Next track"
        case .note: return "Add note"
        case .menu: return "More actions"
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
        // ⋯ — three fat dots, the established "more actions" glyph
        case .menu:    return ["XX.XX.XX",
                               "XX.XX.XX"]
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
