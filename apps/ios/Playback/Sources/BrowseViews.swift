import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Shared bits

private func libraryDragPayload(_ trackID: String) -> String { "library-song:\(trackID)" }
private func libraryTrackID(from payload: String?) -> String? {
    guard let payload, payload.hasPrefix("library-song:") else { return nil }
    return String(payload.dropFirst("library-song:".count))
}

private func playlistDragPayload(_ playlistID: String, _ trackID: String) -> String {
    "playlist-song:\(playlistID):\(trackID)"
}
private func playlistTrackID(from payload: String?, playlistID: String) -> String? {
    let prefix = "playlist-song:\(playlistID):"
    guard let payload, payload.hasPrefix(prefix) else { return nil }
    return String(payload.dropFirst(prefix.count))
}

private struct ImportedAudioSelection {
    var relativePath: String
    var fileName: String
    var displayName: String
    var title: String?
    var artist: String?
    var durationMs: Int
    var artwork: ImportedArtworkSelection?
}

private struct ImportedArtworkSelection: Equatable {
    var relativePath: String
    var fileName: String
    var displayName: String
    var paletteHexes: [UInt]?
}

private enum AudioImportError: LocalizedError {
    case noFile
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .noFile: return "Choose an audio file first."
        case .copyFailed: return "That file could not be imported."
        }
    }
}

private enum ArtworkImportError: LocalizedError {
    case invalidImage
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "That image could not be used as artwork."
        case .writeFailed: return "That artwork could not be saved."
        }
    }
}

private enum ImportedMediaWriter {
    static func sanitizedFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = value.lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .reduce("") { partial, char in
                if char == "-", partial.last == "-" { return partial }
                return partial + char
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "media" : slug
    }

    static func importArtworkData(_ data: Data, sourceName: String) throws -> ImportedArtworkSelection {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { throw ArtworkImportError.invalidImage }
        let output = image.jpegData(compressionQuality: 0.92) ?? data
        let palette = paletteHexes(from: image)
        #else
        let output = data
        let palette: [UInt]? = nil
        #endif

        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("ImportedArtwork", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let stem = sanitizedFileName(sourceName)
        let fileName = "\(stem)-\(UUID().uuidString.prefix(8)).jpg"
        let destination = directory.appendingPathComponent(fileName)

        do {
            try output.write(to: destination, options: .atomic)
        } catch {
            throw ArtworkImportError.writeFailed
        }

        return ImportedArtworkSelection(
            relativePath: "ImportedArtwork/\(fileName)",
            fileName: fileName,
            displayName: sourceName,
            paletteHexes: palette
        )
    }

    #if canImport(UIKit)
    private static func paletteHexes(from image: UIImage) -> [UInt]? {
        guard let cgImage = image.cgImage else { return nil }
        let width = 3
        let height = 3
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            let r = UInt(bytes[offset])
            let g = UInt(bytes[offset + 1])
            let b = UInt(bytes[offset + 2])
            return (r << 16) | (g << 8) | b
        }
    }
    #endif
}

func trackSwatch(_ t: Track, _ s: CGFloat, radius: CGFloat = 8) -> some View {
    TrackArtwork(track: t, cornerRadius: radius)
        .frame(width: s, height: s)
}

// MARK: pinning helpers

func pinnedCover(_ ref: PinRef, _ store: WorkspaceStore) -> Track? {
    switch ref.kind {
    case .song: return store.track(ref.targetID)
    case .playlist: return store.playlist(ref.targetID)?.trackIDs.compactMap { store.track($0) }.first
    case .room: return store.rooms.first { $0.id == ref.targetID }?.trackIDs.compactMap { store.track($0) }.first
    }
}

func pinnedTitle(_ ref: PinRef, _ store: WorkspaceStore) -> String {
    switch ref.kind {
    case .song: return store.displayTitle(ref.targetID, store.track(ref.targetID)?.title ?? "—")
    case .playlist: return store.playlist(ref.targetID)?.title ?? "Playlist"
    case .room: return store.rooms.first { $0.id == ref.targetID }?.title ?? "Project"
    }
}

extension View {
    /// Long-press → pin / unpin from Home.
    func pinMenu(_ store: WorkspaceStore, _ ref: PinRef) -> some View {
        contextMenu {
            Button {
                store.togglePin(ref.id)
            } label: {
                Label(store.isPinned(ref.id) ? "Unpin from Home" : "Pin to Home",
                      systemImage: store.isPinned(ref.id) ? "pin.slash" : "pin")
            }
        }
    }

    func songActionsMenu(_ store: WorkspaceStore, _ track: Track) -> some View {
        modifier(SongActionsMenuModifier(store: store, track: track))
    }
}

private struct SongActionsMenuModifier: ViewModifier {
    var store: WorkspaceStore
    var track: Track
    @State private var showEdit = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                let pin = PinRef(kind: .song, targetID: track.id)
                Button {
                    store.togglePin(pin.id)
                } label: {
                    Label(store.isPinned(pin.id) ? "Unpin from Home" : "Pin to Home",
                          systemImage: store.isPinned(pin.id) ? "pin.slash" : "pin")
                }

                Menu {
                    Button {
                        _ = store.createKeptPlaylist(title: "\(track.title) List", trackIDs: [track.id])
                    } label: {
                        Label("New playlist from song", systemImage: "text.badge.plus")
                    }
                    ForEach(store.playlists) { playlist in
                        Button(playlist.title) {
                            store.addTrack(track.id, toPlaylist: playlist.id)
                        }
                    }
                } label: {
                    Label("Add to playlist", systemImage: "plus.square.on.square")
                }

                Menu {
                    ForEach(store.rooms) { room in
                        Button(room.title) {
                            store.addTrack(track.id, toProject: room.id)
                        }
                    }
                } label: {
                    Label("Add to project", systemImage: "folder.badge.plus")
                }

                if store.isEditableTrack(track.id) {
                    Divider()
                    Button {
                        showEdit = true
                    } label: {
                        Label("Edit song info", systemImage: "slider.horizontal.3")
                    }
                    if store.isCustomTrack(track.id) {
                        Button(role: .destructive) {
                            store.deleteTrack(track.id)
                        } label: {
                            Label("Delete imported song", systemImage: "trash")
                        }
                    }
                }
            }
            .sheet(isPresented: $showEdit) {
                EditSongSheet(trackID: track.id, store: store)
            }
    }
}

struct SongRow: View {
    var track: Track
    var store: WorkspaceStore
    var trailing: String? = nil
    var trailingColor: Color = PB.pencil
    var showsDragHandle = false

    var body: some View {
        HStack(spacing: 13) {
            trackSwatch(track, 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayTitle(track.id, track.title)).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel("\(track.artist) · \(track.versionLabel)", color: PB.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            if let trailing { MonoLabel(trailing, color: trailingColor, size: 9, tracking: 1) }
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PB.pencil)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())
    }
}

private struct ScreenHeader: View {
    var eyebrow: String  // kept for API compat but ignored — wordmark always shows
    var title: String
    var isPlaying: Bool = false
    var body: some View {
        AppScreenHeader(title: title, isPlaying: isPlaying)
    }
}

struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PB.cream).frame(width: 40, height: 40)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
    }
}

private enum BulkSelectionMode {
    case selecting
    case holding

    var title: String {
        switch self {
        case .selecting: return "Selected"
        case .holding: return "Holding"
        }
    }
}

private struct SelectionMark: View {
    var isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? PB.cobalt : PB.cream.opacity(0.28), lineWidth: 1.2)
                .background(Circle().fill(isSelected ? PB.cobalt : PB.panel.opacity(0.4)))
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(PB.cream)
            }
        }
        .frame(width: 22, height: 22)
        .frame(width: 32, height: 44)
        .accessibilityHidden(true)
    }
}

private struct BulkSongActionBar: View {
    var count: Int
    var mode: BulkSelectionMode
    var playlists: [Playlist]
    var rooms: [Room]
    var projectLabel: String = "Project"
    var canDelete: Bool
    var removeLabel: String?
    var onNewPlaylist: () -> Void
    var onAddToPlaylist: (Playlist) -> Void
    var onMoveToProject: (Room) -> Void
    var onShare: () -> Void
    var onDelete: () -> Void
    var onRemove: (() -> Void)?
    var onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    MonoLabel(mode.title, color: mode == .holding ? PB.cobalt : PB.pencil, size: 9, tracking: 1.6)
                    Text("\(count) \(count == 1 ? "song" : "songs")")
                        .font(PB.display(20))
                        .foregroundStyle(PB.cream)
                }
                Spacer(minLength: 10)
                Button(action: onClear) {
                    MonoLabel("Discard", color: PB.pencil, size: 9, tracking: 1.4)
                        .frame(minWidth: 68, minHeight: 36)
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        Button {
                            onNewPlaylist()
                        } label: {
                            Label("New playlist from selection", systemImage: "text.badge.plus")
                        }
                        ForEach(playlists) { playlist in
                            Button(playlist.title) {
                                onAddToPlaylist(playlist)
                            }
                        }
                    } label: {
                        bulkPill("plus.square.on.square", "Playlist")
                    }

                    Menu {
                        if rooms.isEmpty {
                            Button("No projects yet") {}
                                .disabled(true)
                        } else {
                            ForEach(rooms) { room in
                                Button(room.title) {
                                    onMoveToProject(room)
                                }
                            }
                        }
                    } label: {
                        bulkPill("folder.badge.plus", projectLabel)
                    }

                    Button(action: onShare) {
                        bulkPill("square.and.arrow.up", "Share")
                    }
                    .buttonStyle(.plain)

                    if let removeLabel, let onRemove {
                        Button(role: .destructive, action: onRemove) {
                            bulkPill("minus.circle", removeLabel)
                        }
                        .buttonStyle(.plain)
                    }

                    if canDelete {
                        Button(role: .destructive, action: onDelete) {
                            bulkPill("trash", "Delete")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(PB.cream.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 24, y: 12)
    }

    private func bulkPill(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            MonoLabel(label, color: PB.cream, size: 9, tracking: 1.1)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
        .background(Capsule().fill(PB.panel.opacity(0.72)))
        .overlay(Capsule().strokeBorder(PB.cream.opacity(0.11), lineWidth: 1))
    }
}

private func copyShareLinks(_ tracks: [Track], store: WorkspaceStore) -> Bool {
    #if canImport(UIKit)
    UIPasteboard.general.string = tracks.map { track in
        "\(store.displayTitle(track.id, track.title)) — \(Config.shareURL(token: track.id))"
    }.joined(separator: "\n")
    return true
    #else
    return false
    #endif
}

// MARK: - Library

struct LibraryView: View {
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void
    var onDropOnSong: (String, String) -> Void = { _, _ in }
    var onOpenPlaylist: (Playlist) -> Void = { _ in }
    @State private var query = ""
    @State private var showAddSong = false
    @State private var showNewPlaylist = false
    @State private var bulkMode: BulkSelectionMode?
    @State private var selectedTrackIDs: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var bulkMessage: String?

