import SwiftUI

// =====================================================================
// WHITE LABEL · Editorial Redline · iOS theme
// Brand-true tokens that match apps/web/src/styles.css.
// Studio mode = workspace surfaces (dark, like the producer's tape).
// Sleeve mode = recipient + share-link surfaces (cream, like an LP back).
// Old token names (canvas, paper, soft, ink, accent…) are preserved
// and re-pointed to brand colours so legacy views become brand-true
// without per-view changes; new tokens are added alongside.
// =====================================================================

// MARK: - Color helpers -------------------------------------------------

private extension UIColor {
    static func pmwAdaptive(light: UIColor, dark: UIColor) -> UIColor {
        UIColor(dynamicProvider: { $0.userInterfaceStyle == .dark ? dark : light })
    }

    static func pmwHex(_ hex: UInt32) -> UIColor {
        UIColor(
            red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8)  & 0xFF) / 255,
            blue:  CGFloat( hex        & 0xFF) / 255,
            alpha: 1
        )
    }
}

private func hex(_ value: UInt32) -> Color { Color(uiColor: .pmwHex(value)) }
private func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(uiColor: .pmwAdaptive(light: .pmwHex(light), dark: .pmwHex(dark)))
}

// MARK: - Brand tokens --------------------------------------------------

enum PMWColors {
    // ----- Studio mode (workspace, dark) -----
    static let studioBlack    = hex(0x0B0A09)
    static let studioPanel    = hex(0x15130F)
    static let studioElevated = hex(0x1B1814)
    static let studioHairline = hex(0x2A2620)
    static let tapeOxide      = hex(0xF2EDE2)
    static let pencilWarm     = hex(0x8C8473)

    // ----- Sleeve mode (recipient, cream paper) -----
    static let sleeveCream    = hex(0xF2EDE2)
    static let sleeveCard     = hex(0xFAF5E8)
    static let sleeveElevated = hex(0xFFFCF3)
    static let sleeveHairline = hex(0xC8C0AE)
    static let inkDeep        = hex(0x0B0A09)
    static let pencilCool     = hex(0x6E685D)

    // ----- Brand accents -----
    /// The single editorial red. The only red in the system.
    static let redline   = hex(0xD9281D)
    /// The single notes-blue. The only blue in the system.
    static let notesBlue = hex(0x2D5DB8)

    // ----- Back-compat aliases (old names, repointed to brand) -----
    /// Producer workspace canvas — always studio black. Producer surfaces force
    /// `.preferredColorScheme(.dark)` at the root so this stays consistent.
    /// Recipient surfaces explicitly use `sleeveCream` instead.
    static let canvas    = studioBlack
    static let paper     = studioPanel
    static let soft      = studioElevated
    static let ink       = tapeOxide
    static let muted     = pencilWarm
    static let line      = studioHairline
    static let lineStrong = pencilWarm
    static let accent    = redline
    static let accentSoft = hex(0x2A0F0D)
    static let success   = tapeOxide
    static let warning   = hex(0xBB7A16)
}

// MARK: - Per-song cover gradient ---------------------------------------

/// Derive a stable hue (0–360) from a string id so every song gets a face.
private func pmwHashHue(_ id: String) -> Int {
    var hash: UInt64 = 14695981039346656037
    for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
    return Int(hash % 360)
}

/// Build a sleeve-mode-toned gradient keyed to the song id.
/// Mirrors the web's `coverGradient(songId)` helper so iOS and web song
/// covers feel like the same object across platforms.
func pmwCoverGradient(for songId: String) -> LinearGradient {
    let hue = pmwHashHue(songId)
    let angle = 130 + (pmwHashHue(songId + "a") % 40)
    let rad = Angle.degrees(Double(angle)).radians
    let startX = 0.5 - 0.5 * cos(rad)
    let startY = 0.5 - 0.5 * sin(rad)
    let endX = 0.5 + 0.5 * cos(rad)
    let endY = 0.5 + 0.5 * sin(rad)
    return LinearGradient(
        colors: [
            Color(hue: Double((hue + 200) % 360) / 360, saturation: 0.08, brightness: 0.14),
            Color(hue: Double((hue + 30) % 360) / 360, saturation: 0.20, brightness: 0.32),
            Color(hue: Double(hue) / 360, saturation: 0.30, brightness: 0.56),
            Color(hue: Double((hue + 25) % 360) / 360, saturation: 0.42, brightness: 0.78),
        ],
        startPoint: UnitPoint(x: startX, y: startY),
        endPoint: UnitPoint(x: endX, y: endY)
    )
}

// MARK: - Spacing -------------------------------------------------------

enum PMWSpacing {
    static let micro: CGFloat = 6
    static let compact: CGFloat = 12
    static let stack: CGFloat = 20
    static let page: CGFloat = 20
    static let section: CGFloat = 28
    static let radius: CGFloat = 2 // brand prefers nearly square edges
    static let radiusCard: CGFloat = 6
}

// MARK: - Type ----------------------------------------------------------

