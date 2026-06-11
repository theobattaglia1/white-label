import SwiftUI

/// THE SHELF — pins + recents as a record crate on Home.
///
/// SwiftUI port of the web reference (apps/web/src/Shelf.tsx): a row of square
/// 12" sleeves standing on a floor, receding in 3D; the focused card faces the
/// viewer most, far cards sit nearly edge-on, cards left of focus mirror and
/// lean the other way. Transforms + opacity only — no timers, no TimelineView,
/// no auto-advance, and no reads of any high-frequency player state.
///
/// Hit model (ported from the web fix in bc0dbdf): each card button is a FLAT
/// strip — offset(x:) + zIndex in painter's order, like records in a bin. The
/// 3D pose lives on an inert inner face (`allowsHitTesting(false)`), so taps
/// resolve through plain 2D stacking, never 3D-projected quads.
///
/// Three-tap state machine (focus → pull → open):
///   1. tap an unfocused card → the crate eases so it becomes focused
///   2. tap the focused card  → PULL-OUT (rises + comes forward, rest dims)
///   3. tap the pulled card   → onOpen(item) navigates
/// Tap outside / swipe down while pulled → slips back. Horizontal drags flip
/// through the crate, rubber-banding at the ends.
struct ShelfView: View {
    var items: [ShelfItem]
    var store: WorkspaceStore
    var onOpen: (ShelfItem) -> Void

    @State private var focus = 0
    @State private var pulled = false
    @State private var dragAnchor: Int?
    @State private var rubber: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("wl.reduceMotion") private var appReduceMotion = false

    /// Reduce Motion (system or in-app): crossfade focus, pull-out becomes
    /// border + label emphasis. Fully functional, nothing travels in 3D.
    private var reduced: Bool { systemReduceMotion || appReduceMotion }

    // Crate geometry — spacing keeps every exposed sleeve sliver ≥ 44pt.
    private let cardW: CGFloat = 196
    private let cardH: CGFloat = 196        // 1:1 square sleeve — artwork fills the face
    private let spacing: CGFloat = 44       // adjacent receding cards
    private let focusGap: CGFloat = 104     // focused card → first neighbor
    private let maxVisible = 3              // cards drawn each side of focus
    private let depth: CGFloat = 1100       // perspective distance for z → scale
    private let labelBandH: CGFloat = 56
    private let stageH: CGFloat = 282

