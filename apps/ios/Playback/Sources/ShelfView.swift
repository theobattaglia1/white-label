import SwiftUI

/// THE WALL — pins + recents plastered as posters across a draggable room on Home.
///
/// The slot logic still lives in ShelfSlots.swift: the 15 shelf slots become
/// the close cluster (large posters near the center viewpoint) and the next
/// ~60 recents become a spillover band deeper in the room (smaller, dimmer,
/// slower parallax). This view is only the presentation layer: a large virtual
/// plane the user pans freely in both axes, with a fixed marquee focal spot at
/// band center. The tap grammar is the shelf's, unchanged:
///   tap a wall poster  -> it travels forward into the marquee
///   tap the marquee    -> pull-out (rises, wall dims)
///   tap the pulled item-> open via Home's existing song / playlist / project
///                         navigation. Tap-away or drag-down slips it back.
struct ShelfView: View {
    var items: [ShelfItem]
    var store: WorkspaceStore
    var onOpen: (ShelfItem) -> Void

    @State private var marqueeID: String?
    @State private var pulled = false
    @State private var returningID: String?
    @State private var pan: CGPoint = .zero
    @State private var dragStartPan: CGPoint?
    @State private var cache = WallLayoutCache()
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("wl.reduceMotion") private var appReduceMotion = false

    private var reduced: Bool { systemReduceMotion || appReduceMotion }

    private let stageH: CGFloat = 332
    private let marqueeSize: CGFloat = 190
    private var marqueeY: CGFloat { stageH * 0.59 }   // leaves label room above

