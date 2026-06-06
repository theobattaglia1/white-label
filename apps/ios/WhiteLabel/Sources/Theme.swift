import SwiftUI

/// WHITE LABEL — v3 design tokens for iOS.
/// Warm-dark studio palette + the Teenage Engineering type system
/// (Univers TE display, Lettera Mono labels, Ndot sparingly).
enum WL {
    // Palette
    static let black   = Color(hex: 0x0C0907)
    static let panel   = Color(hex: 0x16110C)
    static let cream   = Color(hex: 0xF3ECDE)
    static let pencil  = Color(hex: 0x9B9285)
    static let faint   = Color.white.opacity(0.30)
    static let redline = Color(hex: 0xFF4A22) // needs-attention / in-review
    static let cobalt  = Color(hex: 0x4663E8) // current / structure
    static let green   = Color(hex: 0x5FD08A) // approved

    // Pale transport tints — soft hardware-button colors.
    static let paleCobalt = Color(hex: 0xBAC3EC)
    static let paleCoral  = Color(hex: 0xEDB29B)
    static let paleGreen  = Color(hex: 0xAFDBC3)

    // Type — PostScript names of the bundled faces.
    static func display(_ size: CGFloat) -> Font { .custom("UniversTE40-Light", size: size) }
    static func text(_ size: CGFloat)    -> Font { .custom("UniversTE20", size: size) }
    static func thin(_ size: CGFloat)    -> Font { .custom("UniversTE20-Thin", size: size) }
    static func mono(_ size: CGFloat)    -> Font { .custom("LetteraMonoLL-Regular", size: size) }
    static func dot(_ size: CGFloat)     -> Font { .custom("Ndot-55", size: size) }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// A small uppercase mono label — the catalog/eyebrow voice.
struct MonoLabel: View {
    let text: String
    var color: Color = WL.pencil
    var size: CGFloat = 10
    var tracking: CGFloat = 1.6
    init(_ text: String, color: Color = WL.pencil, size: CGFloat = 10, tracking: CGFloat = 1.6) {
        self.text = text; self.color = color; self.size = size; self.tracking = tracking
    }
    var body: some View {
        Text(text.uppercased())
            .font(WL.mono(size))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}
