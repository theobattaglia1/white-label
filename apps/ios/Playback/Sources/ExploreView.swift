import SwiftUI

/// Explore is the account-backed discovery surface: saved views, review queues,
/// projects, playlists, and recent songs all point back into the same library.
struct ExploreView: View {
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void
    var openQueue: (String, [Track]) -> Void = { _, _ in }

    private var reviewTracks: [Track] {
        let flagged = store.tracks.filter { store.openCount($0.id) > 0 }
        return Array((flagged.isEmpty ? store.tracks : flagged).prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                AppScreenHeader(title: "Explore", isPlaying: player.isPlaying)

                syncStrip

                if !store.savedViews.isEmpty {
                    section("Smart views") {
                        ForEach(store.savedViews) { view in
                            NavigationLink {
                                SavedViewDetailView(summary: view, player: player, store: store, openQueue: openQueue)
                            } label: {
                                exploreRow(icon: "line.3.horizontal.decrease.circle", title: view.name, detail: view.detail)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                section("Needs your ear") {
                    ForEach(reviewTracks) { track in
                        Button { openSong(track.id) } label: {
                            HStack(spacing: 13) {
                                TrackArtwork(track: track, cornerRadius: 7)
                                    .frame(width: 46, height: 46)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(store.displayTitle(track.id, track.title))
                                        .font(PB.display(17))
                                        .foregroundStyle(PB.cream)
                                    MonoLabel("\(track.artist) · \(track.versionLabel)", color: PB.pencil, size: 9, tracking: 1.2)
                                }
                                Spacer()
                                if store.openCount(track.id) > 0 {
                                    MonoLabel("\(store.openCount(track.id)) open", color: PB.redline, size: 9, tracking: 1)
                                }
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .songActionsMenu(store, track)
                    }
                }

                section("Projects") {
                    ForEach(store.rooms) { room in
                        NavigationLink(value: room) {
                            exploreRow(icon: "folder", title: room.title, detail: "\(room.artist) · \(room.trackIDs.count) songs")
                        }
                        .buttonStyle(.plain)
                        .pinMenu(store, PinRef(kind: .room, targetID: room.id))
                    }
                }

                section("Playlists") {
                    ForEach(store.playlists) { playlist in
                        NavigationLink(value: playlist) {
                            exploreRow(icon: "text.badge.plus", title: playlist.title, detail: "\(playlist.trackIDs.count) tracks")
                        }
                        .buttonStyle(.plain)
                        .pinMenu(store, PinRef(kind: .playlist, targetID: playlist.id))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 150)
        }
        .scrollIndicators(.hidden)
        .background {
            PB.black.ignoresSafeArea()
            AmbientDotField(isPlaying: player.isPlaying, positionMs: player.positionMs)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var syncStrip: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(syncColor)
                .frame(width: 7, height: 7)
            MonoLabel(store.syncMessage, color: PB.pencil, size: 9, tracking: 1.2)
            Spacer()
            MonoLabel("\(store.tracks.count) songs", color: PB.cream.opacity(0.7), size: 9, tracking: 1.2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.panel))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
    }

    private var syncColor: Color {
        switch store.syncState {
        case .synced: return PB.green
        case .syncing, .saving: return PB.cobalt
        case .offline, .error: return PB.redline
        default: return PB.pencil
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MonoLabel(title, color: PB.pencil, size: 10, tracking: 2)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel.opacity(0.72)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
        }
    }

    private func exploreRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(PB.cream)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PB.cream.opacity(0.08)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel(detail, color: PB.pencil, size: 9, tracking: 1.1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(PB.pencil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 69)
        }
    }
}

struct SavedViewDetailView: View {
    var summary: SavedViewSummary
    var player: Player
    var store: WorkspaceStore
    var openQueue: (String, [Track]) -> Void

    private var tracks: [Track] {
        let descriptor = "\(summary.name) \(summary.detail)".lowercased()
        if descriptor.contains("open") || descriptor.contains("review") || descriptor.contains("needs") {
            let filtered = store.tracks.filter { store.openCount($0.id) > 0 }
            return filtered.isEmpty ? store.tracks : filtered
        }
        return store.tracks
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    MonoLabel("Smart view", color: PB.pencil, size: 10, tracking: 2)
                    Text(summary.name).font(PB.display(32)).foregroundStyle(PB.cream)
                    MonoLabel("\(tracks.count) songs · \(summary.detail)", color: PB.pencil, size: 10, tracking: 1.1)
                }
                .padding(.top, 40)

                VStack(spacing: 0) {
                    ForEach(tracks) { track in
                        Button { openQueue(track.id, tracks) } label: {
                            SongRow(track: track, store: store,
                                    trailing: store.openCount(track.id) > 0 ? "\(store.openCount(track.id)) open" : nil,
                                    trailingColor: PB.redline)
                        }
                        .buttonStyle(.plain)
                        .songActionsMenu(store, track)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 150)
        }
        .scrollIndicators(.hidden)
        .background {
            PB.black.ignoresSafeArea()
            AmbientDotField(isPlaying: player.isPlaying, positionMs: player.positionMs)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, 16).padding(.top, 6) }
    }
}