    private var travelAnimation: Animation {
        reduced ? .easeInOut(duration: 0.16) : .spring(response: 0.45, dampingFraction: 0.82)
    }
    private var settleAnimation: Animation {
        reduced ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.55)
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                head.padding(.horizontal, 24)
                stage
            }
            .onChange(of: items) { _, next in
                if let id = marqueeID, !next.contains(where: { $0.id == id }) {
                    // a stale spill/slot marquee self-heals at render too, but
                    // reset eagerly so pull-out can't linger on a gone item.
                    marqueeID = nil
                    pulled = false
                }
            }
        }
    }

    private var head: some View {
        HStack(spacing: 10) {
            MonoLabel("The Wall", color: PB.pencil, size: 11, tracking: 2)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            MonoLabel(String(format: "%02d up close", items.count),
                      color: PB.pencil.opacity(0.7), size: 9, tracking: 1.6)
        }
    }

    private var stage: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let model = cache.model(items: items, store: store, width: width, height: stageH)
            let currentID = model.byID[marqueeID ?? ""] != nil ? (marqueeID ?? items[0].id) : items[0].id
            let maxPanX = max(0, (model.planeW - width) / 2)
            let maxPanY = max(0, (model.planeH - stageH) / 2)
            let visible = visibleSpots(model: model, width: width, currentID: currentID)

            ZStack {
                WallBackdrop(width: width, height: stageH,
                             planeW: model.planeW, planeH: model.planeH,
                             pan: pan, reduced: reduced)
                    .allowsHitTesting(false)

                // CULL: only spots inside viewport + one poster-width margin
                // are instantiated; the marquee + returning poster always are.
                ForEach(visible) { spot in
                    if !(reduced && spot.id == currentID) {
                        poster(spot, width: width,
                               isMarquee: !reduced && spot.id == currentID,
                               currentID: currentID)
                    }
                }

                // Dim film between the wall and the marquee occupant — very
                // slight at rest, heavy while pulled (and then it eats taps,
                // so tap-away slips the pulled poster back).
                Rectangle()
                    .fill(PB.black.opacity(pulled ? 0.55 : 0.12))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(travelAnimation) { pulled = false }
                    }
                    .allowsHitTesting(pulled)
                    .zIndex(50)

                // Reduce Motion: marquee changes crossfade instead of travel.
                if reduced, let spot = model.byID[currentID] {
                    poster(spot, width: width, isMarquee: true, currentID: currentID)
                        .id("marquee-\(currentID)")
                        .transition(.opacity)
                }

                marqueeLabel(model.byID[currentID]?.item)
                    .frame(width: width - 56)
                    .position(x: width / 2, y: marqueeY - marqueeSize / 2 - 36)
                    .zIndex(80)
                    .allowsHitTesting(false)
                    .id("label-\(currentID)")
            }
            .frame(width: width, height: stageH)
            .clipped()
            .contentShape(Rectangle())
            .highPriorityGesture(panGesture(maxPanX: maxPanX, maxPanY: maxPanY))
            .accessibilityChildren {
                // VoiceOver: a flat list, close cluster first, then spillover.
                ForEach(model.ordered, id: \.id) { item in
                    Button("Open \(item.title), \(kindName(item))\(item.pinned ? ", pinned" : "")") {
                        onOpen(item)
                    }
                }
            }
            .accessibilityLabel("The wall — \(model.ordered.count) posters, pinned and recent")
        }
        .frame(height: stageH)
    }

    /// Viewport culling: a spot is live when its screen position (after its
    /// layer's parallax factor) lands within the band plus one poster-width
    /// margin. The marquee occupant and the poster travelling home are always
    /// kept alive so their springs never pop mid-flight.
    private func visibleSpots(model: WallModel, width: CGFloat, currentID: String) -> [WallSpot] {
        model.spots.filter { spot in
            if spot.id == currentID || spot.id == returningID { return true }
            let f = reduced ? 1 : spot.layerFactor
            let sx = spot.x - pan.x * f
            let sy = spot.y - pan.y * f
            return abs(sx) < width / 2 + spot.size && abs(sy) < stageH / 2 + spot.size
        }
    }

    private func poster(_ spot: WallSpot, width: CGFloat, isMarquee: Bool, currentID: String) -> some View {
        let f = reduced ? 1 : spot.layerFactor
        let sx = width / 2 + spot.x - pan.x * f
        let sy = stageH * 0.5 + spot.y - pan.y * f
        let mScale = marqueeSize / spot.size
        let scale = isMarquee ? (pulled ? mScale * 1.12 : mScale) : 1
        let px = isMarquee ? width / 2 : sx
        let py = isMarquee ? marqueeY - (pulled ? 18 : 0) : sy
        // Walls curve toward you at the extremes — subtle rotateY by screen x.
        let norm = max(-1.0, min(1.0, Double((sx - width / 2) / max(width / 2, 1))))
        let tilt = (reduced || isMarquee) ? 0 : norm * -14
        let lean = (reduced || isMarquee) ? 0 : spot.rotation

        return Button {
            handleTap(spot, isMarquee: isMarquee, currentID: currentID)
        } label: {
            posterFace(spot.item, close: spot.close, size: spot.size, focused: isMarquee)
                .frame(width: spot.size, height: spot.size)
                .contentShape(Rectangle().inset(by: -max(0, (44 - spot.size) / 2)))
        }
        .buttonStyle(.plain)
        .rotationEffect(.degrees(lean))
        .rotation3DEffect(.degrees(tilt), axis: (x: 0, y: 1, z: 0), perspective: 0.62)
        .scaleEffect(scale)
        .shadow(color: .black.opacity(isMarquee ? 0.5 : 0.3),
                radius: isMarquee ? 16 : 7, x: 0, y: isMarquee ? 10 : 5)
        .position(x: px, y: py)
        .opacity(isMarquee ? 1 : spot.baseOpacity)
        .zIndex(isMarquee ? (pulled ? 110 : 100)
                : spot.id == returningID ? 40
                : spot.close ? 30
                : spot.layer == 1 ? 20 : 10)
        .accessibilityHidden(true)
    }

    private func handleTap(_ spot: WallSpot, isMarquee: Bool, currentID: String) {
        if isMarquee {
            if pulled {
                withAnimation(travelAnimation) { pulled = false }
                onOpen(spot.item)
            } else {
                withAnimation(travelAnimation) { pulled = true }
            }
            return
        }
        returningID = currentID
        withAnimation(travelAnimation) {
            marqueeID = spot.id
            pulled = false
        }
        let demoted = currentID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if returningID == demoted { returningID = nil }
        }
    }

    private func posterFace(_ item: ShelfItem, close: Bool, size: CGFloat, focused: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            cover(item, close: close)
                .frame(width: size, height: size)
                .clipped()

            LinearGradient(
                colors: [.black.opacity(0.1), .black.opacity(close ? 0.42 : 0.3)],
                startPoint: .top,
                endPoint: .bottom
            )

            if close {
                VStack(alignment: .leading) {
                    HStack(alignment: .top) {
                        MonoLabel(kindName(item), color: PB.cream.opacity(0.74), size: 6, tracking: 1.1)
                        Spacer(minLength: 0)
                        if item.pinned {
                            MonoLabel("Pinned", color: PB.cream.opacity(0.7), size: 6, tracking: 1.05)
                        }
                    }
                    Spacer(minLength: 0)
                    MonoLabel(initials(item.title), color: PB.cream.opacity(0.78), size: size * 0.17, tracking: 1.6)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                }
                .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(PB.cream.opacity(focused ? 0.28 : 0.14), lineWidth: focused ? 1 : 0.75)
        )
    }

    /// Close cluster gets real artwork (TrackArtwork caches bundled/imported
    /// images and falls back to the mesh). Spillover is mesh-only by design:
    /// TrackArtwork's imported-file path hits disk per instantiation and the
    /// remote path spawns AsyncImage fetches — both jank when culling churns
    /// 60 deep posters during a pan, so the deep room stays generative.
    @ViewBuilder private func cover(_ item: ShelfItem, close: Bool) -> some View {
        if close, let track = pinnedCover(item.ref, store) {
            TrackArtwork(track: track, cornerRadius: 4, showsKeyline: false, animateFallback: false)
        } else {
            MeshCover(colors: MeshPalette.colors(for: item.id), animate: false, fillsSafeArea: false)
        }
    }

    @ViewBuilder private func marqueeLabel(_ item: ShelfItem?) -> some View {
        if let item {
            VStack(spacing: 5) {
                Text(item.title)
                    .font(PB.display(17))
                    .foregroundStyle(PB.cream)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 7) {
                    MonoLabel(item.subtitle, color: PB.pencil, size: 7, tracking: 1.15)
                        .lineLimit(1)
                    if item.pinned {
                        MonoLabel("Pinned", color: PB.pencil.opacity(0.86), size: 6, tracking: 1.2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(PB.pencil.opacity(0.35), lineWidth: 0.75))
                    }
                }
            }
            .multilineTextAlignment(.center)
        }
    }

    /// Drag = pan. minimumDistance 6 keeps taps intact (≥6pt of movement
    /// suppresses the tap, like the web shelf fix). Momentum comes from the
    /// gesture's predicted end point eased out; bounds rubber-band during the
    /// drag and settle inside on release. While pulled, a downward drag slips
    /// the poster back instead of panning.
    private func panGesture(maxPanX: CGFloat, maxPanY: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if pulled {
                    if value.translation.height > 30 {
                        withAnimation(travelAnimation) { pulled = false }
                    }
                    return
                }
                if dragStartPan == nil { dragStartPan = pan }
                guard let start = dragStartPan else { return }
                pan = CGPoint(
                    x: rubber(start.x - value.translation.width, limit: maxPanX),
                    y: rubber(start.y - value.translation.height, limit: maxPanY)
                )
            }
            .onEnded { value in
                guard let start = dragStartPan else { return }
                dragStartPan = nil
                guard !pulled else { return }
                let target = CGPoint(
                    x: min(maxPanX, max(-maxPanX, start.x - value.predictedEndTranslation.width)),
                    y: min(maxPanY, max(-maxPanY, start.y - value.predictedEndTranslation.height))
                )
                withAnimation(settleAnimation) { pan = target }
            }
    }

    private func rubber(_ raw: CGFloat, limit: CGFloat) -> CGFloat {
        if raw > limit { return limit + (raw - limit) * 0.22 }
        if raw < -limit { return -limit + (raw + limit) * 0.22 }
        return raw
    }

    private func kindName(_ item: ShelfItem) -> String {
        switch item.ref.kind {
        case .song: return "song"
        case .playlist: return "playlist"
        case .room: return "project"
        }
    }

    private func initials(_ title: String) -> String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        if letters.count >= 2 { return String(letters).uppercased() }
        if let word = words.first { return String(word.prefix(2)).uppercased() }
        return "PB"
    }
}