    private var results: [Track] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.tracks }
        return store.tracks.filter { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
    }
    private var selectedTracks: [Track] {
        store.tracks.filter { selectedTrackIDs.contains($0.id) }
    }
    private var selectedEditableCount: Int {
        selectedTrackIDs.filter { store.isCustomTrack($0) }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(eyebrow: "Playback", title: "Library", isPlaying: player.isPlaying)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(PB.pencil)
                    TextField("Search songs, artists", text: $query)
                        .font(PB.text(15)).foregroundStyle(PB.cream).tint(PB.cobalt)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.panel))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))

                libraryActions

                if let bulkMessage {
                    MonoLabel(bulkMessage, color: PB.green, size: 9, tracking: 1.2)
                        .transition(.opacity)
                }

                VStack(alignment: .leading, spacing: 12) {
                    MonoLabel("Songs · \(results.count)", color: PB.pencil, size: 10, tracking: 2)
                    if results.isEmpty {
                        searchEmptyState
                    } else {
                        VStack(spacing: 0) {
                            ForEach(results) { t in
                                librarySongItem(t)
                            }
                        }
                    }
                }

                if query.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        MonoLabel("Playlists", color: PB.pencil, size: 10, tracking: 2)
                        VStack(spacing: 0) {
                            ForEach(store.playlists) { pl in
                                NavigationLink(value: pl) { playlistRow(pl) }
                                    .buttonStyle(.plain)
                                    .pinMenu(store, PinRef(kind: .playlist, targetID: pl.id))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        MonoLabel("Projects", color: PB.pencil, size: 10, tracking: 2)
                        VStack(spacing: 0) {
                            ForEach(store.rooms) { rm in
                                NavigationLink(value: rm) { roomRow(rm) }
                                    .buttonStyle(.plain)
                                    .pinMenu(store, PinRef(kind: .room, targetID: rm.id))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 150)
        }
        .scrollIndicators(.hidden)
        .background {
            PB.black.ignoresSafeArea()
            AmbientDotField(isPlaying: player.isPlaying, positionMs: player.positionMs)
                .allowsHitTesting(false).ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            if let bulkMode, !selectedTrackIDs.isEmpty {
                BulkSongActionBar(
                    count: selectedTrackIDs.count,
                    mode: bulkMode,
                    playlists: store.playlists,
                    rooms: store.rooms,
                    projectLabel: "Project",
                    canDelete: selectedEditableCount > 0,
                    removeLabel: nil,
                    onNewPlaylist: createPlaylistFromSelection,
                    onAddToPlaylist: addSelection(to:),
                    onMoveToProject: addSelection(to:),
                    onShare: shareSelection,
                    onDelete: { confirmBulkDelete = true },
                    onRemove: nil,
                    onClear: clearSelection
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 94)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedTrackIDs)
        .confirmationDialog(
            "Delete imported songs?",
            isPresented: $confirmBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedEditableCount) imported \(selectedEditableCount == 1 ? "song" : "songs")", role: .destructive) {
                deleteEditableSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only songs imported on this device can be deleted. Shared catalog songs will stay in the library.")
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var libraryActions: some View {
        HStack(spacing: 10) {
            libraryActionButton("plus", "Add song", allowsWrap: false) { showAddSong = true }
            libraryActionButton("text.badge.plus", "New playlist") { showNewPlaylist = true }
            libraryActionButton(bulkMode == nil ? "checkmark.circle" : "xmark.circle",
                                bulkMode == nil ? "Select" : "Done",
                                allowsWrap: false) {
                if bulkMode == nil {
                    bulkMode = .selecting
                } else {
                    clearSelection()
                }
            }
        }
        .sheet(isPresented: $showAddSong) {
            AddSongSheet(store: store, player: player)
        }
        .sheet(isPresented: $showNewPlaylist) {
            NewPlaylistSheet(store: store, player: player) { playlist in
                onOpenPlaylist(playlist)
            }
        }
    }

    private func libraryActionButton(_ icon: String, _ title: String, allowsWrap: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                MonoLabel(title, color: PB.cream, size: 10, tracking: 1.2)
                    .lineLimit(allowsWrap ? 2 : 1)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.panel))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func librarySongItem(_ t: Track) -> some View {
        HStack(spacing: 8) {
            if bulkMode != nil {
                Button { toggleSelection(t.id) } label: {
                    SelectionMark(isSelected: selectedTrackIDs.contains(t.id))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selectedTrackIDs.contains(t.id) ? "Deselect \(store.displayTitle(t.id, t.title))" : "Select \(store.displayTitle(t.id, t.title))")
            }

            Button {
                if bulkMode != nil {
                    toggleSelection(t.id)
                } else {
                    openSong(t.id)
                }
            } label: {
                SongRow(track: t, store: store,
                        trailing: store.openCount(t.id) > 0 ? "\(store.openCount(t.id)) open" : nil,
                        trailingColor: PB.redline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                beginSelection(with: t.id, mode: .holding)
            })

            if bulkMode == nil {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PB.pencil)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .draggable(libraryDragPayload(t.id)) {
                        SongRow(track: t, store: store).frame(width: 280).opacity(0.9)
                    }
                    .accessibilityLabel("Drag \(store.displayTitle(t.id, t.title)) onto another song to create a playlist")
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard bulkMode == nil else { return false }
            guard let dropped = libraryTrackID(from: ids.first), dropped != t.id else { return false }
            onDropOnSong(dropped, t.id)
            return true
        }
        .songActionsMenu(store, t)
    }

    private func beginSelection(with id: String, mode: BulkSelectionMode) {
        bulkMode = mode
        selectedTrackIDs.insert(id)
    }

    private func toggleSelection(_ id: String) {
        if bulkMode == nil { bulkMode = .selecting }
        if selectedTrackIDs.contains(id) {
            selectedTrackIDs.remove(id)
            if selectedTrackIDs.isEmpty { bulkMode = .selecting }
        } else {
            selectedTrackIDs.insert(id)
        }
    }

    private func clearSelection() {
        selectedTrackIDs.removeAll()
        bulkMode = nil
    }

    private func createPlaylistFromSelection() {
        let tracks = selectedTracks
        guard !tracks.isEmpty else { return }
        let playlist = store.createKeptPlaylist(
            title: tracks.count == 1 ? "\(tracks[0].title) List" : "Selected Songs",
            trackIDs: tracks.map(\.id)
        )
        showBulkMessage("Playlist created")
        clearSelection()
        onOpenPlaylist(playlist)
    }

    private func addSelection(to playlist: Playlist) {
        selectedTracks.forEach { store.addTrack($0.id, toPlaylist: playlist.id) }
        showBulkMessage("Added to \(playlist.title)")
        clearSelection()
    }

    private func addSelection(to room: Room) {
        selectedTracks.forEach { store.addTrack($0.id, toProject: room.id) }
        showBulkMessage("Added to \(room.title)")
        clearSelection()
    }

    private func shareSelection() {
        guard copyShareLinks(selectedTracks, store: store) else { return }
        showBulkMessage("Share links copied")
        clearSelection()
    }

    private func deleteEditableSelection() {
        let ids = selectedTrackIDs.filter { store.isCustomTrack($0) }
        ids.forEach { store.deleteTrack($0) }
        showBulkMessage(ids.isEmpty ? "No imported songs selected" : "Deleted \(ids.count)")
        clearSelection()
    }

    private func showBulkMessage(_ message: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            bulkMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if bulkMessage == message {
                withAnimation(.easeInOut(duration: 0.18)) { bulkMessage = nil }
            }
        }
    }

    private var searchEmptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("No matches").font(PB.display(20)).foregroundStyle(PB.cream)
            MonoLabel("Try another song or artist", color: PB.pencil, size: 9, tracking: 1.2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
    }

    private func roomRow(_ rm: Room) -> some View {
        let cover = rm.trackIDs.compactMap { store.track($0) }.first
        return HStack(spacing: 13) {
            if let cover { trackSwatch(cover, 44) }
            VStack(alignment: .leading, spacing: 3) {
                Text(rm.title).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel("\(rm.artist) · \(rm.trackIDs.count) songs", color: PB.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(PB.pencil)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())
    }

    private func playlistRow(_ pl: Playlist) -> some View {
        let cover = pl.trackIDs.compactMap { store.track($0) }.first
        return HStack(spacing: 13) {
            if let cover { trackSwatch(cover, 44) }
            VStack(alignment: .leading, spacing: 3) {
                Text(pl.title).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel("\(pl.trackIDs.count) tracks", color: PB.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(PB.pencil)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())
    }
}

struct AddSongSheet: View {
    var store: WorkspaceStore
    var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var project = ""
    @State private var version = "Demo v1"
    @State private var duration = "3:00"
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var importedAudio: ImportedAudioSelection?
    @State private var importedArtwork: ImportedArtworkSelection?
    @State private var artworkItem: PhotosPickerItem?
    @State private var artworkError: String?
    @State private var importError: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    audioPicker
                    artworkPicker
                    sheetField("Title", text: $title, placeholder: "Song title")
                    sheetField("Artist", text: $artist, placeholder: "Artist")
                    sheetField("Project", text: $project, placeholder: "Project or room")
                    sheetField("Version", text: $version, placeholder: "Demo v1")
                    sheetField("Length", text: $duration, placeholder: "3:00")

                    Button {
                        saveSong()
                    } label: {
                        Text(isSaving ? "SAVING" : "ADD SONG").font(PB.mono(11)).tracking(1.5).foregroundStyle(PB.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(Capsule().fill(canSave ? PB.cream : PB.pencil))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.55)
                }
                .padding(22)
            }
            .background(PB.black)
            .navigationTitle("Add song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(PB.mono(13)).foregroundStyle(PB.cobalt)
                }
            }
            .toolbarBackground(PB.black, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationBackground(PB.black)
        .foregroundStyle(PB.cream)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .onChange(of: artworkItem) { _, item in
            importArtwork(item)
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && importedAudio != nil && !isImporting && !isSaving
    }

    private func saveSong() {
        isSaving = true
        Task {
            let track = await store.uploadImportedSong(
                title: title,
                artist: artist,
                project: project,
                versionLabel: version,
                durationMs: parseDuration(duration),
                importedAudioPath: importedAudio?.relativePath,
                sourceFileName: importedAudio?.fileName,
                importedArtworkPath: importedArtwork?.relativePath,
                artworkPalette: importedArtwork?.paletteHexes
            )
            await MainActor.run {
                player.replaceQueue(store.tracks)
                player.open(track.id)
                isSaving = false
                dismiss()
            }
        }
    }

    private var audioPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("Audio file", color: PB.pencil, size: 10, tracking: 2)
            Button { showImporter = true } label: {
                HStack(spacing: 13) {
                    Image(systemName: importedAudio == nil ? "music.note" : "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(importedAudio == nil ? PB.cream : PB.green)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(importedAudio?.displayName ?? "Choose audio")
                            .font(PB.text(16)).foregroundStyle(PB.cream)
                            .lineLimit(1)
                        MonoLabel(importedAudio == nil ? "MP3 · M4A · WAV · AIFF" : "\(duration) · copied into Playback",
                                  color: importError == nil ? PB.pencil : PB.redline,
                                  size: 9,
                                  tracking: 1)
                    }
                    Spacer()
                    if isImporting {
                        ProgressView().tint(PB.cream)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PB.pencil)
                    }
                }
                .padding(15)
                .frame(minHeight: 64)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isImporting)
            .accessibilityLabel("Choose audio")

            if let importError {
                MonoLabel(importError, color: PB.redline, size: 9, tracking: 0.8)
            }
        }
    }

    private var artworkPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("Artwork", color: PB.pencil, size: 10, tracking: 2)
            PhotosPicker(selection: $artworkItem, matching: .images) {
                HStack(spacing: 13) {
                    artworkPreview(path: importedArtwork?.relativePath)
                        .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(importedArtwork?.displayName ?? "Choose artwork")
                            .font(PB.text(16)).foregroundStyle(PB.cream)
                            .lineLimit(1)
                        MonoLabel(importedArtwork == nil ? "Optional · image from Photos" : "Artwork saved with song",
                                  color: artworkError == nil ? PB.pencil : PB.redline,
                                  size: 9,
                                  tracking: 1)
                    }
                    Spacer()
                    if importedArtwork != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(PB.green)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(PB.pencil)
                    }
                }
                .padding(15)
                .frame(minHeight: 82)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose artwork")

            if importedArtwork != nil {
                Button { importedArtwork = nil; artworkItem = nil } label: {
                    MonoLabel("Remove artwork", color: PB.pencil, size: 9, tracking: 1)
                        .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
            }

            if let artworkError {
                MonoLabel(artworkError, color: PB.redline, size: 9, tracking: 0.8)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                importError = AudioImportError.noFile.localizedDescription
                return
            }
            isImporting = true
            importError = nil
            Task {
                do {
                    let selection = try await Task.detached(priority: .userInitiated) {
                        try await Self.importAudio(from: url)
                    }.value
                    await MainActor.run {
                        importedAudio = selection
                        duration = selection.durationMs.clock
                        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            title = selection.title ?? selection.displayName
                        }
                        if artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let importedArtist = selection.artist {
                            artist = importedArtist
                        }
                        if importedArtwork == nil, let artwork = selection.artwork {
                            importedArtwork = artwork
                        }
                        isImporting = false
                    }
                } catch {
                    await MainActor.run {
                        importError = error.localizedDescription
                        isImporting = false
                    }
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    nonisolated private static func importAudio(from sourceURL: URL) async throws -> ImportedAudioSelection {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("ImportedAudio", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let stem = sanitizedFileName(sourceURL.deletingPathExtension().lastPathComponent)
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension.lowercased()
        let fileName = "\(stem)-\(UUID().uuidString.prefix(8)).\(ext)"
        let destination = directory.appendingPathComponent(fileName)

        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw AudioImportError.copyFailed
        }

        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        let durationMs = seconds.isFinite && seconds > 0 ? Int(seconds * 1000) : 180_000
        var metadataTitle: String?
        var metadataArtist: String?
        var embeddedArtwork: ImportedArtworkSelection?
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        for item in metadata {
            guard let key = item.commonKey?.rawValue else { continue }
            let value = try? await item.load(.stringValue)
            if key == "title", let value, !value.isEmpty { metadataTitle = value }
            if key == "artist", let value, !value.isEmpty { metadataArtist = value }
            if key == "artwork", embeddedArtwork == nil, let data = try? await item.load(.dataValue) {
                embeddedArtwork = try? ImportedMediaWriter.importArtworkData(data, sourceName: sourceURL.deletingPathExtension().lastPathComponent)
            }
        }

        return ImportedAudioSelection(
            relativePath: "ImportedAudio/\(fileName)",
            fileName: sourceURL.lastPathComponent,
            displayName: sourceURL.deletingPathExtension().lastPathComponent,
            title: metadataTitle,
            artist: metadataArtist,
            durationMs: max(15_000, durationMs),
            artwork: embeddedArtwork
        )
    }

    nonisolated private static func sanitizedFileName(_ value: String) -> String {
        ImportedMediaWriter.sanitizedFileName(value)
    }

    private func importArtwork(_ item: PhotosPickerItem?) {
        guard let item else { return }
        artworkError = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ArtworkImportError.invalidImage
                }
                let selection = try ImportedMediaWriter.importArtworkData(data, sourceName: title.isEmpty ? "artwork" : title)
                await MainActor.run {
                    importedArtwork = selection
                }
            } catch {
                await MainActor.run {
                    artworkError = error.localizedDescription
                }
            }
        }
    }

    private func artworkPreview(path: String?) -> some View {
        ZStack {
            if let path,
               let image = TrackArtworkLoader.uiImage(importedPath: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                MeshCover(colors: [PB.cobalt, PB.paleCobalt, PB.paleCoral, PB.panel, PB.cobalt, PB.cream, PB.black, PB.green, PB.paleGreen],
                          animate: false,
                          fillsSafeArea: false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PB.cream.opacity(0.14), lineWidth: 0.75))
    }
}

