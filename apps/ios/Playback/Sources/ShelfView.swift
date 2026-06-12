import SwiftUI

/// THE SHELF — pins + recents as a record crate on Home.
///
/// SwiftUI port of the web reference (apps/web/src/Shelf.tsx): a row of square
/// 12" sleeves standing on a floor, receding in 3D. Every sleeve leans the
/// SAME way — one continuous direction, like records in a crate viewed from
/// one side. The focused card faces the viewer most; cards ahead of focus
/// (right) recede slot by slot; cards behind focus (left) are the flipped-past
/// end of the stack — packed tighter, pushed deeper, faded quieter. Transforms
/// + opacity only — no timers, no TimelineView, no auto-advance, and no reads
/// of any high-frequency player state.
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
/// through the crate. With more records than one visible window holds, the
/// crate LOOPS — flipping past the last record wraps to the first in both
/// directions (poses come from the shortest wrap distance, not raw index
/// distance), so the band is consistently filled at every position and the
/// drag just keeps flipping. With few records the ends stay real and drags
/// rubber-band past them.
struct ShelfView: View {
    var items: [ShelfItem]
    var store: WorkspaceStore
    var onOpen: (ShelfItem) -> Void

    @State private var focus = 0
    @State private var pulled = false
    @State private var dragAnchor: Int?
    @State private var rubber: CGFloat = 0
    /// Item ids whose wrap distance jumped across the loop seam on the most
    /// recent flip (e.g. d −3 → +3 when focus wraps past an end). Their
    /// transaction animation is stripped so they relocate instantly at the
    /// faded band edge instead of springing across the whole crate.
    @State private var seamCrossing: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("wl.reduceMotion") private var appReduceMotion = false

    /// Reduce Motion (system or in-app): crossfade focus, pull-out becomes
    /// border + label emphasis. Fully functional, nothing travels in 3D.
    private var reduced: Bool { systemReduceMotion || appReduceMotion }

    // Crate geometry — spacing keeps every exposed sleeve sliver ≥ 44pt
    // ahead of focus; behind focus the slivers are inert filler (tighter).
    private let cardW: CGFloat = 196
    private let cardH: CGFloat = 196        // 1:1 square sleeve — artwork fills the face
    private let spacing: CGFloat = 44       // slot pitch ahead of focus (also drag pt/slot)
    private let focusGap: CGFloat = 104     // focused card → first card ahead
    private let backSpacing: CGFloat = 26   // tighter pitch behind focus
    private let backGap: CGFloat = 84       // focused card → first card behind
    private let maxVisibleAhead = 3         // base budget ahead of focus
    private let maxVisibleBehind = 2        // fewer behind — the quiet end of the stack

    /// The crate loops only when it holds more records than one visible
    /// window (n > behind + ahead + 1) — wrapping with fewer would ask the
    /// same sleeve to appear on both sides of focus in a single frame.
    /// Below that, the ends stay real and the clamped behavior holds.
    private var looping: Bool { items.count > maxVisibleAhead + maxVisibleBehind + 1 }

    /// Display offset of card `i` from focus `f`. Looping: the wrap-forward
    /// (ahead) distance while it fits the ahead budget, else negative — the
    /// card sits behind focus via the wrap. Every card gets a distinct
    /// offset, biased to match the asymmetric window (more ahead than
    /// behind), so both sides of focus are always populated and flipping
    /// past either end just keeps going. Non-looping: plain index distance.
    private func delta(_ i: Int, from f: Int) -> Int {
        guard looping else { return i - f }
        let n = items.count
        let ahead = (((i - f) % n) + n) % n
        return ahead <= maxVisibleAhead ? ahead : ahead - n
    }

    /// Visible window per side. On a LOOPING crate both sides are always
    /// populated (wrap distance fills them), so each side takes its base
    /// budget and the window is identical at every focus index. On a small
    /// (non-looping) crate the adaptive end-extension still applies: when
    /// one side runs out of items, the other inherits its unused budget, so
    /// the band never collapses to a sliver — at the last slot the
    /// behind-run extends to 5, at slot 0 the ahead-run does.
    private var visAhead: Int {
        if looping { return maxVisibleAhead }
        let availAhead = max(items.count - 1 - focus, 0)
        let availBehind = focus
        return min(availAhead, maxVisibleAhead + max(0, maxVisibleBehind - availBehind))
    }