// MARK: - Room backdrop

/// Sparse wall seams + two rails, moving at the mid-layer parallax rate so the
/// band reads as a room and the pan reads as travel. One stroked path, no
/// timers — it only redraws because the pan changed.
private struct WallBackdrop: View {
    let width: CGFloat
    let height: CGFloat
    let planeW: CGFloat
    let planeH: CGFloat
    let pan: CGPoint
    let reduced: Bool

    var body: some View {
        Canvas { context, _ in
            let f: CGFloat = reduced ? 1 : 0.85
            var seams = Path()
            let spacing: CGFloat = 230
            var x = -planeW / 2
            while x <= planeW / 2 {
                let sx = width / 2 + x - pan.x * f
                if sx > -10, sx < width + 10 {
                    seams.move(to: CGPoint(x: sx, y: 0))
                    seams.addLine(to: CGPoint(x: sx, y: height))
                }
                x += spacing
            }
            for railY in [-planeH * 0.34, planeH * 0.36] {
                let sy = height / 2 + railY - pan.y * f
                if sy > -10, sy < height + 10 {
                    seams.move(to: CGPoint(x: 0, y: sy))
                    seams.addLine(to: CGPoint(x: width, y: sy))
                }
            }
            context.stroke(seams, with: .color(PB.cream.opacity(0.06)), lineWidth: 1)
        }
    }
}

