import SwiftUI

/// The living gradient cover — a slowly drifting MeshGradient that stands in for
/// generative artwork. Corners stay pinned; the inner + edge points wander on
/// gentle sine paths so the field breathes without ever looping obviously.
struct MeshCover: View {
    let colors: [Color]
    var animate: Bool = true
    var fillsSafeArea: Bool = true
    @AppStorage("wl.reduceMotion") private var reduceMotion = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate || reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let gradient = MeshGradient(
                width: 3,
                height: 3,
                points: points(t),
                colors: colors,
                smoothsColors: true
            )
            if fillsSafeArea {
                gradient.ignoresSafeArea()
            } else {
                gradient
            }
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

/// Deterministic mesh palettes for items without artwork.
///
/// `String.hashValue` is seeded per launch, so anything derived from it
/// reshuffles every run. This uses a stable FNV-1a hash of the item id to pick
/// a base palette and rotate its hues, so every artist / project / song keeps
/// the same cover across launches while reading distinct from its neighbors.
enum MeshPalette {
    static func colors(for id: String) -> [Color] {
        hexes(for: id).map { Color(hex: $0) }
    }

    static func hexes(for id: String) -> [UInt] {
        let hash = stableHash(id)
        let base = basePalettes[Int(hash % UInt64(basePalettes.count))]
        let step = Double((hash >> 8) % 12) / 12.0   // 0°, 30°, … 330°
        guard step > 0 else { return base }
        return base.map { rotateHue($0, by: step) }
    }

    static func stableHash(_ id: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    private static let basePalettes: [[UInt]] = [
        [0x4663E8, 0x6E86EC, 0xEDB29B, 0x35499E, 0xC2566F, 0xF0A85A, 0x1F2C6E, 0xB13F72, 0xE8C87A],
        [0x5FD08A, 0xAFDBC3, 0xBAC3EC, 0x2E7A57, 0x4663E8, 0xE0A22E, 0x1D4F3A, 0x6E86EC, 0xEDB29B],
        [0xB1417E, 0xD0466A, 0xF07A6A, 0x6E4BD6, 0xE14B6A, 0xF0A85A, 0x3A2C7A, 0xB13F72, 0xE8B84A],
    ]

    /// Rotate a 0xRRGGBB color's hue by `shift` (0…1 of a full turn),
    /// preserving saturation and brightness so palettes keep their balance.
    private static func rotateHue(_ hex: UInt, by shift: Double) -> UInt {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        let maxC = Swift.max(r, g, b), minC = Swift.min(r, g, b)
        let delta = maxC - minC
        var h: Double = 0
        if delta > 0 {
            if maxC == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { h = (b - r) / delta + 2 }
            else { h = (r - g) / delta + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = maxC == 0 ? 0 : delta / maxC
        let v = maxC
        h = (h + shift).truncatingRemainder(dividingBy: 1)
        let sector = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let rgb: (Double, Double, Double)
        switch sector {
        case 0: rgb = (v, t, p)
        case 1: rgb = (q, v, p)
        case 2: rgb = (p, v, t)
        case 3: rgb = (p, q, v)
        case 4: rgb = (t, p, v)
        default: rgb = (v, p, q)
        }
        func channel(_ x: Double) -> UInt { UInt((Swift.min(1, Swift.max(0, x)) * 255).rounded()) }
        return (channel(rgb.0) << 16) | (channel(rgb.1) << 8) | channel(rgb.2)
    }
}

/// Placeholder cover for artists / projects without artwork: a deterministic
/// mesh derived from the item id with a two-letter initials overlay.
struct InitialsCover: View {
    let id: String
    let name: String
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            MeshCover(colors: MeshPalette.colors(for: id), animate: false, fillsSafeArea: false)
            MonoLabel(initials, color: PB.cream, size: size * 0.27, tracking: 1.2)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(PB.cream.opacity(0.14), lineWidth: 0.75)
        )
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        if letters.count >= 2 { return String(letters) }
        if let word = words.first { return String(word.prefix(2)) }
        return "·"
    }
}