    private var visBehind: Int {
        if looping { return maxVisibleBehind }
        let availAhead = max(items.count - 1 - focus, 0)
        return min(focus, maxVisibleBehind + max(0, maxVisibleAhead - availAhead))
    }
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
        var fade: Double    // at-rest card opacity
        var tuck: Double    // 0…1 — quiets sleeve initials as a card recedes
    }

    /// Crate pose for a card `d` slots away from focus — ONE continuous lean
    /// direction across the whole bin. Focused: a gentle −18°. Ahead (d > 0):
    /// falls back toward a −65° cap as it recedes. Behind (d < 0): the SAME
    /// lean, but these are the already-flipped records — pushed deeper
    /// (z −60… vs −26…), packed tighter, and faded, so the left side reads as
    /// the back of the same run, never a mirrored book-end. Both sides
    /// extrapolate past their base budgets (the adaptive window extends
    /// either run when the other side has no items): z keeps sinking, the
    /// lean eases toward −65°, opacity keeps falling to a 0.3 floor — never
    /// a flat run of identical slivers.
    private func pose(_ d: Int) -> Pose {
        if d == 0 { return Pose(x: 0, z: 90, ry: -18, hidden: false, fade: 1, tuck: 0) }
        let a = abs(d)
        if d > 0 {
            return Pose(
                x: focusGap + CGFloat(a - 1) * spacing,
                z: CGFloat(-26 * min(a, 4) - max(0, a - 4) * 9),
                ry: -18 - Double(min(8 + a * 11, 37)) - Double(min(max(0, a - 3) * 5, 10)), // −37°, −48°, −55° … −65° cap
                hidden: a > visAhead,
                fade: max(0.3, 1 - Double(a - 1) * 0.08),       // 1, 0.92 … falls to a 0.3 floor
                tuck: min(1, Double(a - 1) * 0.3)
            )
        }
        return Pose(
            x: -(backGap + CGFloat(a - 1) * backSpacing),
            z: CGFloat(-60 - (min(a, 4) - 1) * 22 - max(0, a - 4) * 9), // −60, −82, −104, −126, then −9/slot
            ry: -50 - Double(min((a - 1) * 6, 14)) - Double(min(max(0, a - 4), 2)), // −50°, −56°, −62° … −66° cap
            hidden: a > visBehind,
            fade: max(0.3, 0.8 - Double(a - 1) * 0.15),         // 0.8, 0.65 … falls to a 0.3 floor
            tuck: min(1, 0.45 + Double(a - 1) * 0.3)
        )
    }

    /// Compose the band around the *visible* group so there's never a dead
    /// half-band: shift the whole crate by half the difference between the
    /// occupied extents behind (left) and ahead (right) of focus — the two
    /// sides have different gaps and pitches now, so each gets its own extent.
    private func aheadExtent(_ n: Int) -> CGFloat {
        n == 0 ? cardW / 2 : focusGap + CGFloat(n - 1) * spacing + cardW / 2
    }

    private func behindExtent(_ n: Int) -> CGFloat {
        n == 0 ? cardW / 2 : backGap + CGFloat(n - 1) * backSpacing + cardW / 2
    }

    private var crateShift: CGFloat {
        let behind = behindExtent(visBehind)
        let ahead = aheadExtent(visAhead)
        return ((behind - ahead) / 2).rounded()
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
                    if pulled {
                        seamCrossing = []
                        withAnimation(crateAnimation) { pulled = false }
                    }
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

    // MARK: labels — exactly ONE label at rest: the focused card's, anchored
    // above ITS sleeve. Hidden during pull-out (the pulled sleeve rises into
    // the label band); under Reduce Motion the focused label stays as the
    // pull-out emphasis instead.
    private var labels: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let d = delta(i, from: focus)
                let p = pose(d)
                let dir: CGFloat = d < 0 ? -1 : (d > 0 ? 1 : 0)
                let pulledEmphasis = pulled && reduced && d == 0
                let visible = !p.hidden && d == 0 && (!pulled || pulledEmphasis)
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
                .opacity(visible ? 1 : 0)
                .transaction { t in
                    // Label follows its card: crossing the loop seam jumps,
                    // never streaks across the band.
                    if seamCrossing.contains(item.id) { t.animation = nil }
                }
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
        let d = delta(i, from: focus)
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
        .opacity(p.hidden ? 0 : (dimmed ? 0.45 : p.fade))
        .allowsHitTesting(!p.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open \(item.title), \(kindName(item))\(item.pinned ? ", pinned" : "")")
        .transaction { t in
            // Crossing the loop seam (d jumping e.g. −3 → +3) must not
            // interpolate — strip the animation so this card relocates
            // instantly at the faded band edge instead of springing across.
            if seamCrossing.contains(item.id) { t.animation = nil }
        }
    }

    /// The 3D face — rotation, depth scale, hairline edge, soft floor shadow.
    /// Inert: hit-testing belongs to the flat strip that wraps it.
    private func face(_ item: ShelfItem, pose p: Pose, isPulled: Bool, dimmed: Bool) -> some View {
        let ry: Double = (reduced || isPulled) ? 0 : p.ry
        let z: CGFloat = p.z - (dimmed ? 40 : 0)
        let scale: CGFloat = (reduced || isPulled) ? 1 : depth / (depth - z)
        let emphasized = isPulled && reduced
        return cover(item, tuck: p.tuck)
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
    /// identical blank. `tuck` fades + shrinks the initials as the sleeve
    /// recedes, so strongly tucked slivers stay quiet instead of stacking
    /// big letters into clutter. Meshes are static here: 15 sleeves must not
    /// run 15 redraw loops.
    @ViewBuilder private func cover(_ item: ShelfItem, tuck: Double) -> some View {
        if let track = pinnedCover(item.ref, store) {
            TrackArtwork(track: track, cornerRadius: 10, showsKeyline: false, animateFallback: false)
        } else {
            ZStack {
                MeshCover(colors: MeshPalette.colors(for: item.id), animate: false, fillsSafeArea: false)
                MonoLabel(initials(item.title), color: PB.cream, size: 28, tracking: 2)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .scaleEffect(1 - tuck * 0.3)
                    .opacity(1 - tuck * 0.85)
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

    // MARK: focus moves — every flip routes here

    /// Advance focus: wrap mod n when looping (no ends), clamp otherwise.
    /// Before the animated change, pre-compute which cards cross the loop
    /// seam for THIS move — a crosser's wrap distance jumps by more than
    /// half the crate (normal moves shift d by the step count; crossers by
    /// n − step) — and strip their transaction animation so the spring
    /// always travels the short way and nothing flies across the band.
    private func flip(to target: Int) {
        let n = items.count
        guard n > 0 else { return }
        let next = looping ? ((target % n) + n) % n : min(n - 1, max(0, target))
        guard next != focus else { return }
        seamCrossing = looping
            ? Set(items.indices.compactMap { i in
                abs(delta(i, from: next) - delta(i, from: focus)) > n / 2 ? items[i].id : nil
            })
            : []
        withAnimation(crateAnimation) { focus = next }
    }

    // MARK: the three-tap progression

    private func handleTap(_ i: Int) {
        if i != focus {
            withAnimation(crateAnimation) { pulled = false }
            flip(to: i)
            return
        }
        seamCrossing = [] // pull/Esc is untouched by the wrap — never strip its spring
        if !pulled {
            withAnimation(crateAnimation) { pulled = true }
            return
        }
        withAnimation(crateAnimation) { pulled = false }
        onOpen(items[i])
    }

    // MARK: drags

    /// Horizontal drag flips through the crate — records move under your
    /// thumb, one slot per `spacing` points. On a looping crate there are no
    /// ends, so no rubber-band: the drag just keeps flipping, wrapping mod n
    /// in either direction (the spring stays short-way via `flip`'s seam
    /// stripping). Small (non-looping) crates keep the clamp + rubber give.
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
                flip(to: target)
                if looping {
                    if rubber != 0 { rubber = 0 }
                    return
                }
                let clamped = min(items.count - 1, max(0, target))
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
                seamCrossing = []
                withAnimation(crateAnimation) { pulled = false }
            }
    }
}