// MARK: - Spatial model

private struct WallSpot: Identifiable {
    let item: ShelfItem
    let x: CGFloat        // world coords, plane-centered
    let y: CGFloat
    let size: CGFloat
    let rotation: Double  // poster lean jitter, degrees
    let layer: Int        // 0 close · 1 mid spill · 2 deep spill
    let baseOpacity: Double
    let close: Bool
    var id: String { item.id }
    var layerFactor: CGFloat { layer == 0 ? 1 : layer == 1 ? 0.85 : 0.7 }
}

private struct WallModel {
    var spots: [WallSpot]
    var byID: [String: WallSpot]
    var ordered: [ShelfItem]   // close-cluster-first, for VoiceOver
    var planeW: CGFloat
    var planeH: CGFloat
}

/// Memoizes the deterministic scatter. The body re-evaluates on every pan
/// frame, so the layout (and the recents-derived spillover behind it) is only
/// rebuilt when the inputs that can move posters change: slot ids, library
/// shape, band width. Plain class on purpose — mutating it never invalidates
/// the view.
private final class WallLayoutCache {
    private var key = ""
    private var cached: WallModel?

    func model(items: [ShelfItem], store: WorkspaceStore, width: CGFloat, height: CGFloat) -> WallModel {
        let k = "\(Int(width))|\(items.map(\.id).joined(separator: ","))|\(store.tracks.count)|\(store.playlists.count)"
        if let cached, key == k { return cached }
        let spill = ShelfSlots.spillover(
            shelf: items,
            recents: ShelfSlots.recents(
                tracks: store.tracks,
                playlists: store.playlists,
                activity: store.activity,
                titleOverrides: store.titleOverrides
            ),
            limit: 60
        )
        let model = WallLayout.build(close: items, spill: spill, width: width, height: height)
        key = k
        cached = model
        return model
    }
}