    private var crateAnimation: Animation {
        reduced ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.85)
    }

    private struct Pose {
        var x: CGFloat
        var z: CGFloat
        var ry: Double
        var hidden: Bool
    }

    /// Crate pose for a card `d` slots away from focus. Focused card leans a
    /// gentle −18°; cards fall back toward ±55° (near edge-on) as they recede,
    /// cards left of focus mirroring the lean.
    private func pose(_ d: Int) -> Pose {
        if d == 0 { return Pose(x: 0, z: 90, ry: -18, hidden: false) }
        let a = abs(d)
        let dir: CGFloat = d < 0 ? -1 : 1
        let lean = 18.0 + Double(min(8 + a * 11, 37))   // 37°, 48°, 55°, 55° …
        return Pose(
            x: dir * (focusGap + CGFloat(a - 1) * spacing),
            z: CGFloat(-26 * min(a, 4)),
            ry: d > 0 ? -lean : lean,
            hidden: a > maxVisible
        )
    }

    /// Compose the band around the *visible* group so there's never a dead
    /// half-band: shift the whole crate by half the difference between the
    /// occupied extents left and right of focus (focused sleeve lands about a
    /// third in from the leading edge when the crate recedes one way).
    private func sideExtent(_ n: Int) -> CGFloat {
        n == 0 ? cardW / 2 : focusGap + CGFloat(n - 1) * spacing + cardW / 2
    }

    private var crateShift: CGFloat {
        let left = sideExtent(min(focus, maxVisible))
        let right = sideExtent(min(max(items.count - 1 - focus, 0), maxVisible))
        return ((left - right) / 2).rounded()
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                head.padding(.horizontal, 24)
                stage
            }
            .onChange(of: items.count) { _, count in
                if focus > count - 1 {
                    focus = max(0, count - 1)
                    pulled = false
                }
            }
        }
    }

    private var head: some View {
        HStack(spacing: 10) {
            MonoLabel("The Shelf", color: PB.pencil, size: 11, tracking: 2)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            MonoLabel(String(format: "%02d records", items.count),
                      color: PB.pencil.opacity(0.7), size: 9, tracking: 1.6)
        }
    }

    private var stage: some View {
        ZStack(alignment: .top) {
            // Tap anywhere outside the pulled card → slips back into the crate.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if pulled { withAnimation(crateAnimation) { pulled = false } }
                }

            labels

            crate
                .padding(.top, labelBandH + 8)
        }
        .frame(height: stageH)
        .frame(maxWidth: .infinity)
        .gesture(crateDrag)
        .simultaneousGesture(pulledDismissDrag)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The shelf — pinned and recent")
    }

    // MARK: labels — focused card + 1 neighbor each side, anchored above
    // THEIR card. All hidden during pull-out (the pulled sleeve rises into
    // the label band); under Reduce Motion the focused label stays as the
    // pull-out emphasis instead.
    private var labels: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let d = i - focus
                let p = pose(d)
                let dir: CGFloat = d < 0 ? -1 : (d > 0 ? 1 : 0)
                let pulledEmphasis = pulled && reduced && d == 0
                let visible = !p.hidden && abs(d) <= 1 && (!pulled || pulledEmphasis)
                VStack(spacing: 3) {
                    Text(item.title)
                        .font(PB.display(16))
                        .foregroundStyle(PB.cream)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        MonoLabel(item.subtitle, color: PB.pencil, size: 8, tracking: 1.2)
                            .lineLimit(1)
                        if item.pinned {
                            MonoLabel("Pinned", color: PB.pencil.opacity(0.85), size: 7, tracking: 1.4)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .overlay(Capsule().strokeBorder(PB.pencil.opacity(0.35), lineWidth: 0.75))
                        }
                    }
                }
                .frame(width: 184)
                .offset(x: p.x + crateShift + dir * 52)
                .opacity(visible ? (d == 0 ? 1 : 0.55) : 0)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: labelBandH, alignment: .center)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: crate

    private var crate: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                card(i, item)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardH)
    }

    private func card(_ i: Int, _ item: ShelfItem) -> some View {
        let d = i - focus
        let p = pose(d)
        let x = p.x + crateShift + rubber
        let isFocused = d == 0
        let isPulled = isFocused && pulled
        let dimmed = pulled && !isFocused

        return Button {
            handleTap(i)
        } label: {
            // Flat 2D hit strip; the 3D pose lives on the inert face inside.
            ZStack {
                Color.clear.contentShape(Rectangle())
                face(item, pose: p, isPulled: isPulled, dimmed: dimmed)
                    .allowsHitTesting(false)
            }
            .frame(width: cardW, height: cardH)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPulled && !reduced ? 1.12 : 1)
        .offset(x: x, y: isPulled && !reduced ? -46 : 0)
        .zIndex(isPulled ? 60 : Double(40 - abs(d)))
        .opacity(p.hidden ? 0 : (dimmed ? 0.45 : 1))
        .allowsHitTesting(!p.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open \(item.title), \(kindName(item))\(item.pinned ? ", pinned" : "")")
    }

    /// The 3D face — rotation, depth scale, hairline edge, soft floor shadow.
    /// Inert: hit-testing belongs to the flat strip that wraps it.
    private func face(_ item: ShelfItem, pose p: Pose, isPulled: Bool, dimmed: Bool) -> some View {
        let ry: Double = (reduced || isPulled) ? 0 : p.ry
        let z: CGFloat = p.z - (dimmed ? 40 : 0)
        let scale: CGFloat = (reduced || isPulled) ? 1 : depth / (depth - z)
        let emphasized = isPulled && reduced
        return cover(item)
            .frame(width: cardW, height: cardH)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(PB.cream.opacity(emphasized ? 0.7 : 0.14),
                                  lineWidth: emphasized ? 1.5 : 0.75)
            )
            .shadow(color: .black.opacity(0.55), radius: 14, x: 0, y: 12)
            .scaleEffect(scale)
            .rotation3DEffect(.degrees(ry), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
    }

    /// Sleeve artwork: real cover when one resolves (same source as Library
    /// rows), otherwise a deterministic mesh + quiet initials — never an
    /// identical blank. Meshes are static here: 15 sleeves must not run 15
    /// redraw loops.
    @ViewBuilder private func cover(_ item: ShelfItem) -> some View {
        if let track = pinnedCover(item.ref, store) {
            TrackArtwork(track: track, cornerRadius: 10, showsKeyline: false, animateFallback: false)
        } else {
            ZStack {
                MeshCover(colors: MeshPalette.colors(for: item.id), animate: false, fillsSafeArea: false)
                MonoLabel(initials(item.title), color: PB.cream, size: 28, tracking: 2)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
        }
    }

    private func kindName(_ item: ShelfItem) -> String {
        switch item.ref.kind {
        case .song: return "song"
        case .playlist: return "playlist"
        case .room: return "project"
        }
    }

    /// 1–2 quiet initials for coverless sleeves.
    private func initials(_ title: String) -> String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        if letters.count >= 2 { return String(letters) }
        if let word = words.first { return String(word.prefix(2)) }
        return "·"
    }

    // MARK: the three-tap progression

    private func handleTap(_ i: Int) {
        if i != focus {
            withAnimation(crateAnimation) {
                pulled = false
                focus = i
            }
            return
        }
        if !pulled {
            withAnimation(crateAnimation) { pulled = true }
            return
        }
        withAnimation(crateAnimation) { pulled = false }
        onOpen(items[i])
    }

    // MARK: drags

    /// Horizontal drag flips through the crate — records move under your
    /// thumb, one slot per `spacing` points — rubber-banding past the ends.
    /// Vertical drags fall through to the surrounding scroll view.
    private var crateDrag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard !pulled else { return }
                if dragAnchor == nil {
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragAnchor = focus
                }
                guard let anchor = dragAnchor else { return }
                let steps = Int((-value.translation.width / spacing).rounded())
                let target = anchor + steps
                let clamped = min(items.count - 1, max(0, target))
                if clamped != focus {
                    withAnimation(crateAnimation) { focus = clamped }
                }
                if target != clamped {
                    let overshoot = -value.translation.width - CGFloat(clamped - anchor) * spacing
                    rubber = -overshoot * 0.18
                } else if rubber != 0 {
                    withAnimation(crateAnimation) { rubber = 0 }
                }
            }
            .onEnded { _ in
                dragAnchor = nil
                if rubber != 0 {
                    withAnimation(crateAnimation) { rubber = 0 }
                }
            }
    }

    /// Swipe down on the band while pulled → the card slips back.
    private var pulledDismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard pulled,
                      value.translation.height > 28,
                      value.translation.height > abs(value.translation.width)
                else { return }
                withAnimation(crateAnimation) { pulled = false }
            }
    }
}