struct EditSongSheet: View {
    let trackID: String
    var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var project = ""
    @State private var version = ""
    @State private var importedArtwork: ImportedArtworkSelection?
    @State private var artworkItem: PhotosPickerItem?
    @State private var artworkError: String?
    @State private var didLoad = false

    private var track: Track? { store.track(trackID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if track == nil {
                        Text("Song unavailable")
                            .font(PB.display(22))
                            .foregroundStyle(PB.cream)
                    } else {
                        artworkPicker
                        sheetField("Title", text: $title, placeholder: "Song title")
                        sheetField("Artist", text: $artist, placeholder: "Artist")
                        sheetField("Project", text: $project, placeholder: "Project or room")
                        sheetField("Version", text: $version, placeholder: "Demo v1")

                        Button {
                            store.updateTrack(
                                trackID,
                                title: title,
                                artist: artist,
                                project: project,
                                versionLabel: version,
                                importedArtworkPath: importedArtwork?.relativePath,
                                artworkPalette: importedArtwork?.paletteHexes
                            )
                            dismiss()
                        } label: {
                            Text("SAVE CHANGES").font(PB.mono(11)).tracking(1.5).foregroundStyle(PB.black)
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(Capsule().fill(canSave ? PB.cream : PB.pencil))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSave)
                        .opacity(canSave ? 1 : 0.55)
                    }
                }
                .padding(22)
            }
            .background(PB.black)
            .navigationTitle("Edit song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(PB.mono(13)).foregroundStyle(PB.cobalt)
                }
            }
            .toolbarBackground(PB.black, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationBackground(PB.black)
        .foregroundStyle(PB.cream)
        .onAppear(perform: loadTrack)
        .onChange(of: artworkItem) { _, item in
            importArtwork(item)
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var artworkPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("Artwork", color: PB.pencil, size: 10, tracking: 2)
            PhotosPicker(selection: $artworkItem, matching: .images) {
                HStack(spacing: 13) {
                    artworkPreview(path: importedArtwork?.relativePath)
                        .frame(width: 68, height: 68)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(importedArtwork?.displayName ?? "Choose artwork")
                            .font(PB.text(16)).foregroundStyle(PB.cream)
                            .lineLimit(1)
                        MonoLabel(importedArtwork == nil ? "Optional · image from Photos" : "Tap to change",
                                  color: artworkError == nil ? PB.pencil : PB.redline,
                                  size: 9,
                                  tracking: 1)
                    }
                    Spacer()
                    Image(systemName: importedArtwork == nil ? "photo" : "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(importedArtwork == nil ? PB.pencil : PB.green)
                }
                .padding(15)
                .frame(minHeight: 92)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)

            if importedArtwork != nil {
                Button {
                    importedArtwork = nil
                    artworkItem = nil
                } label: {
                    MonoLabel("Remove artwork", color: PB.pencil, size: 9, tracking: 1)
                        .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
            }

            if let artworkError {
                MonoLabel(artworkError, color: PB.redline, size: 9, tracking: 0.8)
            }
        }
    }

    private func loadTrack() {
        guard !didLoad, let track else { return }
        didLoad = true
        title = store.displayTitle(track.id, track.title)
        artist = track.artist
        project = track.label
        version = track.versionLabel
        if let path = track.importedArtworkPath {
            importedArtwork = ImportedArtworkSelection(
                relativePath: path,
                fileName: "Artwork",
                displayName: "Current artwork",
                paletteHexes: nil
            )
        }
    }

    private func importArtwork(_ item: PhotosPickerItem?) {
        guard let item else { return }
        artworkError = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ArtworkImportError.invalidImage
                }
                let selection = try ImportedMediaWriter.importArtworkData(
                    data,
                    sourceName: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "artwork" : title
                )
                await MainActor.run { importedArtwork = selection }
            } catch {
                await MainActor.run { artworkError = error.localizedDescription }
            }
        }
    }

    private func artworkPreview(path: String?) -> some View {
        ZStack {
            if let path,
               let image = TrackArtworkLoader.uiImage(importedPath: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let track {
                MeshCover(colors: track.mesh, animate: false, fillsSafeArea: false)
            } else {
                MeshCover(colors: [PB.cobalt, PB.paleCobalt, PB.paleCoral, PB.panel, PB.cobalt, PB.cream, PB.black, PB.green, PB.paleGreen],
                          animate: false,
                          fillsSafeArea: false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PB.cream.opacity(0.14), lineWidth: 0.75))
    }
}

struct NewPlaylistSheet: View {
    var store: WorkspaceStore
    var player: Player
    var onCreate: (Playlist) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var selected: Set<String> = []

    private var selectedTracks: [String] {
        store.tracks.filter { selected.contains($0.id) }.map(\.id)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sheetField("Title", text: $title, placeholder: "Playlist title")

                    VStack(alignment: .leading, spacing: 10) {
                        MonoLabel("Songs", color: PB.pencil, size: 10, tracking: 2)
                        VStack(spacing: 0) {
                            ForEach(store.tracks) { track in
                                Button { toggle(track.id) } label: {
                                    HStack(spacing: 13) {
                                        trackSwatch(track, 38)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(store.displayTitle(track.id, track.title))
                                                .font(PB.display(16)).foregroundStyle(PB.cream)
                                            MonoLabel(track.artist, color: PB.pencil, size: 9, tracking: 1)
                                        }
                                        Spacer()
                                        Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected.contains(track.id) ? PB.cobalt : PB.pencil)
                                    }
                                    .padding(13)
                                    .contentShape(Rectangle())
                                    .overlay(alignment: .bottom) { Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1) }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
                    }

                    Button {
                        let playlist = store.createKeptPlaylist(title: title, trackIDs: selectedTracks)
                        dismiss()
                        onCreate(playlist)
                    } label: {
                        Text("CREATE PLAYLIST").font(PB.mono(11)).tracking(1.5).foregroundStyle(PB.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(Capsule().fill(canCreate ? PB.cream : PB.pencil))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCreate)
                    .opacity(canCreate ? 1 : 0.55)
                }
                .padding(22)
            }
            .background(PB.black)
            .navigationTitle("New playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(PB.mono(13)).foregroundStyle(PB.cobalt)
                }
            }
            .toolbarBackground(PB.black, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationBackground(PB.black)
        .foregroundStyle(PB.cream)
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

struct NewProjectSheet: View {
    var store: WorkspaceStore
    var onCreate: (Room) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sheetField("Title", text: $title, placeholder: "Project title")
                    sheetField("Artist", text: $artist, placeholder: "Artist")

                    Button {
                        let room = store.createProject(title: title, artist: artist)
                        dismiss()
                        onCreate(room)
                    } label: {
                        Text("CREATE PROJECT").font(PB.mono(11)).tracking(1.5).foregroundStyle(PB.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(Capsule().fill(canCreate ? PB.cream : PB.pencil))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCreate)
                    .opacity(canCreate ? 1 : 0.55)
                }
                .padding(22)
            }
            .background(PB.black)
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(PB.mono(13)).foregroundStyle(PB.cobalt)
                }
            }
            .toolbarBackground(PB.black, for: .navigationBar)
        }
        .presentationDetents([.medium])
        .presentationBackground(PB.black)
        .foregroundStyle(PB.cream)
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@ViewBuilder
func sheetField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        MonoLabel(label, color: PB.pencil, size: 10, tracking: 2)
        TextField(placeholder, text: text)
            .font(PB.text(16)).foregroundStyle(PB.cream).tint(PB.cobalt)
            .padding(15)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
    }
}