/// Deterministic poster scatter. Every position derives from an FNV-1a hash
/// of the item id (MeshPalette.stableHash — same convention as the mesh
/// covers), so the room is identical across launches. Minimum-distance
/// rejection keeps overlap under ~15%: each poster tries a fan of seeded
/// candidates and takes the first that clears its neighbors, else the least
/// bad one.
private enum WallLayout {
    static func build(close: [ShelfItem], spill: [ShelfItem], width: CGFloat, height: CGFloat) -> WallModel {
        let planeW = max(width * 3, 900)
        let planeH = height * 2.2
        let maxPanX = max(0, (planeW - width) / 2)
        let maxPanY = max(0, (planeH - height) / 2)
        var spots: [WallSpot] = []

        func place(_ candidates: [(x: CGFloat, y: CGFloat)], size: CGFloat) -> (x: CGFloat, y: CGFloat) {
            var best = candidates[0]
            var bestScore = -CGFloat.greatestFiniteMagnitude
            for c in candidates {
                var worst = CGFloat.greatestFiniteMagnitude
                for s in spots {
                    let need = (size + s.size) / 2 * 0.85   // ≤ ~15% overlap
                    worst = min(worst, hypot(c.x - s.x, c.y - s.y) - need)
                }
                if worst >= 0 { return c }
                if worst > bestScore { bestScore = worst; best = c }
            }
            return best
        }

        // Close cluster — the 15 shelf slots on a jittered golden-angle
        // spiral around the marquee's spot at the origin. 96–120pt posters.
        for (i, item) in close.enumerated() {
            var rng = SeededRNG(MeshPalette.stableHash("wall:" + item.id))
            let size = 96 + rng.unit() * 24
            let lean = Double(rng.unit() * 2 + 2) * (rng.unit() < 0.5 ? -1 : 1)
            var candidates: [(x: CGFloat, y: CGFloat)] = []
            for attempt in 0..<14 {
                let angle = CGFloat(i) * 2.39996 + (rng.unit() - 0.5) * 1.1 + CGFloat(attempt) * 0.47
                let radius = 150 + 102 * sqrt(CGFloat(i)) + (rng.unit() - 0.5) * 44 + CGFloat(attempt) * 9
                var x = cos(angle) * radius
                var y = sin(angle) * radius * 0.62
                x = min(maxPanX + width / 2 - size / 2 - 8, max(-(maxPanX + width / 2) + size / 2 + 8, x))
                y = min(maxPanY + height / 2 - size / 2 - 6, max(-(maxPanY + height / 2) + size / 2 + 6, y))
                candidates.append((x, y))
            }
            let p = place(candidates, size: size)
            spots.append(WallSpot(item: item, x: p.x, y: p.y, size: size,
                                  rotation: lean, layer: 0, baseOpacity: 1, close: true))
        }

        // Spillover — up to 60 more recents deeper in the room: smaller,
        // dimmer, on the slower parallax layers. Positions stay within each
        // layer's pannable reach (viewport + pan × layer factor) so nothing
        // is born unreachable, and a center keep-out ring leaves the close
        // cluster breathing room.
        for item in spill {
            var rng = SeededRNG(MeshPalette.stableHash("wall:" + item.id))
            let deep = rng.unit() < 0.45
            let layer = deep ? 2 : 1
            let f: CGFloat = deep ? 0.7 : 0.85
            let size = deep ? 64 + rng.unit() * 12 : 72 + rng.unit() * 12
            let lean = Double(rng.unit() * 2 + 2) * (rng.unit() < 0.5 ? -1 : 1)
            let opacity = deep ? 0.55 + Double(rng.unit()) * 0.13 : 0.68 + Double(rng.unit()) * 0.12
            let reachX = width / 2 + maxPanX * f - size / 2 - 8
            let reachY = height / 2 + maxPanY * f - size / 2 - 6
            var candidates: [(x: CGFloat, y: CGFloat)] = []
            for _ in 0..<16 {
                var x = (rng.unit() * 2 - 1) * reachX
                var y = (rng.unit() * 2 - 1) * reachY
                let nd = hypot(x, y / 0.62)
                if nd < 330 {
                    let push = 330 / max(nd, 1)
                    x = min(reachX, max(-reachX, x * push))
                    y = min(reachY, max(-reachY, y * push))
                }
                candidates.append((x, y))
            }
            let p = place(candidates, size: size)
            spots.append(WallSpot(item: item, x: p.x, y: p.y, size: size,
                                  rotation: lean, layer: layer, baseOpacity: opacity, close: false))
        }

        var byID: [String: WallSpot] = [:]
        for s in spots { byID[s.id] = s }
        return WallModel(spots: spots, byID: byID, ordered: close + spill,
                         planeW: planeW, planeH: planeH)
    }
}

/// SplitMix64 stream seeded from the FNV-1a id hash — cheap, deterministic,
/// and well distributed even for near-identical seeds.
private struct SeededRNG {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func unit() -> CGFloat { CGFloat(next64() >> 11) / CGFloat(UInt64(1) << 53) }
}