enum PMWFont {
    /// Display — heavy condensed grotesque. The brand wordmark uses this.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .default).width(.condensed)
    }

    /// Typewriter mono — metadata, catalog ids, stamps, cues.
    static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Body sans — note text, paragraph copy.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    // ---- Back-compat ----
    static func t1(size: CGFloat) -> Font { display(size, weight: .heavy) }
    static func t2(_ weight: Font.Weight = .regular) -> Font { sans(13, weight: weight) }
    static func t3(_ weight: Font.Weight = .semibold) -> Font { mono(11, weight: weight) }
}

// MARK: - Brand primitives ---------------------------------------------

/// The "WHITE LABEL_" wordmark with the red underscore cursor. Brand chrome.
struct PMWWordmark: View {
    enum Size { case sm, md, lg, hero }
    var size: Size = .md

    private var pointSize: CGFloat {
        switch size {
        case .sm:   return 16
        case .md:   return 24
        case .lg:   return 36
        case .hero: return 64
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("WHITE LABEL")
                .font(PMWFont.display(pointSize, weight: .black))
                .kerning(-pointSize * 0.04)
                .foregroundStyle(PMWColors.ink)
            Rectangle()
                .fill(PMWColors.redline)
                .frame(width: pointSize * 0.45, height: pointSize * 0.16)
                .padding(.top, pointSize * 0.55)
        }
    }
}

/// The "WL_" monogram — used inside compact chrome.
struct PMWMonoMark: View {
    var size: CGFloat = 18
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 2) {
            Text("WL")
                .font(PMWFont.display(size, weight: .black))
                .kerning(-size * 0.02)
                .foregroundStyle(tint)
            Rectangle()
                .fill(PMWColors.redline)
                .frame(width: size * 0.42, height: size * 0.18)
                .padding(.top, size * 0.55)
        }
    }
}

/// Typewriter-style stamp tag (NOTES DUE, APPROVED, PRIVATE COPY).
struct PMWStamp: View {
    enum Kind { case privateCopy, notesDue, approved, latest, custom }

    let text: String
    var kind: Kind = .privateCopy
    var tight: Bool = false
    var straight: Bool = false

    private var color: Color {
        switch kind {
        case .privateCopy: return PMWColors.redline
        case .notesDue:    return PMWColors.notesBlue
        case .approved:    return PMWColors.inkDeep
        case .latest:      return PMWColors.inkDeep
        case .custom:      return PMWColors.redline
        }
    }

    var body: some View {
        Text(text.uppercased())
            .font(PMWFont.mono(tight ? 9 : 11, weight: .bold))
            .kerning(tight ? 1.4 : 1.8)
            .foregroundStyle(color)
            .padding(.horizontal, tight ? 6 : 10)
            .padding(.vertical, tight ? 2 : 4)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .stroke(color, lineWidth: 1.5)
            )
            .rotationEffect(.degrees(straight ? 0 : (tight ? -0.5 : -1.2)))
    }
}

/// A horizontal hairline. Uses brand-aware line color.
struct PMWRule: View {
    var body: some View {
        Rectangle()
            .fill(PMWColors.line)
            .frame(height: 1)
    }
}

/// Catalog ID text — `WL · 0142 · Halftime` style, mono caps with red dots.
struct PMWCatalogId: View {
    let workspaceCode: String
    let catalogNumber: String
    let title: String?
    var tint: Color = PMWColors.pencilWarm

    var body: some View {
        HStack(spacing: 6) {
            Text(workspaceCode.uppercased())
                .foregroundStyle(PMWColors.ink)
            Text("·")
                .foregroundStyle(tint)
            Text(catalogNumber)
                .foregroundStyle(PMWColors.ink)
            if let title {
                Text("·")
                    .foregroundStyle(tint)
                Text(title.uppercased())
                    .foregroundStyle(tint)
            }
        }
        .font(PMWFont.mono(11, weight: .semibold))
        .kerning(0.8)
    }
}

// MARK: - Button styles ------------------------------------------------

struct PMWIconButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(PMWColors.ink)
            .frame(width: 44, height: 44)
            .background {
                if active || configuration.isPressed {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(PMWColors.soft)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(PMWColors.line, lineWidth: 1))
                }
            }
            .offset(y: configuration.isPressed ? 1 : 0)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct PMWChromeButtonStyle: ButtonStyle {
    enum Variant { case ghost, dark, accent }
    var variant: Variant = .ghost

    // back-compat: old code does `PMWChromeButtonStyle(accent: true)`
    init(variant: Variant) { self.variant = variant }
    init(accent: Bool = false) { self.variant = accent ? .accent : .ghost }

    private var background: Color {
        switch variant {
        case .ghost:  return .clear
        case .dark:   return PMWColors.inkDeep
        case .accent: return PMWColors.redline
        }
    }
    private var foreground: Color {
        switch variant {
        case .ghost:  return PMWColors.ink
        case .dark, .accent: return .white
        }
    }
    private var border: Color {
        switch variant {
        case .ghost:  return PMWColors.lineStrong.opacity(0.45)
        case .dark:   return PMWColors.inkDeep
        case .accent: return PMWColors.redline
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PMWFont.sans(13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(background)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(border, lineWidth: 1))
            )
            .offset(y: configuration.isPressed ? 1 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

extension View {
    func pmwScreen() -> some View {
        self
            .padding(.horizontal, PMWSpacing.page)
            .background(PMWColors.canvas)
    }
}