func parseDuration(_ value: String) -> Int {
    let parts = value.split(separator: ":").compactMap { Int(String($0).trimmingCharacters(in: .whitespaces)) }
    if parts.count == 2 { return ((parts[0] * 60) + parts[1]) * 1000 }
    if let minutes = Int(value.trimmingCharacters(in: .whitespaces)) { return minutes * 60 * 1000 }
    return 180_000
}

// MARK: - Inbox

struct InboxView: View {
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void

    private var items: [InboxItem] { store.inbox }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AppScreenHeader(title: "Inbox", isPlaying: player.isPlaying) {
                    HStack(alignment: .center, spacing: 10) {
                        MonoLabel("\(store.inboxNewCount) new", color: PB.redline, size: 11, tracking: 1.4)
                        if store.inboxNewCount > 0 {
                            Button { store.markAllInboxHeard() } label: {
                                MonoLabel("Mark all heard", color: PB.cobalt, size: 9, tracking: 1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(Capsule().stroke(PB.cobalt.opacity(0.4), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(spacing: 0) {
                    ForEach(items) { item in
                        if let t = store.track(item.trackID) {
                            inboxItem(item, t)
                        }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 150)
        }
        .scrollIndicators(.hidden)
        .background {
            PB.black.ignoresSafeArea()
            AmbientDotField(isPlaying: player.isPlaying, positionMs: player.positionMs)
                .allowsHitTesting(false).ignoresSafeArea()
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func inboxItem(_ item: InboxItem, _ t: Track) -> some View {
        HStack(spacing: 10) {
            Button {
                store.markInboxHeard(item.id)
                openSong(t.id)
            } label: {
                inboxRow(item, t)
            }
            .buttonStyle(.plain)

            if item.isNew {
                Button { store.markInboxHeard(item.id) } label: {
                    MonoLabel("Heard", color: PB.cobalt, size: 9, tracking: 1.1)
                        .frame(minWidth: 54, minHeight: 36)
                        .background(Capsule().stroke(PB.cobalt.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contextMenu {
            Button(item.isNew ? "Mark heard" : "Mark new") { store.toggleInboxNew(item.id) }
            let pin = PinRef(kind: .song, targetID: t.id)
            Button { store.togglePin(pin.id) } label: {
                Label(store.isPinned(pin.id) ? "Unpin from Home" : "Pin to Home",
                      systemImage: store.isPinned(pin.id) ? "pin.slash" : "pin")
            }
            Menu {
                Button {
                    _ = store.createKeptPlaylist(title: "\(t.title) List", trackIDs: [t.id])
                } label: {
                    Label("New playlist from song", systemImage: "text.badge.plus")
                }
                ForEach(store.playlists) { playlist in
                    Button(playlist.title) { store.addTrack(t.id, toPlaylist: playlist.id) }
                }
            } label: {
                Label("Add to playlist", systemImage: "plus.square.on.square")
            }
            Menu {
                ForEach(store.rooms) { room in
                    Button(room.title) { store.addTrack(t.id, toProject: room.id) }
                }
            } label: {
                Label("Add to project", systemImage: "folder.badge.plus")
            }
            if store.isCustomTrack(t.id) {
                Divider()
                Button(role: .destructive) { store.deleteTrack(t.id) } label: {
                    Label("Delete imported song", systemImage: "trash")
                }
            }
        }
    }

    private func inboxRow(_ item: InboxItem, _ t: Track) -> some View {
        HStack(spacing: 13) {
            trackSwatch(t, 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayTitle(t.id, t.title)).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel("Shared by \(item.sharedBy) · \(item.context)", color: PB.pencil, size: 9, tracking: 1)
            }
            Spacer()
            if item.isNew {
                MonoLabel("New", color: PB.redline, size: 9, tracking: 1.4)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().stroke(PB.redline.opacity(0.5), lineWidth: 1))
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Playlist detail

private struct PlaylistEditNotice: Identifiable {
    let id = UUID()
    let message: String
}

/// Playlist — mirrors the Now Playing world: full-bleed living gradient with the
/// playlist name where the song title sits (a lighter, distinct cut), and the
/// running order elegantly beneath.
struct PlaylistDetailView: View {
    var playlist: Playlist
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void
    var openQueue: (String, [Track]) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var dropTargetID: String?
    @State private var playlistNotice: PlaylistEditNotice?
    @State private var undoOrder: [String]?
    @State private var bulkMode: BulkSelectionMode?
    @State private var selectedTrackIDs: Set<String> = []
    @State private var confirmBulkDelete = false

    private var live: Playlist { store.playlist(playlist.id) ?? playlist }
    private var tracks: [Track] { live.trackIDs.compactMap { store.track($0) } }
    private var cover: Track { tracks.first ?? store.tracks[0] }
    private var totalMs: Int { tracks.reduce(0) { $0 + $1.durationMs } }
    private var selectedTracks: [Track] { tracks.filter { selectedTrackIDs.contains($0.id) } }
    private var selectedEditableCount: Int { selectedTrackIDs.filter { store.isCustomTrack($0) }.count }

    var body: some View {
        ZStack {
            PB.black
            MeshCover(colors: cover.mesh)
                .overlay(scrim)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack { BackButton(); Spacer() }
                        .padding(.top, 4)

                    if store.isDraft(live.id) { draftBanner.padding(.top, 12) }

                    titleBlock
                        .padding(.top, store.isDraft(live.id) ? 18 : 40)

                    if let playlistNotice {
                        editNotice(playlistNotice)
                            .padding(.top, 16)
                    }

                    songs
                        .padding(.top, 30)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 150)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(PB.cream)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) {
            if let bulkMode, !selectedTrackIDs.isEmpty {
                BulkSongActionBar(
                    count: selectedTrackIDs.count,
                    mode: bulkMode,
                    playlists: store.playlists,
                    rooms: store.rooms,
                    projectLabel: "Project",
                    canDelete: selectedEditableCount > 0,
                    removeLabel: "Remove",
                    onNewPlaylist: createPlaylistFromSelection,
                    onAddToPlaylist: addSelection(to:),
                    onMoveToProject: addSelection(to:),
                    onShare: shareSelection,
                    onDelete: { confirmBulkDelete = true },
                    onRemove: removeSelectionFromPlaylist,
                    onClear: clearSelection
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 94)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedTrackIDs)
        .confirmationDialog(
            "Delete imported songs?",
            isPresented: $confirmBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedEditableCount) imported \(selectedEditableCount == 1 ? "song" : "songs")", role: .destructive) {
                deleteEditableSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only songs imported on this device can be deleted. Playlist membership for shared catalog songs will stay available.")
        }
        .onAppear { if !store.isDraft(live.id) { store.touch(PinRef(kind: .playlist, targetID: live.id).id) } }
        .onDisappear {
            // leaving a draft without keeping it = no changes
            if store.isDraft(live.id) { store.discardPlaylist(live.id) }
        }
    }

    private var draftBanner: some View {
        HStack(spacing: 12) {
            MonoLabel("New playlist", color: PB.cobalt, size: 10, tracking: 1.6)
            Spacer()
            Button { store.discardPlaylist(live.id); dismiss() } label: {
                MonoLabel("Discard", color: PB.pencil, size: 10, tracking: 1.4)
            }.buttonStyle(.plain)
            Button { store.keepPlaylist(live.id) } label: {
                Text("KEEP").font(PB.mono(10)).tracking(1.4).foregroundStyle(PB.black)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(PB.cream))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.cobalt.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(PB.cobalt.opacity(0.4), lineWidth: 1))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel("Playlist", color: PB.cobalt, size: 11, tracking: 2.5)
            Text(live.title)
                .font(PB.thin(46))                       // thin cut — distinct from a song title
                .foregroundStyle(PB.cream)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            MonoLabel("\(tracks.count) tracks · \(totalMs.clock) · drag handle to reorder", color: PB.cream.opacity(0.7), size: 10, tracking: 1.6)
            HStack(spacing: 10) {
                Button { if let f = tracks.first { openQueue(f.id, tracks) } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill").font(.system(size: 11))
                        MonoLabel("Play all", color: PB.black, size: 11, tracking: 1.5)
                    }
                    .foregroundStyle(PB.black)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(PB.cream))
                }
                .buttonStyle(.plain)

                Button {
                    if bulkMode == nil {
                        bulkMode = .selecting
                    } else {
                        clearSelection()
                    }
                } label: {
                    MonoLabel(bulkMode == nil ? "Select" : "Done", color: PB.cream, size: 11, tracking: 1.5)
                        .frame(minWidth: 74, minHeight: 38)
                        .background(Capsule().fill(PB.panel.opacity(0.72)))
                        .overlay(Capsule().strokeBorder(PB.cream.opacity(0.16), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
        }
    }

    private func editNotice(_ notice: PlaylistEditNotice) -> some View {
        HStack(spacing: 12) {
            MonoLabel(notice.message, color: PB.green, size: 10, tracking: 1.4)
            Spacer()
            if undoOrder != nil {
                Button { restoreLastChange() } label: {
                    MonoLabel("Undo", color: PB.cobalt, size: 10, tracking: 1.2)
                        .frame(minWidth: 44, minHeight: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.green.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(PB.green.opacity(0.32), lineWidth: 1))
    }

    private var songs: some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                HStack(spacing: 8) {
                    if bulkMode != nil {
                        Button { toggleSelection(t.id) } label: {
                            SelectionMark(isSelected: selectedTrackIDs.contains(t.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(selectedTrackIDs.contains(t.id) ? "Deselect \(store.displayTitle(t.id, t.title))" : "Select \(store.displayTitle(t.id, t.title))")
                    }

                    Button {
                        if bulkMode != nil {
                            toggleSelection(t.id)
                        } else {
                            openQueue(t.id, tracks)
                        }
                    } label: {
                        HStack(spacing: 14) {
                            MonoLabel(String(format: "%02d", i + 1), color: PB.cobalt, size: 11, tracking: 1)
                                .frame(width: 22, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.displayTitle(t.id, t.title)).font(PB.display(18)).foregroundStyle(PB.cream)
                                MonoLabel("\(t.artist) · \(t.versionLabel)", color: PB.cream.opacity(0.55), size: 9, tracking: 1.2)
                            }
                            Spacer()
                            Text(t.durationMs.clock).font(PB.mono(11)).foregroundStyle(PB.cream.opacity(0.5))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                        beginSelection(with: t.id, mode: .holding)
                    })

                    if bulkMode == nil {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(PB.cream.opacity(0.7))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .draggable(playlistDragPayload(live.id, t.id)) {
                                HStack(spacing: 10) {
                                    MonoLabel(String(format: "%02d", i + 1), color: PB.cobalt, size: 10, tracking: 1)
                                    Text(store.displayTitle(t.id, t.title)).font(PB.display(16)).foregroundStyle(PB.cream)
                                }
                                .padding(10).background(PB.panel)
                            }
                            .accessibilityLabel("Drag to reorder \(store.displayTitle(t.id, t.title))")
                    }
                }
                .padding(.vertical, 13)
                .background {
                    if dropTargetID == t.id {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(PB.cobalt.opacity(0.14))
                    }
                }
                .overlay(alignment: .bottom) { Rectangle().fill(PB.cream.opacity(0.08)).frame(height: 1) }
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { ids, _ in
                    guard bulkMode == nil else { return false }
                    guard let dragged = playlistTrackID(from: ids.first, playlistID: live.id), dragged != t.id else { return false }
                    reorder(dragged, before: t.id)
                    return true
                } isTargeted: { isTargeted in
                    dropTargetID = isTargeted ? t.id : (dropTargetID == t.id ? nil : dropTargetID)
                }
                .contextMenu {
                    Button(role: .destructive) { removeFromPlaylist(t.id) } label: {
                        Label("Remove from playlist", systemImage: "minus.circle")
                    }
                }
            }
        }
    }

    private func beginSelection(with id: String, mode: BulkSelectionMode) {
        bulkMode = mode
        selectedTrackIDs.insert(id)
    }

    private func toggleSelection(_ id: String) {
        if bulkMode == nil { bulkMode = .selecting }
        if selectedTrackIDs.contains(id) {
            selectedTrackIDs.remove(id)
            if selectedTrackIDs.isEmpty { bulkMode = .selecting }
        } else {
            selectedTrackIDs.insert(id)
        }
    }

    private func clearSelection() {
        selectedTrackIDs.removeAll()
        bulkMode = nil
    }

    private func createPlaylistFromSelection() {
        guard !selectedTracks.isEmpty else { return }
        let title = selectedTracks.count == 1 ? "\(selectedTracks[0].title) List" : "\(live.title) Selection"
        _ = store.createKeptPlaylist(title: title, trackIDs: selectedTracks.map(\.id))
        showNotice("Playlist created")
        clearSelection()
    }

    private func addSelection(to playlist: Playlist) {
        selectedTracks.forEach { store.addTrack($0.id, toPlaylist: playlist.id) }
        showNotice("Added to \(playlist.title)")
        clearSelection()
    }

    private func addSelection(to room: Room) {
        selectedTracks.forEach { store.addTrack($0.id, toProject: room.id) }
        showNotice("Added to \(room.title)")
        clearSelection()
    }

    private func shareSelection() {
        guard copyShareLinks(selectedTracks, store: store) else { return }
        showNotice("Share links copied")
        clearSelection()
    }

    private func removeSelectionFromPlaylist() {
        let ids = selectedTrackIDs
        guard !ids.isEmpty else { return }
        undoOrder = live.trackIDs
        ids.forEach { store.removeTrack($0, fromPlaylist: live.id) }
        showNotice("Removed \(ids.count)")
        clearSelection()
    }

    private func deleteEditableSelection() {
        let ids = selectedTrackIDs.filter { store.isCustomTrack($0) }
        ids.forEach { store.deleteTrack($0) }
        showNotice(ids.isEmpty ? "No imported songs selected" : "Deleted \(ids.count)")
        clearSelection()
    }

    private func reorder(_ dragged: String, before target: String) {
        let previous = live.trackIDs
        var order = previous
        order.removeAll { $0 == dragged }
        if let at = order.firstIndex(of: target) { order.insert(dragged, at: at) } else { order.append(dragged) }
        guard order != previous else { return }
        undoOrder = previous
        store.reorderPlaylist(live.id, order)
        showNotice("Reordered")
    }

    private func removeFromPlaylist(_ trackID: String) {
        let previous = live.trackIDs
        guard previous.contains(trackID) else { return }
        undoOrder = previous
        store.removeTrack(trackID, fromPlaylist: live.id)
        showNotice("Removed")
    }

    private func restoreLastChange() {
        guard let undoOrder else { return }
        store.reorderPlaylist(live.id, undoOrder)
        self.undoOrder = nil
        showNotice("Restored", clearsUndo: true)
    }

    private func showNotice(_ message: String, clearsUndo: Bool = false) {
        let notice = PlaylistEditNotice(message: message)
        withAnimation(.easeInOut(duration: 0.18)) { playlistNotice = notice }
        if clearsUndo { undoOrder = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            if playlistNotice?.id == notice.id {
                withAnimation(.easeInOut(duration: 0.18)) { playlistNotice = nil }
                if !clearsUndo { undoOrder = nil }
            }
        }
    }

    private var scrim: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.30), location: 0),
            .init(color: .black.opacity(0.04), location: 0.14),
            .init(color: .black.opacity(0.45), location: 0.40),
            .init(color: .black.opacity(0.88), location: 0.66),
            .init(color: PB.black, location: 1.0),
        ], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
}

// MARK: - Room / project detail

struct RoomDetailView: View {
    var room: Room
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void
    var openQueue: (String, [Track]) -> Void = { _, _ in }
    @State private var bulkMode: BulkSelectionMode?
    @State private var selectedTrackIDs: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var projectNotice: PlaylistEditNotice?

    private var live: Room { store.rooms.first { $0.id == room.id } ?? room }
    private var tracks: [Track] { live.trackIDs.compactMap { store.track($0) } }
    private var selectedTracks: [Track] { tracks.filter { selectedTrackIDs.contains($0.id) } }
    private var selectedEditableCount: Int { selectedTrackIDs.filter { store.isCustomTrack($0) }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        MonoLabel("Project", color: PB.pencil, size: 10, tracking: 2)
                        Text(live.title).font(PB.display(32)).foregroundStyle(PB.cream)
                        MonoLabel("\(live.artist) · \(tracks.count) songs", color: PB.pencil, size: 10, tracking: 1.2)
                    }
                    Spacer(minLength: 10)
                    Button {
                        if bulkMode == nil {
                            bulkMode = .selecting
                        } else {
                            clearSelection()
                        }
                    } label: {
                        MonoLabel(bulkMode == nil ? "Select" : "Done", color: PB.cream, size: 10, tracking: 1.4)
                            .frame(minWidth: 74, minHeight: 38)
                            .background(Capsule().fill(PB.panel.opacity(0.72)))
                            .overlay(Capsule().strokeBorder(PB.cream.opacity(0.16), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 40)

                if let projectNotice {
                    editNotice(projectNotice)
                }

                VStack(spacing: 0) {
                    ForEach(tracks) { t in
                        HStack(spacing: 8) {
                            if bulkMode != nil {
                                Button { toggleSelection(t.id) } label: {
                                    SelectionMark(isSelected: selectedTrackIDs.contains(t.id))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(selectedTrackIDs.contains(t.id) ? "Deselect \(store.displayTitle(t.id, t.title))" : "Select \(store.displayTitle(t.id, t.title))")
                            }

                            Button {
                                if bulkMode != nil {
                                    toggleSelection(t.id)
                                } else {
                                    openQueue(t.id, tracks)
                                }
                            } label: {
                                SongRow(track: t, store: store,
                                        trailing: store.openCount(t.id) > 0 ? "\(store.openCount(t.id)) open" : nil,
                                        trailingColor: PB.redline)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                                beginSelection(with: t.id, mode: .holding)
                            })
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                removeSelectionFromProject(ids: Set([t.id]))
                            } label: {
                                Label("Remove from project", systemImage: "minus.circle")
                            }
                        }
                        .songActionsMenu(store, t)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 150)
        }
        .scrollIndicators(.hidden)
        .background {
            PB.black.ignoresSafeArea()
            AmbientDotField(isPlaying: player.isPlaying, positionMs: player.positionMs)
                .allowsHitTesting(false).ignoresSafeArea()
        }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, 16).padding(.top, 6) }
        .overlay(alignment: .bottom) {
            if let bulkMode, !selectedTrackIDs.isEmpty {
                BulkSongActionBar(
                    count: selectedTrackIDs.count,
                    mode: bulkMode,
                    playlists: store.playlists,
                    rooms: store.rooms.filter { $0.id != live.id },
                    projectLabel: "Move",
                    canDelete: selectedEditableCount > 0,
                    removeLabel: "Remove",
                    onNewPlaylist: createPlaylistFromSelection,
                    onAddToPlaylist: addSelection(to:),
                    onMoveToProject: moveSelection(to:),
                    onShare: shareSelection,
                    onDelete: { confirmBulkDelete = true },
                    onRemove: { removeSelectionFromProject(ids: selectedTrackIDs) },
                    onClear: clearSelection
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 94)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedTrackIDs)
        .confirmationDialog(
            "Delete imported songs?",
            isPresented: $confirmBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedEditableCount) imported \(selectedEditableCount == 1 ? "song" : "songs")", role: .destructive) {
                deleteEditableSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only songs imported on this device can be deleted. Shared catalog songs will stay in the library.")
        }
        .onAppear { store.touch(PinRef(kind: .room, targetID: live.id).id) }
    }

    private func editNotice(_ notice: PlaylistEditNotice) -> some View {
        MonoLabel(notice.message, color: PB.green, size: 10, tracking: 1.4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.green.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(PB.green.opacity(0.32), lineWidth: 1))
    }

    private func beginSelection(with id: String, mode: BulkSelectionMode) {
        bulkMode = mode
        selectedTrackIDs.insert(id)
    }

    private func toggleSelection(_ id: String) {
        if bulkMode == nil { bulkMode = .selecting }
        if selectedTrackIDs.contains(id) {
            selectedTrackIDs.remove(id)
            if selectedTrackIDs.isEmpty { bulkMode = .selecting }
        } else {
            selectedTrackIDs.insert(id)
        }
    }

    private func clearSelection() {
        selectedTrackIDs.removeAll()
        bulkMode = nil
    }

    private func createPlaylistFromSelection() {
        guard !selectedTracks.isEmpty else { return }
        _ = store.createKeptPlaylist(title: "\(live.title) Selection", trackIDs: selectedTracks.map(\.id))
        showNotice("Playlist created")
        clearSelection()
    }

    private func addSelection(to playlist: Playlist) {
        selectedTracks.forEach { store.addTrack($0.id, toPlaylist: playlist.id) }
        showNotice("Added to \(playlist.title)")
        clearSelection()
    }

    private func moveSelection(to room: Room) {
        let ids = selectedTrackIDs
        ids.forEach {
            store.addTrack($0, toProject: room.id)
            store.removeTrack($0, fromProject: live.id)
        }
        showNotice("Moved to \(room.title)")
        clearSelection()
    }

    private func shareSelection() {
        guard copyShareLinks(selectedTracks, store: store) else { return }
        showNotice("Share links copied")
        clearSelection()
    }

    private func removeSelectionFromProject(ids: Set<String>) {
        ids.forEach { store.removeTrack($0, fromProject: live.id) }
        showNotice("Removed \(ids.count)")
        clearSelection()
    }

    private func deleteEditableSelection() {
        let ids = selectedTrackIDs.filter { store.isCustomTrack($0) }
        ids.forEach { store.deleteTrack($0) }
        showNotice(ids.isEmpty ? "No imported songs selected" : "Deleted \(ids.count)")
        clearSelection()
    }

    private func showNotice(_ message: String) {
        let notice = PlaylistEditNotice(message: message)
        withAnimation(.easeInOut(duration: 0.18)) { projectNotice = notice }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if projectNotice?.id == notice.id {
                withAnimation(.easeInOut(duration: 0.18)) { projectNotice = nil }
            }
        }
    }
}
