import SwiftUI

// MARK: - Pile payload

// String-based so it travels through the existing String Transferable pipeline.
// Prefix distinguishes it from library-song: and playlist-song: payloads.

func songPilePayload(_ ids: [String]) -> String {
    "playback-pile:" + ids.joined(separator: ",")
}

/// Returns the track IDs encoded in a pile payload, or nil if the payload
/// is not a pile payload.
func idsFromPilePayload(_ payload: String?) -> [String]? {
    guard let p = payload, p.hasPrefix("playback-pile:") else { return nil }
    let ids = String(p.dropFirst("playback-pile:".count))
        .components(separatedBy: ",")
        .filter { !$0.isEmpty }
    return ids.isEmpty ? nil : ids
}

// MARK: - Draggable modifier

extension View {
    /// Makes this view draggable as a single-song springboard item.
    /// Safe to call even when `enabled` is false — becomes a no-op.
    @ViewBuilder
    func springboardDraggable(
        trackID: String,
        track: Track,
        store: WorkspaceStore,
        enabled: Bool
    ) -> some View {
        if enabled {
            self.draggable(songPilePayload([trackID])) {
                HStack(spacing: 12) {
                    TrackArtwork(track: track, cornerRadius: 6)
                        .frame(width: 36, height: 36)
                    Text(store.displayTitle(trackID, track.title))
                        .font(PB.display(15))
                        .foregroundStyle(PB.cream)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PB.panel))
            }
        } else {
            self
        }
    }

    /// Makes this view draggable as a multi-song pile.
    /// Used when `bulkMode == .holding` and this row is part of the selection.
    @ViewBuilder
    func springboardPileDraggable(
        pileIDs: [String],
        pileTracks: [Track],
        store: WorkspaceStore,
        enabled: Bool
    ) -> some View {
        if enabled && !pileIDs.isEmpty {
            self.draggable(songPilePayload(pileIDs)) {
                HStack(spacing: 12) {
                    if let first = pileTracks.first {
                        TrackArtwork(track: first, cornerRadius: 6)
                            .frame(width: 36, height: 36)
                    }
                    Text("\(pileIDs.count) \(pileIDs.count == 1 ? "song" : "songs")")
                        .font(PB.display(15))
                        .foregroundStyle(PB.cream)
                    if pileIDs.count > 1 {
                        Text("+\(pileIDs.count - 1)")
                            .font(PB.mono(11)).foregroundStyle(PB.cobalt)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PB.panel))
            }
        } else {
            self
        }
    }

    /// Accepts a springboard pile drop. `onDrop` receives the full combined
    /// track ID list: dropped IDs + this row's targetID.
    /// Guards itself against pile payloads that contain only the target (no-op
    /// self-drop) and ignores drops while `disabled`.
    @ViewBuilder
    func springboardDropTarget(
        targetID: String,
        enabled: Bool,
        onDrop: @escaping ([String]) -> Void
    ) -> some View {
        if enabled {
            self.dropDestination(for: String.self) { payloads, _ in
                guard let ids = idsFromPilePayload(payloads.first) else { return false }
                // Drop target must not already be in the pile
                guard !ids.contains(targetID) else { return false }
                onDrop(ids + [targetID])
                return true
            }
        } else {
            self
        }
    }
}

// MARK: - Pile badge overlay

/// Small stacked-artwork badge shown on a selected row in holding mode.
/// Signals "this row is part of the draggable pile."
struct PileBadge: View {
    var count: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(PB.cobalt.opacity(0.18))
                .frame(width: 22, height: 22)
            Image(systemName: "square.stack.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PB.cobalt)
                .frame(width: 22, height: 22)
            if count > 1 {
                Text("\(count)")
                    .font(PB.mono(8))
                    .foregroundStyle(.white)
                    .padding(2)
                    .background(Capsule().fill(PB.cobalt))
                    .offset(x: 6, y: -6)
            }
        }
    }
}
