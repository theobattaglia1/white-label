import SwiftUI

// MARK: - Shared bits

func trackSwatch(_ t: Track, _ s: CGFloat, radius: CGFloat = 8) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(LinearGradient(colors: [t.mesh[0], t.mesh[4], t.mesh[8]],
                             startPoint: .topLeading, endPoint: .bottomTrailing))
        .frame(width: s, height: s)
}

struct SongRow: View {
    var track: Track
    var store: WorkspaceStore
    var trailing: String? = nil
    var trailingColor: Color = WL.pencil

    var body: some View {
        HStack(spacing: 13) {
            trackSwatch(track, 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayTitle(track.id, track.title)).font(WL.display(17)).foregroundStyle(WL.cream)
                MonoLabel("\(track.artist) · \(track.versionLabel)", color: WL.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            if let trailing { MonoLabel(trailing, color: trailingColor, size: 9, tracking: 1) }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())
    }
}

private struct ScreenHeader: View {
    var eyebrow: String
    var title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MonoLabel(eyebrow, color: WL.pencil, size: 11, tracking: 2.5)
            Text(title).font(WL.display(40)).foregroundStyle(WL.cream)
        }
    }
}

private struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(WL.cream).frame(width: 40, height: 40)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Library

struct LibraryView: View {
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void
    @State private var query = ""

    private var results: [Track] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SampleData.tracks }
        return SampleData.tracks.filter { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(eyebrow: "White Label", title: "Library")

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(WL.pencil)
                    TextField("Search songs, artists", text: $query)
                        .font(WL.text(15)).foregroundStyle(WL.cream).tint(WL.cobalt)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(WL.panel))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(WL.cream.opacity(0.08), lineWidth: 1))

                VStack(alignment: .leading, spacing: 12) {
                    MonoLabel("Songs · \(results.count)", color: WL.pencil, size: 10, tracking: 2)
                    VStack(spacing: 0) {
                        ForEach(results) { t in
                            Button { openSong(t.id) } label: {
                                SongRow(track: t, store: store,
                                        trailing: store.openCount(t.id) > 0 ? "\(store.openCount(t.id)) open" : nil,
                                        trailingColor: WL.redline)
                            }.buttonStyle(.plain)
                        }
                    }
                }

                if query.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        MonoLabel("Projects", color: WL.pencil, size: 10, tracking: 2)
                        VStack(spacing: 0) {
                            ForEach(SampleData.rooms) { rm in
                                NavigationLink(value: rm) { roomRow(rm) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 150)
        }
        .scrollIndicators(.hidden)
        .background(WL.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func roomRow(_ rm: Room) -> some View {
        let cover = rm.trackIDs.compactMap { SampleData.track($0) }.first
        return HStack(spacing: 13) {
            if let cover { trackSwatch(cover, 44) }
            VStack(alignment: .leading, spacing: 3) {
                Text(rm.title).font(WL.display(17)).foregroundStyle(WL.cream)
                MonoLabel("\(rm.artist) · \(rm.trackIDs.count) songs", color: WL.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(WL.pencil)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())
    }
}

// MARK: - Inbox

struct InboxView: View {
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void

    private var items: [InboxItem] { SampleData.inbox }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    MonoLabel("White Label", color: WL.pencil, size: 11, tracking: 2.5)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Inbox").font(WL.display(40)).foregroundStyle(WL.cream)
                        MonoLabel("\(items.filter { $0.isNew }.count) new", color: WL.redline, size: 11, tracking: 1.4)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(items) { item in
                        if let t = SampleData.track(item.trackID) {
                            Button { openSong(t.id) } label: { inboxRow(item, t) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 150)
        }
        .scrollIndicators(.hidden)
        .background(WL.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func inboxRow(_ item: InboxItem, _ t: Track) -> some View {
        HStack(spacing: 13) {
            trackSwatch(t, 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayTitle(t.id, t.title)).font(WL.display(17)).foregroundStyle(WL.cream)
                MonoLabel("Shared by \(item.sharedBy) · \(item.context)", color: WL.pencil, size: 9, tracking: 1)
            }
            Spacer()
            if item.isNew {
                MonoLabel("New", color: WL.redline, size: 9, tracking: 1.4)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().stroke(WL.redline.opacity(0.5), lineWidth: 1))
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    var playlist: Playlist
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void

    private var tracks: [Track] { playlist.trackIDs.compactMap { SampleData.track($0) } }
    private var cover: Track? { tracks.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let cover {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [cover.mesh[0], cover.mesh[4], cover.mesh[8]],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 170)
                }
                VStack(alignment: .leading, spacing: 8) {
                    MonoLabel("Playlist", color: WL.pencil, size: 10, tracking: 2)
                    Text(playlist.title).font(WL.display(30)).foregroundStyle(WL.cream)
                    Text(playlist.subtitle).font(WL.text(14)).foregroundStyle(WL.pencil)
                    Button { if let f = tracks.first { openSong(f.id) } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill").font(.system(size: 12))
                            MonoLabel("Play all · \(tracks.count)", color: WL.black, size: 11, tracking: 1.4)
                        }
                        .foregroundStyle(WL.black)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(Capsule().fill(WL.cream))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                        Button { openSong(t.id) } label: {
                            HStack(spacing: 13) {
                                MonoLabel(String(format: "%02d", i + 1), color: WL.cobalt, size: 11, tracking: 1)
                                    .frame(width: 22, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(store.displayTitle(t.id, t.title)).font(WL.display(16)).foregroundStyle(WL.cream)
                                    MonoLabel("\(t.artist) · \(t.versionLabel)", color: WL.pencil, size: 9, tracking: 1.2)
                                }
                                Spacer()
                                Text(t.durationMs.clock).font(WL.mono(11)).foregroundStyle(WL.pencil)
                            }
                            .padding(.vertical, 11)
                            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 150)
        }
        .scrollIndicators(.hidden)
        .background(WL.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, 16).padding(.top, 6) }
    }
}

// MARK: - Room / project detail

struct RoomDetailView: View {
    var room: Room
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void

    private var tracks: [Track] { room.trackIDs.compactMap { SampleData.track($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    MonoLabel("Project", color: WL.pencil, size: 10, tracking: 2)
                    Text(room.title).font(WL.display(32)).foregroundStyle(WL.cream)
                    MonoLabel("\(room.artist) · \(tracks.count) songs", color: WL.pencil, size: 10, tracking: 1.2)
                }
                .padding(.top, 40)

                VStack(spacing: 0) {
                    ForEach(tracks) { t in
                        Button { openSong(t.id) } label: {
                            SongRow(track: t, store: store,
                                    trailing: store.openCount(t.id) > 0 ? "\(store.openCount(t.id)) open" : nil,
                                    trailingColor: WL.redline)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 150)
        }
        .scrollIndicators(.hidden)
        .background(WL.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, 16).padding(.top, 6) }
    }
}
