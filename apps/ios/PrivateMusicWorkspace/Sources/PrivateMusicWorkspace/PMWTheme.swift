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

/// All non-readout type is Helvetica Neue. Drama comes from size, weight
/// and tracking — not from novelty fonts. Mono is reserved for actual
/// instrument readouts (time codes, LUFS, BPM-as-number, dB).
enum PMWFont {
    private static func helvetica(_ size: CGFloat, weight: Font.Weight) -> Font {
        Font.custom(helveticaName(for: weight), size: size)
    }

    private static func helveticaName(for weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin: return "HelveticaNeue-Thin"
        case .light:             return "HelveticaNeue-Light"
        case .regular:           return "HelveticaNeue"
        case .medium:            return "HelveticaNeue-Medium"
        case .semibold:          return "HelveticaNeue-Medium"
        case .bold:              return "HelveticaNeue-Bold"
        case .heavy, .black:     return "HelveticaNeue-Bold"
        default:                 return "HelveticaNeue"
        }
    }

    /// Display — heavy Helvetica. Wordmark, hero titles.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        helvetica(size, weight: weight)
    }

    /// "Mono" in name only — now Helvetica, used for eyebrows / labels /
    /// catalog ids / stamp text where tight tracking + uppercase is the
    /// effect we want. Call sites supply tracking via `.kerning(...)`.
    static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        helvetica(size, weight: weight)
    }

    /// Body sans — note text, paragraph copy.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        helvetica(size, weight: weight)
    }

    /// Genuine monospace for instrument readouts only — time codes, LUFS,
    /// BPM-as-number, dB. The system mono on iOS is SF Mono.
    static func readout(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
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

/// Status indicator label — a small color-dot followed by tight Helvetica
/// caps. No rotation, no double-border. Used for "Notes Due", "Approved",
/// "Latest", etc. Drama comes from tracking + color, not from kitsch.
struct PMWStamp: View {
    enum Kind { case privateCopy, notesDue, approved, latest, custom }

    let text: String
    var kind: Kind = .privateCopy
    var tight: Bool = false
    /// Retained for source compat — the stamp is never rotated now.
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
        HStack(spacing: tight ? 5 : 6) {
            Circle()
                .fill(color)
                .frame(width: tight ? 5 : 6, height: tight ? 5 : 6)
            Text(text.uppercased())
                .font(PMWFont.sans(tight ? 9 : 10, weight: .bold))
                .kerning(tight ? 1.2 : 1.4)
                .foregroundStyle(color)
        }
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

/// Circular icon button. Dark-mode neumorphic.
///
/// RESTING — reads as raised:
///   • fill ~3 steps brighter than the studio canvas (#25211B)
///   • inset top highlight (white @ 10%)
///   • inset bottom-edge dark (black @ 70%)
///   • soft drop shadow with real radius (radius 7, y 3, black @ 55%)
///
/// PRESSED — reads as recessed into the canvas:
///   • fill DARKER than canvas (#07060A) so the button reads as a hole
///   • deep inner shadow at the top of the well
///   • faint bottom-edge highlight (light catching the recessed lip)
///   • drop shadow killed
struct PMWIconButtonStyle: ButtonStyle {
    var active = false
    var diameter: CGFloat = 44

    private static let restingFill = Color(red: 37/255, green: 33/255, blue: 27/255)
    private static let pressedFill = Color(red: 7/255, green: 6/255, blue: 10/255)

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(PMWColors.ink)
            .frame(width: diameter, height: diameter)
            .background(
                ZStack {
                    Circle().fill(pressed ? Self.pressedFill : Self.restingFill)

                    if pressed {
                        // Deep inner shadow at top of the well — multiple
                        // layered strokes simulate a soft inner shadow.
                        Circle()
                            .stroke(Color.black.opacity(0.85), lineWidth: 3)
                            .blur(radius: 3)
                            .mask(
                                Circle().fill(
                                    LinearGradient(
                                        colors: [.black, .black.opacity(0.4), .clear],
                                        startPoint: .top, endPoint: .center
                                    )
                                )
                            )
                        // Faint bottom-edge highlight
                        Circle()
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.8)
                            .mask(
                                Circle().fill(
                                    LinearGradient(
                                        colors: [.clear, .clear, .black],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                            )
                    } else {
                        // Top highlight (catches the light)
                        Circle()
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1.2)
                            .mask(
                                Circle().fill(
                                    LinearGradient(
                                        colors: [.black, .clear],
                                        startPoint: .top, endPoint: .center
                                    )
                                )
                            )
                        // Bottom-edge dark (form's underside)
                        Circle()
                            .strokeBorder(Color.black.opacity(0.7), lineWidth: 1.4)
                            .mask(
                                Circle().fill(
                                    LinearGradient(
                                        colors: [.clear, .black],
                                        startPoint: .center, endPoint: .bottom
                                    )
                                )
                            )
                    }
                }
            )
            // Real lift while raised — disappears on press
            .shadow(color: pressed ? .clear : Color.black.opacity(0.55), radius: 7, x: 0, y: 3)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: pressed)
    }
}

/// Pill-shaped action button. Three variants:
///  - `.ghost` — paper fill, hairline stroke (default, secondary actions)
///  - `.dark`  — ink fill (rare; "set as current"-style emphasis)
///  - `.accent`— redline fill (one primary per surface)
///
/// All three share Music Hub's pressed-in feel: 1pt drop, 2% scale, slight
/// brightness dip over 160ms ease-out. Borders are a soft `lineStrong @ 0.45`
/// — not a hard 1px — so the buttons feel object-like, not boxy.
struct PMWChromeButtonStyle: ButtonStyle {
    enum Variant { case ghost, dark, accent }
    var variant: Variant = .ghost
    var compact: Bool = false

    init(variant: Variant, compact: Bool = false) { self.variant = variant; self.compact = compact }
    init(accent: Bool = false) { self.variant = accent ? .accent : .ghost }

    private static let ghostResting = Color(red: 37/255, green: 33/255, blue: 27/255)
    private static let ghostPressed = Color(red: 7/255, green: 6/255, blue: 10/255)

    private var background: Color {
        switch variant {
        case .ghost:  return Self.ghostResting
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

    @ViewBuilder
    private func neumorphicEdges(pressed: Bool) -> some View {
        // Ghost variant gets the full raised/recessed neumorphic edge.
        // Dark + accent stay flat-filled but still respect the press.
        if variant == .ghost {
            if pressed {
                Capsule()
                    .stroke(Color.black.opacity(0.85), lineWidth: 3)
                    .blur(radius: 3)
                    .mask(
                        Capsule().fill(
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center)
                        )
                    )
                Capsule()
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.8)
                    .mask(
                        Capsule().fill(
                            LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
                        )
                    )
            } else {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1.2)
                    .mask(
                        Capsule().fill(
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center)
                        )
                    )
                Capsule()
                    .strokeBorder(Color.black.opacity(0.7), lineWidth: 1.4)
                    .mask(
                        Capsule().fill(
                            LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
                        )
                    )
            }
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: compact ? 13 : 15, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 14 : 20)
            .frame(height: compact ? 36 : 42)
            .background(
                ZStack {
                    Capsule().fill(
                        variant == .ghost
                            ? (pressed ? Self.ghostPressed : Self.ghostResting)
                            : background
                    )
                    neumorphicEdges(pressed: pressed)
                }
            )
            .shadow(
                color: (variant == .ghost && !pressed) ? Color.black.opacity(0.55) : .clear,
                radius: 7, x: 0, y: 3
            )
            .scaleEffect(pressed ? 0.98 : 1)
            .brightness(pressed && variant != .ghost ? -0.06 : 0)
            .animation(.easeOut(duration: 0.14), value: pressed)
    }
}

/// Full-row tap surface — gives any HStack the same pressed-in well treatment
/// MH uses for typographic rows. Drop in via `.buttonStyle(PMWTactileButtonStyle())`.
struct PMWTactileButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.985
    var pressedOpacity: Double = 0.78
    var pressedWell = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if pressedWell && configuration.isPressed {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(PMWColors.ink.opacity(0.038))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .inset(by: 0.55)
                                .stroke(PMWColors.ink.opacity(0.12), lineWidth: 0.9)
                        )
                }
            }
            .offset(y: configuration.isPressed ? 1 : 0)
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

extension View {
    func pmwScreen() -> some View {
        self
            .padding(.horizontal, PMWSpacing.page)
            .background(PMWColors.canvas)
    }
}
