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

#if canImport(UIKit)
private struct PendingArtworkCrop: Identifiable {
    let id = UUID()
    let image: UIImage
    let sourceName: String
}
#endif

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
    static let marqueeAspectRatio: CGFloat = 3.0 / 4.0

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
        return try importArtworkImage(centerCrop(image, aspectRatio: marqueeAspectRatio), sourceName: sourceName)
        #else
        let output = data
        let palette: [UInt]? = nil
        return try writeArtworkData(output, sourceName: sourceName, palette: palette)
        #endif
    }

    #if canImport(UIKit)
    static func importArtworkImage(_ image: UIImage, sourceName: String) throws -> ImportedArtworkSelection {
        let output = image.jpegData(compressionQuality: 0.92) ?? Data()
        let palette = paletteHexes(from: image)
        return try writeArtworkData(output, sourceName: sourceName, palette: palette)
    }

    static func renderCrop(image: UIImage, scale: CGFloat, offset: CGSize, previewSize: CGSize) -> UIImage {
        let targetWidth: CGFloat = 1200
        let targetSize = CGSize(width: targetWidth, height: targetWidth / marqueeAspectRatio)
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, previewSize.width > 0, previewSize.height > 0 else {
            return centerCrop(image, aspectRatio: marqueeAspectRatio)
        }

        let fillScale = max(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * fillScale * scale, height: imageSize.height * fillScale * scale)
        let offsetScale = targetSize.width / previewSize.width
        let drawOrigin = CGPoint(
            x: (targetSize.width - drawSize.width) / 2 + offset.width * offsetScale,
            y: (targetSize.height - drawSize.height) / 2 + offset.height * offsetScale
        )

        return UIGraphicsImageRenderer(size: targetSize).image { _ in
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
    }

    static func clampedOffset(_ proposed: CGSize, image: UIImage, scale: CGFloat, previewSize: CGSize) -> CGSize {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, previewSize.width > 0, previewSize.height > 0 else {
            return .zero
        }
        let imageAspect = imageSize.width / imageSize.height
        let previewAspect = previewSize.width / previewSize.height
        let baseSize: CGSize = imageAspect > previewAspect
            ? CGSize(width: previewSize.height * imageAspect, height: previewSize.height)
            : CGSize(width: previewSize.width, height: previewSize.width / imageAspect)
        let maxX = max(0, (baseSize.width * scale - previewSize.width) / 2)
        let maxY = max(0, (baseSize.height * scale - previewSize.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private static func centerCrop(_ image: UIImage, aspectRatio: CGFloat) -> UIImage {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return image }
        let currentAspect = imageSize.width / imageSize.height
        let cropRect: CGRect
        if currentAspect > aspectRatio {
            let width = imageSize.height * aspectRatio
            cropRect = CGRect(x: (imageSize.width - width) / 2, y: 0, width: width, height: imageSize.height)
        } else {
            let height = imageSize.width / aspectRatio
            cropRect = CGRect(x: 0, y: (imageSize.height - height) / 2, width: imageSize.width, height: height)
        }
        guard let cgImage = image.cgImage?.cropping(to: cropRect.applying(CGAffineTransform(scaleX: image.scale, y: image.scale))) else {
            return image
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
    #endif

    private static func writeArtworkData(_ output: Data, sourceName: String, palette: [UInt]?) throws -> ImportedArtworkSelection {
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

#if canImport(UIKit)
private struct ArtworkCropSheet: View {
    let pending: PendingArtworkCrop
    let onComplete: (ImportedArtworkSelection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let cropSize = CGSize(width: width, height: width / ImportedMediaWriter.marqueeAspectRatio)
                    ZStack {
                        PB.black
                        Image(uiImage: pending.image)
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(scale)
                            .offset(offset)
                            .frame(width: cropSize.width, height: cropSize.height)
                    }
                    .frame(width: cropSize.width, height: cropSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(PB.cream.opacity(0.18), lineWidth: 1))
                    .gesture(cropGesture(previewSize: cropSize))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") { dismiss() }
                                .font(PB.mono(13))
                                .foregroundStyle(PB.pencil)
                        }
                        ToolbarItem(placement: .principal) {
                            Text("Frame artwork")
                                .font(PB.display(18))
                                .foregroundStyle(PB.cream)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { complete(previewSize: cropSize) }
                                .font(PB.mono(13))
                                .foregroundStyle(PB.cobalt)
                        }
                    }
                }
                .frame(maxHeight: 620)

                HStack {
                    Button("Reset") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            scale = 1
                            baseScale = 1
                            offset = .zero
                            baseOffset = .zero
                        }
                    }
                    .font(PB.mono(11))
                    .foregroundStyle(PB.pencil)
                    Spacer()
                }

                if let errorMessage {
                    MonoLabel(errorMessage, color: PB.redline, size: 9, tracking: 0.8)
                }
            }
            .padding(22)
            .background(PB.black)
            .toolbarBackground(PB.black, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationBackground(PB.black)
    }

    private func cropGesture(previewSize: CGSize) -> some Gesture {
        let drag = DragGesture()
            .onChanged { value in
                let proposed = CGSize(width: baseOffset.width + value.translation.width, height: baseOffset.height + value.translation.height)
                offset = ImportedMediaWriter.clampedOffset(proposed, image: pending.image, scale: scale, previewSize: previewSize)
            }
            .onEnded { _ in
                baseOffset = offset
            }

        let magnify = MagnificationGesture()
            .onChanged { value in
                let nextScale = min(max(baseScale * value, 1), 4)
                scale = nextScale
                offset = ImportedMediaWriter.clampedOffset(offset, image: pending.image, scale: nextScale, previewSize: previewSize)
            }
            .onEnded { _ in
                baseScale = scale
                offset = ImportedMediaWriter.clampedOffset(offset, image: pending.image, scale: scale, previewSize: previewSize)
                baseOffset = offset
            }

        return drag.simultaneously(with: magnify)
    }

    private func complete(previewSize: CGSize) {
        do {
            let cropped = ImportedMediaWriter.renderCrop(image: pending.image, scale: scale, offset: offset, previewSize: previewSize)
            let selection = try ImportedMediaWriter.importArtworkImage(cropped, sourceName: pending.sourceName)
            onComplete(selection)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif

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
                }

                Divider()
                Button(role: .destructive) {
                    store.deleteTrack(track.id)
                } label: {
                    Label("Delete song", systemImage: "trash")
                }
            }
            .sheet(isPresented: $showEdit) {
                EditSongSheet(trackID: track.id, store: store)
            }
    }
}

struct SongRowMenuAction: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String
    var role: ButtonRole? = nil
    var action: () -> Void
}

struct SongActionsButton: View {
    var store: WorkspaceStore
    var track: Track
    var extraActions: [SongRowMenuAction] = []
    @State private var showEdit = false

    var body: some View {
        Menu {
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
                if store.rooms.isEmpty {
                    Button("No projects yet") {}
                        .disabled(true)
                } else {
                    ForEach(store.rooms) { room in
                        Button(room.title) {
                            store.addTrack(track.id, toProject: room.id)
                        }
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
            }

            if !extraActions.isEmpty {
                Divider()
                ForEach(extraActions) { item in
                    Button(role: item.role, action: item.action) {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
            }

            Divider()
            Button(role: .destructive) {
                store.deleteTrack(track.id)
            } label: {
                Label("Delete song", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PB.pencil)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Actions for \(store.displayTitle(track.id, track.title))")
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

struct InteractiveSongItem<RowContent: View, IdleAccessory: View>: View {
    var track: Track
    var store: WorkspaceStore
    @Binding var bulkMode: BulkSelectionMode?
    @Binding var selectedTrackIDs: Set<String>
    var selectedTracks: [Track]
    var extraActions: [SongRowMenuAction] = []
    var onOpen: () -> Void
    var onSpringboardDrop: ([String]) -> Void
    @ViewBuilder var rowContent: () -> RowContent
    @ViewBuilder var idleAccessory: () -> IdleAccessory

    var body: some View {
        let inHolding = bulkMode == .holding && !selectedTrackIDs.isEmpty
        let isSelected = selectedTrackIDs.contains(track.id)
        let dropEnabled = bulkMode == nil || (inHolding && !isSelected)

        HStack(spacing: 8) {
            if bulkMode != nil {
                Button { toggleSelection() } label: {
                    SelectionMark(isSelected: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected
                    ? "Deselect \(store.displayTitle(track.id, track.title))"
                    : "Select \(store.displayTitle(track.id, track.title))")
            }

            Button {
                handleTap()
            } label: {
                rowContent()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The .draggable lift recognizer plus a simultaneous long-press kept
            // winning touch arbitration, so the Button's own tap never fired.
            // Arbitrate explicitly instead: a 0.35s hold enters holding mode,
            // anything shorter is a tap and always reaches onOpen.
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.35)
                    .onEnded { _ in beginHolding() }
                    .exclusively(before: TapGesture().onEnded { handleTap() })
            )

            if inHolding && isSelected {
                PileBadge(count: selectedTrackIDs.count)
                    .padding(.trailing, 4)
            } else if bulkMode == nil {
                idleAccessory()
                SongActionsButton(store: store, track: track, extraActions: extraActions)
            }
        }
        .springboardDraggable(trackID: track.id, track: track, store: store,
                              enabled: bulkMode == nil)
        .springboardPileDraggable(pileIDs: Array(selectedTrackIDs),
                                  pileTracks: selectedTracks,
                                  store: store,
                                  enabled: inHolding && isSelected)
        .springboardDropTarget(targetID: track.id, enabled: dropEnabled,
                               onDrop: onSpringboardDrop)
        .selectionDragTarget(id: track.id)
    }

    private func handleTap() {
        if bulkMode != nil {
            toggleSelection()
        } else {
            onOpen()
        }
    }

    private func beginHolding() {
        bulkMode = .holding
        selectedTrackIDs.insert(track.id)
    }

    private func toggleSelection() {
        if bulkMode == nil { bulkMode = .selecting }
        if selectedTrackIDs.contains(track.id) {
            selectedTrackIDs.remove(track.id)
            if selectedTrackIDs.isEmpty { bulkMode = .selecting }
        } else {
            selectedTrackIDs.insert(track.id)
        }
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

enum BulkSelectionMode {
    case selecting
    case holding

    var title: String {
        switch self {
        case .selecting: return "Selected"
        case .holding: return "Holding"
        }
    }
}

struct SelectionMark: View {
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

struct BulkSongActionBar: View {
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

func copyShareLinks(_ tracks: [Track], store: WorkspaceStore) -> Bool {
    #if canImport(UIKit)
    if Config.useRemoteAPI {
        // API share links are per-song and async. For bulk selection, copy
        // titles only — individual sharing from the player menu gives real links.
        UIPasteboard.general.string = tracks.map { store.displayTitle($0.id, $0.title) }.joined(separator: "\n")
    } else {
        UIPasteboard.general.string = tracks.map { track in
            "\(store.displayTitle(track.id, track.title)) — \(Config.shareURL(token: track.id))"
        }.joined(separator: "\n")
    }
    return true
    #else
    return false
    #endif
}

// MARK: - Library

private enum LibraryCreationSheet: Identifiable {
    case song
    case playlist

    var id: String {
        switch self {
        case .song: return "song"
        case .playlist: return "playlist"
        }
    }
}

struct LibraryView: View {
    var player: Player
    var store: WorkspaceStore
    var openSong: (String) -> Void
    var onDropOnSong: ([String]) -> Void = { _ in }
    var onOpenPlaylist: (Playlist) -> Void = { _ in }
    @State private var creationSheet: LibraryCreationSheet?
    @State private var bulkMode: BulkSelectionMode?
    @State private var selectedTrackIDs: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var bulkMessage: String?
    @State private var selectionDragTargets: [SelectionDragTarget] = []

    private var artists: [ArtistSummary] { store.artistSummaries }
    private var results: [Track] {
        store.tracks
    }
    private var selectedTracks: [Track] {
        store.tracks.filter { selectedTrackIDs.contains($0.id) }
    }
    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                scrollToTopMarker()
                VStack(alignment: .leading, spacing: 26) {
                    AppScreenHeader(title: "Library", isPlaying: player.isPlaying) {
                        HStack(spacing: 10) {
                            if !store.tracks.isEmpty {
                                librarySelectButton
                            }
                            libraryAddMenu
                        }
                    }

                    if let bulkMessage {
                        MonoLabel(bulkMessage, color: PB.green, size: 9, tracking: 1.2)
                            .transition(.opacity)
                    }

                    librarySection("Artists", count: artists.count) {
                        if artists.isEmpty {
                            libraryEmptyRow("No artists yet")
                        } else {
                            ForEach(artists) { artist in
                                NavigationLink {
                                    ArtistDetailView(artist: artist, player: player, store: store, openQueue: { id, queue in
                                        openSong(id)
                                    })
                                } label: {
                                    artistRow(artist)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    librarySection("Playlists", count: store.playlists.count) {
                        if store.playlists.isEmpty {
                            libraryEmptyRow("No playlists yet")
                        } else {
                            ForEach(store.playlists) { pl in
                                NavigationLink(value: pl) { playlistRow(pl) }
                                    .buttonStyle(.plain)
                                    .pinMenu(store, PinRef(kind: .playlist, targetID: pl.id))
                            }
                        }
                    }

                    librarySection("Projects", count: store.rooms.count) {
                        if store.rooms.isEmpty {
                            libraryEmptyRow("No projects yet")
                        } else {
                            ForEach(store.rooms) { rm in
                                NavigationLink(value: rm) { roomRow(rm) }
                                    .buttonStyle(.plain)
                                    .pinMenu(store, PinRef(kind: .room, targetID: rm.id))
                            }
                        }
                    }

                    librarySection("Songs", count: results.count) {
                        if results.isEmpty {
                            libraryEmptyRow("No songs yet")
                        } else {
                            ForEach(results) { t in
                                librarySongItem(t)
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
            .overlay(alignment: .top) {
                TopTapScrollHotspot { scrollToTop(scrollProxy) }
            }
            .onPreferenceChange(SelectionDragTargetKey.self) { targets in
                selectionDragTargets = targets
            }
            .twoFingerSelection(
                enabled: !results.isEmpty,
                targets: selectionDragTargets,
                onSelect: selectDuringDrag
            )
            .overlay(alignment: .bottom) {
                if let bulkMode, !selectedTrackIDs.isEmpty {
                    BulkSongActionBar(
                        count: selectedTrackIDs.count,
                        mode: bulkMode,
                        playlists: store.playlists,
                        rooms: store.rooms,
                        projectLabel: "Project",
                        canDelete: true,
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
                "Delete selected songs?",
                isPresented: $confirmBulkDelete,
                titleVisibility: .visible
            ) {
                Button("Delete \(selectedTrackIDs.count) \(selectedTrackIDs.count == 1 ? "song" : "songs")", role: .destructive) {
                    deleteSelectedSongs()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the selected songs from your Playback library. Imported audio and artwork files on this device will be deleted.")
            }
            .sheet(item: $creationSheet) { sheet in
                switch sheet {
                case .song:
                    AddSongSheet(store: store, player: player)
                case .playlist:
                    NewPlaylistSheet(store: store, player: player) { playlist in
                        onOpenPlaylist(playlist)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var librarySelectButton: some View {
        Button {
            if bulkMode == nil {
                bulkMode = .selecting
            } else {
                clearSelection()
            }
        } label: {
            HeaderCircleIcon(systemName: bulkMode == nil ? "checkmark.circle" : "xmark.circle")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bulkMode == nil ? "Select songs" : "Done selecting")
    }

    private var libraryAddMenu: some View {
        Menu {
            Button { creationSheet = .song } label: {
                Label("Song(s)", systemImage: "music.note")
            }
            Button { creationSheet = .playlist } label: {
                Label("Playlist", systemImage: "text.badge.plus")
            }
        } label: {
            // Label the inner control too — the Menu surfaces it to VoiceOver
            // as an unnamed pop-up button otherwise.
            HeaderCircleIcon(systemName: "plus")
                .accessibilityLabel("Add")
        }
        .accessibilityLabel("Add")
    }

    private func librarySection<C: View>(_ title: String, count: Int, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MonoLabel("\(title) · \(count)", color: PB.pencil, size: 10, tracking: 2)
            VStack(spacing: 0) { content() }
        }
    }

    private func artistRow(_ artist: ArtistSummary) -> some View {
        let cover = artist.trackIDs.compactMap { store.track($0) }.first
        let projectText = artist.projectIDs.count == 1 ? "1 project" : "\(artist.projectIDs.count) projects"
        let songText = artist.trackIDs.count == 1 ? "1 song" : "\(artist.trackIDs.count) songs"
        return HStack(spacing: 13) {
            if let cover {
                trackSwatch(cover, 44)
            } else {
                InitialsCover(id: artist.id, name: artist.name, size: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel("\(songText) · \(projectText)", color: PB.pencil, size: 9, tracking: 1.2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(PB.pencil)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())
    }

    private func libraryEmptyRow(_ title: String) -> some View {
        HStack {
            MonoLabel(title, color: PB.pencil, size: 9, tracking: 1.2)
            Spacer()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.04)).frame(height: 1) }
    }

    private func librarySongItem(_ t: Track) -> some View {
        InteractiveSongItem(
            track: t,
            store: store,
            bulkMode: $bulkMode,
            selectedTrackIDs: $selectedTrackIDs,
            selectedTracks: selectedTracks,
            onOpen: { openSong(t.id) },
            onSpringboardDrop: onDropOnSong
        ) {
            SongRow(track: t, store: store,
                    trailing: store.openCount(t.id) > 0 ? "\(store.openCount(t.id)) open" : nil,
                    trailingColor: PB.redline)
        } idleAccessory: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PB.pencil)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Drag \(store.displayTitle(t.id, t.title)) onto another song to create a playlist")
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

    private func selectDuringDrag(_ id: String) {
        if bulkMode == nil { bulkMode = .selecting }
        selectedTrackIDs.insert(id)
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

    private func deleteSelectedSongs() {
        let ids = selectedTrackIDs
        let deleted = ids.reduce(0) { count, id in
            count + (store.deleteTrack(id) ? 1 : 0)
        }
        if !store.tracks.isEmpty { player.replaceQueue(store.tracks) }
        showBulkMessage(deleted == 0 ? "Nothing deleted" : "Deleted \(deleted)")
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
        let tracks = store.roomTracks(rm)
        let songText = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        // Skip the artist prefix when the project is self-titled — repeating
        // the title as the subtitle reads as duplicate context.
        let selfTitled = rm.title.compare(rm.artist, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        return HStack(spacing: 13) {
            if let cover = tracks.first {
                trackSwatch(cover, 44)
            } else {
                InitialsCover(id: rm.id, name: rm.title, size: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(rm.title).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel(selfTitled ? songText : "\(rm.artist) · \(songText)", color: PB.pencil, size: 9, tracking: 1.2)
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

struct ArtistDetailView: View {
    var artist: ArtistSummary
    var player: Player
    var store: WorkspaceStore
    var openQueue: (String, [Track]) -> Void
    @State private var bulkMode: BulkSelectionMode?
    @State private var selectedTrackIDs: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var artistNotice: PlaylistEditNotice?
    @State private var springboardPlaylist: Playlist?
    @State private var selectionDragTargets: [SelectionDragTarget] = []

    private var tracks: [Track] { store.artistTracks(artist) }
    private var projects: [Room] { store.artistProjects(artist) }
    private var selectedTracks: [Track] { tracks.filter { selectedTrackIDs.contains($0.id) } }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                scrollToTopMarker()
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            MonoLabel("Artist", color: PB.pencil, size: 10, tracking: 2)
                            Text(artist.name).font(PB.display(34)).foregroundStyle(PB.cream)
                            MonoLabel("\(tracks.count) songs · \(projects.count) projects", color: PB.pencil, size: 10, tracking: 1.1)
                        }
                        Spacer(minLength: 10)
                        if !tracks.isEmpty {
                            Button {
                                if bulkMode == nil {
                                    bulkMode = .selecting
                                } else {
                                    clearSelection()
                                }
                            } label: {
                                HeaderCircleIcon(systemName: bulkMode == nil ? "checkmark.circle" : "xmark.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(bulkMode == nil ? "Select songs" : "Done selecting")
                        }
                    }
                    .padding(.top, 40)

                    if let artistNotice {
                        editNotice(artistNotice)
                    }

                    if !projects.isEmpty {
                        artistSection("Projects") {
                            ForEach(projects) { room in
                                NavigationLink(value: room) {
                                    artistProjectRow(room)
                                }
                                .buttonStyle(.plain)
                                .pinMenu(store, PinRef(kind: .room, targetID: room.id))
                            }
                        }
                    }

                    artistSection("Songs") {
                        if tracks.isEmpty {
                            HStack {
                                MonoLabel("No songs yet", color: PB.pencil, size: 9, tracking: 1.2)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        } else {
                            ForEach(tracks) { track in
                                artistSongItem(track)
                            }
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
            .overlay(alignment: .top) {
                TopTapScrollHotspot { scrollToTop(scrollProxy) }
            }
            .overlay(alignment: .topLeading) { BackButton().padding(.leading, 16).padding(.top, 6) }
            .onPreferenceChange(SelectionDragTargetKey.self) { targets in
                selectionDragTargets = targets
            }
            .twoFingerSelection(
                enabled: !tracks.isEmpty,
                targets: selectionDragTargets,
                onSelect: selectDuringDrag
            )
            .overlay(alignment: .bottom) {
                if let bulkMode, !selectedTrackIDs.isEmpty {
                    BulkSongActionBar(
                        count: selectedTrackIDs.count,
                        mode: bulkMode,
                        playlists: store.playlists,
                        rooms: store.rooms,
                        projectLabel: "Project",
                        canDelete: true,
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
                "Delete selected songs?",
                isPresented: $confirmBulkDelete,
                titleVisibility: .visible
            ) {
                Button("Delete \(selectedTrackIDs.count) \(selectedTrackIDs.count == 1 ? "song" : "songs")", role: .destructive) {
                    deleteSelectedSongs()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the selected songs from your Playback library. Imported audio and artwork files on this device will be deleted.")
            }
            .sheet(item: $springboardPlaylist) { pl in
                PlaylistDetailView(playlist: pl, player: player, store: store,
                                   openSong: { id in openQueue(id, store.tracks) }, openQueue: openQueue)
            }
        }
    }

    private func artistSongItem(_ track: Track) -> some View {
        InteractiveSongItem(
            track: track,
            store: store,
            bulkMode: $bulkMode,
            selectedTrackIDs: $selectedTrackIDs,
            selectedTracks: selectedTracks,
            onOpen: { openQueue(track.id, tracks) },
            onSpringboardDrop: handleSpringboardDrop
        ) {
            SongRow(track: track, store: store,
                    trailing: store.openCount(track.id) > 0 ? "\(store.openCount(track.id)) open" : nil,
                    trailingColor: PB.redline)
        } idleAccessory: {
            EmptyView()
        }
    }

    private func handleSpringboardDrop(_ ids: [String]) {
        guard ids.count >= 2 else { return }
        let tracks = ids.compactMap { store.track($0) }
        let title = tracks.count == 2
            ? "\(tracks[0].title) + \(tracks[1].title)"
            : "\(tracks[0].title) + \(tracks.count - 1) more"
        let playlist = store.createKeptPlaylist(title: title, trackIDs: ids)
        clearSelection()
        withAnimation(.easeInOut(duration: 0.18)) { springboardPlaylist = playlist }
    }

    private func selectDuringDrag(_ id: String) {
        if bulkMode == nil { bulkMode = .selecting }
        selectedTrackIDs.insert(id)
    }

    private func clearSelection() {
        selectedTrackIDs.removeAll()
        bulkMode = nil
    }

    private func createPlaylistFromSelection() {
        guard !selectedTracks.isEmpty else { return }
        _ = store.createKeptPlaylist(title: "\(artist.name) Selection", trackIDs: selectedTracks.map(\.id))
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
        showNotice(Config.useRemoteAPI ? "Titles copied" : "Share links copied")
        clearSelection()
    }

    private func deleteSelectedSongs() {
        let ids = selectedTrackIDs
        let deleted = ids.reduce(0) { count, id in
            count + (store.deleteTrack(id) ? 1 : 0)
        }
        if !store.tracks.isEmpty { player.replaceQueue(store.tracks) }
        showNotice(deleted == 0 ? "Nothing deleted" : "Deleted \(deleted)")
        clearSelection()
    }

    private func showNotice(_ message: String) {
        let notice = PlaylistEditNotice(message: message)
        withAnimation(.easeInOut(duration: 0.18)) { artistNotice = notice }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if artistNotice?.id == notice.id {
                withAnimation(.easeInOut(duration: 0.18)) { artistNotice = nil }
            }
        }
    }

    private func editNotice(_ notice: PlaylistEditNotice) -> some View {
        MonoLabel(notice.message, color: PB.green, size: 10, tracking: 1.4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.green.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(PB.green.opacity(0.32), lineWidth: 1))
    }

    private func artistSection<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MonoLabel(title, color: PB.pencil, size: 10, tracking: 2)
            VStack(spacing: 0) { content() }
        }
    }

    private func artistProjectRow(_ room: Room) -> some View {
        let tracks = store.roomTracks(room)
        return HStack(spacing: 13) {
            if let cover = tracks.first {
                trackSwatch(cover, 44)
            } else {
                InitialsCover(id: room.id, name: room.title, size: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(room.title).font(PB.display(17)).foregroundStyle(PB.cream)
                MonoLabel(tracks.count == 1 ? "1 song" : "\(tracks.count) songs", color: PB.pencil, size: 9, tracking: 1.2)
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
    private enum AddSongField: Hashable {
        case artist
    }

    var store: WorkspaceStore
    var player: Player
    var initialAudioURL: URL? = nil
    var deleteInitialAudioAfterImport = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: AddSongField?
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
    #if canImport(UIKit)
    @State private var pendingArtworkCrop: PendingArtworkCrop?
    #endif
    @State private var importError: String?
    @State private var isSaving = false
    @State private var didImportInitialAudio = false
    @State private var showDiscardConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    audioPicker
                    artworkPicker
                    sheetField("Title", text: $title, placeholder: "Song title")
                    artistField
                    sheetField("Project", text: $project, placeholder: "Project or room")
                    sheetField("Version", text: $version, placeholder: "Demo v1")
                    sheetField("Length", text: $duration, placeholder: "3:00")
                }
                .padding(22)
            }
            .background(PB.black)
            .navigationTitle("Add song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        requestDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(PB.cobalt)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                    .accessibilityLabel("Close add song")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        saveSong()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .tint(PB.cobalt)
                                .frame(width: 34, height: 34)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 34, height: 34)
                        }
                    }
                    .foregroundStyle(canSave ? PB.cobalt : PB.pencil)
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                    .accessibilityLabel("Save song")
                    .accessibilityHint("Saves the imported song to Playback")
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
        .task(id: initialAudioURL) {
            importInitialAudioIfNeeded()
        }
        .confirmationDialog("Discard this song?", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your imported audio and edits will not be saved.")
        }
        .onChange(of: artworkItem) { _, item in
            importArtwork(item)
        }
        #if canImport(UIKit)
        .sheet(item: $pendingArtworkCrop) { pending in
            ArtworkCropSheet(pending: pending) { selection in
                importedArtwork = selection
                artworkError = nil
                artworkItem = nil
            }
        }
        #endif
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && importedAudio != nil && !isImporting && !isSaving
    }

    private var hasUnsavedChanges: Bool {
        importedAudio != nil
            || importedArtwork != nil
            || !normalized(title).isEmpty
            || !normalized(artist).isEmpty
            || !normalized(project).isEmpty
            || normalized(version) != "Demo v1"
            || normalized(duration) != "3:00"
    }

    private var normalizedArtistQuery: String {
        normalized(artist)
    }

    private var knownArtists: [String] {
        let rawNames = store.tracks.map(\.artist) + store.rooms.map(\.artist)
        var seen: Set<String> = []
        return rawNames.compactMap { rawName in
            let name = normalized(rawName)
            guard !name.isEmpty, artistLookupKey(name) != artistLookupKey("Unknown Artist") else { return nil }
            let key = artistLookupKey(name)
            guard seen.insert(key).inserted else { return nil }
            return name
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var artistMatches: [String] {
        let query = normalizedArtistQuery
        guard !query.isEmpty else { return [] }
        let key = artistLookupKey(query)
        return knownArtists.filter { artistLookupKey($0).contains(key) }
    }

    private var hasExactArtistMatch: Bool {
        let query = normalizedArtistQuery
        guard !query.isEmpty else { return true }
        let key = artistLookupKey(query)
        return knownArtists.contains { artistLookupKey($0) == key }
    }

    private var shouldOfferNewArtist: Bool {
        !normalizedArtistQuery.isEmpty && !hasExactArtistMatch
    }

    private var shouldShowArtistSuggestions: Bool {
        focusedField == .artist && (!artistMatches.isEmpty || shouldOfferNewArtist)
    }

    private var artistField: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("Artist", color: PB.pencil, size: 10, tracking: 2)
            TextField("Artist", text: $artist)
                .font(PB.text(16))
                .foregroundStyle(PB.cream)
                .tint(PB.cobalt)
                .padding(15)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
                .focused($focusedField, equals: .artist)

            if shouldShowArtistSuggestions {
                artistSuggestionList
            }
        }
    }

    private var artistSuggestionList: some View {
        let suggestions = Array(artistMatches.prefix(6))

        return VStack(spacing: 0) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    chooseArtist(suggestion)
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(PB.pencil)
                            .frame(width: 20)
                        Text(suggestion)
                            .font(PB.text(15))
                            .foregroundStyle(PB.cream)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if suggestion != suggestions.last || shouldOfferNewArtist {
                    Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1)
                }
            }

            if shouldOfferNewArtist {
                Button {
                    chooseArtist(normalizedArtistQuery)
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(PB.cobalt)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add artist")
                                .font(PB.text(15))
                                .foregroundStyle(PB.cream)
                            MonoLabel(normalizedArtistQuery, color: PB.pencil, size: 9, tracking: 0.8)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.1), lineWidth: 1))
    }

    private func requestDismiss() {
        guard !isSaving else { return }
        if hasUnsavedChanges {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func chooseArtist(_ value: String) {
        artist = value
        focusedField = nil
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func artistLookupKey(_ value: String) -> String {
        normalized(value).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func saveSong() {
        guard canSave else { return }
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
                store.touch(PinRef(kind: .song, targetID: track.id).id)
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
            importAudioFile(url)
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func importInitialAudioIfNeeded() {
        guard !didImportInitialAudio, let initialAudioURL else { return }
        didImportInitialAudio = true
        importAudioFile(initialAudioURL)
    }

    private func importAudioFile(_ url: URL) {
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
                        title = Self.importTitleCandidate(selection.title ?? selection.displayName)
                    }
                    if artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let importedArtist = selection.artist {
                        artist = importedArtist
                    }
                    if importedArtwork == nil, let artwork = selection.artwork {
                        importedArtwork = artwork
                    }
                    if deleteInitialAudioAfterImport {
                        try? FileManager.default.removeItem(at: url)
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
            displayName: importTitleCandidate(sourceURL.deletingPathExtension().lastPathComponent),
            title: metadataTitle,
            artist: metadataArtist,
            durationMs: max(15_000, durationMs),
            artwork: embeddedArtwork
        )
    }

    nonisolated private static func importTitleCandidate(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? trimmed : collapsed
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
                #if canImport(UIKit)
                guard let image = UIImage(data: data) else { throw ArtworkImportError.invalidImage }
                await MainActor.run {
                    pendingArtworkCrop = PendingArtworkCrop(
                        image: image,
                        sourceName: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "artwork" : title
                    )
                }
                #else
                let selection = try ImportedMediaWriter.importArtworkData(data, sourceName: title.isEmpty ? "artwork" : title)
                await MainActor.run {
                    importedArtwork = selection
                }
                #endif
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
    #if canImport(UIKit)
    @State private var pendingArtworkCrop: PendingArtworkCrop?
    #endif
    @State private var artworkChanged = false
    @State private var didLoad = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showDiscardConfirmation = false
    @State private var originalTitle = ""
    @State private var originalArtist = ""
    @State private var originalProject = ""
    @State private var originalVersion = ""

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

                        if let saveError {
                            MonoLabel(saveError, color: PB.redline, size: 9, tracking: 0.8)
                        }
                    }
                }
                .padding(22)
            }
            .background(PB.black)
            .navigationTitle("Edit song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { cancel() }
                        .font(PB.mono(13))
                        .foregroundStyle(PB.pencil)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "Saving" : "Done") { saveAndDismiss() }
                        .font(PB.mono(13))
                        .foregroundStyle(canSave ? PB.cobalt : PB.pencil)
                        .disabled(!canSave)
                }
            }
            .toolbarBackground(PB.black, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationBackground(PB.black)
        .foregroundStyle(PB.cream)
        .interactiveDismissDisabled(hasUnsavedChanges || isSaving)
        .confirmationDialog("Discard changes?", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your song edits have not been saved.")
        }
        .onAppear(perform: loadTrack)
        .onChange(of: artworkItem) { _, item in
            importArtwork(item)
        }
        #if canImport(UIKit)
        .sheet(item: $pendingArtworkCrop) { pending in
            ArtworkCropSheet(pending: pending) { selection in
                importedArtwork = selection
                artworkChanged = true
                artworkError = nil
                saveError = nil
                artworkItem = nil
            }
        }
        #endif
    }

    private var canSave: Bool {
        !normalized(title).isEmpty && !isSaving
    }

    private var hasUnsavedChanges: Bool {
        normalized(title) != originalTitle
            || normalized(artist) != originalArtist
            || normalized(project) != originalProject
            || normalized(version) != originalVersion
            || artworkChanged
    }

    private var hasVisibleArtwork: Bool {
        importedArtwork != nil
            || (!artworkChanged && (track?.remoteArtworkURL != nil || track?.coverArt != nil))
    }

    private var artworkTitle: String {
        if let importedArtwork { return importedArtwork.displayName }
        if hasVisibleArtwork { return "Current artwork" }
        return "Choose artwork"
    }

    private var artworkSubtitle: String {
        hasVisibleArtwork ? "Tap to change" : "Optional · image from Photos"
    }

    private var artworkPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel("Artwork", color: PB.pencil, size: 10, tracking: 2)
            PhotosPicker(selection: $artworkItem, matching: .images) {
                HStack(spacing: 13) {
                    artworkPreview(path: importedArtwork?.relativePath)
                        .frame(width: 68, height: 68)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(artworkTitle)
                            .font(PB.text(16)).foregroundStyle(PB.cream)
                            .lineLimit(1)
                        MonoLabel(artworkSubtitle,
                                  color: artworkError == nil ? PB.pencil : PB.redline,
                                  size: 9,
                                  tracking: 1)
                    }
                    Spacer()
                    Image(systemName: hasVisibleArtwork ? "checkmark.circle.fill" : "photo")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(hasVisibleArtwork ? PB.green : PB.pencil)
                }
                .padding(15)
                .frame(minHeight: 92)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)

            if hasVisibleArtwork {
                Button {
                    importedArtwork = nil
                    artworkItem = nil
                    artworkChanged = true
                    saveError = nil
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
        let loadedTitle = store.displayTitle(track.id, track.title)
        title = loadedTitle
        artist = track.artist
        project = track.label
        version = track.versionLabel
        originalTitle = normalized(loadedTitle)
        originalArtist = normalized(track.artist)
        originalProject = normalized(track.label)
        originalVersion = normalized(track.versionLabel)
        if let path = track.importedArtworkPath {
            importedArtwork = ImportedArtworkSelection(
                relativePath: path,
                fileName: "Artwork",
                displayName: "Current artwork",
                paletteHexes: nil
            )
        }
    }

    private func saveAndDismiss() {
        guard canSave else { return }
        guard hasUnsavedChanges else {
            dismiss()
            return
        }
        isSaving = true
        saveError = nil
        Task {
            do {
                try await store.updateTrack(
                    trackID,
                    title: title,
                    artist: artist,
                    project: project,
                    versionLabel: version,
                    importedArtworkPath: importedArtwork?.relativePath,
                    artworkPalette: importedArtwork?.paletteHexes,
                    artworkChanged: artworkChanged
                )
                await MainActor.run {
                    isSaving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }

    private func cancel() {
        if hasUnsavedChanges {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func importArtwork(_ item: PhotosPickerItem?) {
        guard let item else { return }
        artworkError = nil
        saveError = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ArtworkImportError.invalidImage
                }
                #if canImport(UIKit)
                guard let image = UIImage(data: data) else { throw ArtworkImportError.invalidImage }
                await MainActor.run {
                    pendingArtworkCrop = PendingArtworkCrop(
                        image: image,
                        sourceName: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "artwork" : title
                    )
                }
                #else
                let selection = try ImportedMediaWriter.importArtworkData(
                    data,
                    sourceName: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "artwork" : title
                )
                await MainActor.run {
                    importedArtwork = selection
                    artworkChanged = true
                }
                #endif
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
            } else if !artworkChanged,
                      let remote = track?.remoteArtworkURL,
                      let url = URL(string: remote) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if let track {
                        MeshCover(colors: track.mesh, animate: false, fillsSafeArea: false)
                    }
                }
            } else if !artworkChanged,
                      let track,
                      let image = TrackArtworkLoader.uiImage(for: track) {
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

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
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

struct AddSongsToCollectionSheet: View {
    var title: String
    var subtitle: String
    var store: WorkspaceStore
    var unavailableTrackIDs: Set<String>
    var onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    private var availableTracks: [Track] {
        store.tracks.filter { !unavailableTrackIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !subtitle.isEmpty {
                        MonoLabel(subtitle, color: PB.pencil, size: 10, tracking: 1.4)
                    }

                    if availableTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("No songs to add").font(PB.display(20)).foregroundStyle(PB.cream)
                            MonoLabel("Everything in the library is already here", color: PB.pencil, size: 9, tracking: 1.1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(availableTracks) { track in
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
                }
                .padding(22)
            }
            .background(PB.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(PB.cobalt)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let ids = Array(selected)
                        guard !ids.isEmpty else { return }
                        onAdd(ids)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 34, height: 34)
                    }
                    .foregroundStyle(selected.isEmpty ? PB.pencil : PB.cobalt)
                    .buttonStyle(.plain)
                    .disabled(selected.isEmpty)
                    .accessibilityLabel("Add selected songs")
                }
            }
            .toolbarBackground(PB.black, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationBackground(PB.black)
        .foregroundStyle(PB.cream)
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
    @State private var bulkMode: BulkSelectionMode?
    @State private var selectedTrackIDs: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var inboxNotice: PlaylistEditNotice?
    @State private var springboardPlaylist: Playlist?
    @State private var selectionDragTargets: [SelectionDragTarget] = []
    @State private var resolvingRequestIDs: Set<String> = []
    @State private var accessRequestError: String?

    private var items: [InboxItem] { store.inbox }
    private var selectedTracks: [Track] {
        store.tracks.filter { selectedTrackIDs.contains($0.id) }
    }

    /// True when the inbox has entries but none of them resolve to a track —
    /// the state a fresh launch lands in until the cloud library has synced.
    private var hasUnresolvedItems: Bool {
        !items.isEmpty && !items.contains { store.track($0.trackID) != nil }
    }

    /// The one-shot launch sync can fail (the hosted API cold-starts slower
    /// than the request timeout), leaving persisted inbox items pointing at a
    /// track catalog that never loaded. Keep retrying the library fetch while
    /// the rows can't resolve so the inbox recovers without a relaunch.
    @MainActor
    private func resolveInboxTracksIfNeeded() async {
        guard Config.useRemoteAPI else { return }
        while !Task.isCancelled && hasUnresolvedItems {
            if store.syncState != .syncing {
                await store.refreshFromService()
            }
            if !hasUnresolvedItems { break }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                scrollToTopMarker()
                VStack(alignment: .leading, spacing: 22) {
                    AppScreenHeader(title: "Inbox", isPlaying: player.isPlaying) {
                        // Count never wraps; the bulkier actions live in one
                        // ⋯ menu so the trailing cluster always fits the row.
                        HStack(alignment: .center, spacing: 10) {
                            MonoLabel("\(store.inboxNewCount) new", color: PB.redline, size: 11, tracking: 1.4)
                                .lineLimit(1)
                                .fixedSize()
                                .layoutPriority(1)
                            if !items.isEmpty {
                                Menu {
                                    Button {
                                        if bulkMode == nil {
                                            bulkMode = .selecting
                                        } else {
                                            clearSelection()
                                        }
                                    } label: {
                                        Label(bulkMode == nil ? "Select songs" : "Done selecting",
                                              systemImage: bulkMode == nil ? "checkmark.circle" : "xmark.circle")
                                    }
                                    if store.inboxNewCount > 0 {
                                        Button { store.markAllInboxHeard() } label: {
                                            Label("Mark all heard", systemImage: "tray.full")
                                        }
                                    }
                                } label: {
                                    HeaderCircleIcon(systemName: "ellipsis")
                                }
                                .accessibilityLabel("Inbox actions")
                            }
                        }
                    }

                    if let inboxNotice {
                        editNotice(inboxNotice)
                    }

                    if !store.accessRequests.isEmpty || accessRequestError != nil {
                        accessRequestsSection
                    }

                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            if let t = store.track(item.trackID) {
                                inboxItem(item, t)
                            }
                        }
                    }

                    // Inbox items persist across launches, but the track
                    // catalog they reference is memory-only and arrives via
                    // cloud sync. If the first sync fails (cold API start,
                    // flaky network) every row resolves to nil and the list
                    // renders empty under a non-zero "N new" header. Surface
                    // the state instead of a silent blank, and let the retry
                    // task below bring the rows back.
                    if hasUnresolvedItems {
                        MonoLabel(store.syncState == .syncing
                                    ? "Syncing library…"
                                    : "Waiting for cloud library — retrying…",
                                  color: PB.pencil, size: 10, tracking: 1.4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 18)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 150)
            }
            .scrollIndicators(.hidden)
            .background {
                PB.black.ignoresSafeArea()
                // Observes position ticks in its own body — keeps the inbox
                // from re-laying-out 20×/sec while audio plays.
                AmbientPlayerBackdrop(player: player)
                    .allowsHitTesting(false).ignoresSafeArea()
            }
            .overlay(alignment: .top) {
                TopTapScrollHotspot { scrollToTop(scrollProxy) }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { await resolveInboxTracksIfNeeded() }
            .onPreferenceChange(SelectionDragTargetKey.self) { targets in
                selectionDragTargets = targets
            }
            .twoFingerSelection(
                enabled: !items.isEmpty,
                targets: selectionDragTargets,
                onSelect: selectDuringDrag
            )
            .overlay(alignment: .bottom) {
                if let bulkMode, !selectedTrackIDs.isEmpty {
                    BulkSongActionBar(
                        count: selectedTrackIDs.count,
                        mode: bulkMode,
                        playlists: store.playlists,
                        rooms: store.rooms,
                        projectLabel: "Project",
                        canDelete: true,
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
                "Delete selected songs?",
                isPresented: $confirmBulkDelete,
                titleVisibility: .visible
            ) {
                Button("Delete \(selectedTrackIDs.count) \(selectedTrackIDs.count == 1 ? "song" : "songs")", role: .destructive) {
                    deleteSelectedSongs()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the selected songs from your Playback library. Imported audio and artwork files on this device will be deleted.")
            }
            .sheet(item: $springboardPlaylist) { playlist in
                PlaylistDetailView(playlist: playlist, player: player, store: store, openSong: openSong)
            }
        }
    }

    private func inboxItem(_ item: InboxItem, _ t: Track) -> some View {
        InteractiveSongItem(
            track: t,
            store: store,
            bulkMode: $bulkMode,
            selectedTrackIDs: $selectedTrackIDs,
            selectedTracks: selectedTracks,
            extraActions: [
                SongRowMenuAction(title: item.isNew ? "Mark heard" : "Mark new",
                                  systemImage: item.isNew ? "checkmark.circle" : "circle") {
                    store.toggleInboxNew(item.id)
                }
            ],
            onOpen: {
                store.markInboxHeard(item.id)
                openSong(t.id)
            },
            onSpringboardDrop: handleSpringboardDrop
        ) {
            inboxRow(item, t)
        } idleAccessory: {
            // NEW is the only idle state pill — mark-heard happens on open,
            // via the row's context menu, or "Mark all heard" in the header.
            EmptyView()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
    }

    private func handleSpringboardDrop(_ ids: [String]) {
        guard ids.count >= 2 else { return }
        let tracks = ids.compactMap { store.track($0) }
        let title = tracks.count == 2
            ? "\(tracks[0].title) + \(tracks[1].title)"
            : "\(tracks[0].title) + \(tracks.count - 1) more"
        let playlist = store.createKeptPlaylist(title: title, trackIDs: ids)
        clearSelection()
        withAnimation(.easeInOut(duration: 0.18)) { springboardPlaylist = playlist }
    }

    private func selectDuringDrag(_ id: String) {
        if bulkMode == nil { bulkMode = .selecting }
        selectedTrackIDs.insert(id)
    }

    private func clearSelection() {
        selectedTrackIDs.removeAll()
        bulkMode = nil
    }

    private func createPlaylistFromSelection() {
        guard !selectedTracks.isEmpty else { return }
        _ = store.createKeptPlaylist(title: "Inbox Selection", trackIDs: selectedTracks.map(\.id))
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
        showNotice(Config.useRemoteAPI ? "Titles copied" : "Share links copied")
        clearSelection()
    }

    private func deleteSelectedSongs() {
        let ids = selectedTrackIDs
        let deleted = ids.reduce(0) { count, id in
            count + (store.deleteTrack(id) ? 1 : 0)
        }
        if !store.tracks.isEmpty { player.replaceQueue(store.tracks) }
        showNotice(deleted == 0 ? "Nothing deleted" : "Deleted \(deleted)")
        clearSelection()
    }

    private func showNotice(_ message: String) {
        let notice = PlaylistEditNotice(message: message)
        withAnimation(.easeInOut(duration: 0.18)) { inboxNotice = notice }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if inboxNotice?.id == notice.id {
                withAnimation(.easeInOut(duration: 0.18)) { inboxNotice = nil }
            }
        }
    }

    private func editNotice(_ notice: PlaylistEditNotice) -> some View {
        MonoLabel(notice.message, color: PB.green, size: 10, tracking: 1.4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.green.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(PB.green.opacity(0.32), lineWidth: 1))
    }

    // MARK: access requests

    private var accessRequestsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoLabel("Access requests", color: PB.pencil, size: 10, tracking: 2)
                .padding(.bottom, 4)
            if let accessRequestError {
                MonoLabel(accessRequestError, color: PB.redline, size: 9, tracking: 1.2)
                    .padding(.top, 6)
            }
            ForEach(store.accessRequests) { request in
                accessRequestRow(request)
                    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.accessRequests)
    }

    private func accessRequestRow(_ request: AccessRequest) -> some View {
        let resolving = resolvingRequestIDs.contains(request.id)
        return HStack(spacing: 13) {
            InitialsCover(id: request.id, name: request.name, size: 46, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.name).font(PB.display(17)).foregroundStyle(PB.cream)
                    .lineLimit(1).truncationMode(.tail)
                MonoLabel(accessRequestSubtitle(request), color: PB.pencil, size: 9, tracking: 1)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 10)
            Button { approveAccessRequest(request) } label: {
                MonoLabel("Approve", color: PB.cream, size: 9, tracking: 1.4)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(PB.cobalt))
            }
            .buttonStyle(.plain)
            .disabled(resolving)
            Button { dismissAccessRequest(request) } label: {
                MonoLabel("Dismiss", color: PB.pencil, size: 9, tracking: 1.4)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .disabled(resolving)
        }
        .opacity(resolving ? 0.5 : 1)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func accessRequestSubtitle(_ request: AccessRequest) -> String {
        var parts = ["Requested access"]
        if let source = request.sourceSongTitle, !source.isEmpty {
            parts.append("Via \(source)")
        }
        parts.append(relativeAge(request.createdAt))
        return parts.joined(separator: " · ")
    }

    private func relativeAge(_ date: Date?) -> String {
        guard let date else { return "Just now" }
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    private func approveAccessRequest(_ request: AccessRequest) {
        guard resolvingRequestIDs.insert(request.id).inserted else { return }
        accessRequestError = nil
        Task { @MainActor in
            defer { resolvingRequestIDs.remove(request.id) }
            do {
                let invite = try await store.approveAccessRequest(request.id)
                UIPasteboard.general.string = invite.url
                showNotice("Invite link copied — send it to \(request.name)")
            } catch {
                // Request stays pending server-side (e.g. invites need
                // Supabase) — quiet inline error; the row stays for retry.
                withAnimation(.easeInOut(duration: 0.18)) {
                    accessRequestError = "Couldn't create invite — try again"
                }
            }
        }
    }

    private func dismissAccessRequest(_ request: AccessRequest) {
        guard resolvingRequestIDs.insert(request.id).inserted else { return }
        accessRequestError = nil
        Task { @MainActor in
            defer { resolvingRequestIDs.remove(request.id) }
            do {
                try await store.dismissAccessRequest(request.id)
            } catch {
                withAnimation(.easeInOut(duration: 0.18)) {
                    accessRequestError = "Couldn't dismiss request — try again"
                }
            }
        }
    }

    private func inboxRow(_ item: InboxItem, _ t: Track) -> some View {
        HStack(spacing: 13) {
            trackSwatch(t, 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.displayTitle(t.id, t.title)).font(PB.display(17)).foregroundStyle(PB.cream)
                    .lineLimit(1).truncationMode(.tail)
                MonoLabel("Shared by \(item.sharedBy) · \(item.context)", color: PB.pencil, size: 9, tracking: 1)
                    .lineLimit(1).truncationMode(.tail)
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

struct PlaylistEditNotice: Identifiable {
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
    @State private var springboardPlaylist: Playlist?
    @State private var bulkMode: BulkSelectionMode?
    @State private var selectedTrackIDs: Set<String> = []
    @State private var confirmBulkDelete = false
    @State private var showAddSongs = false
    @State private var selectionDragTargets: [SelectionDragTarget] = []

    private var live: Playlist { store.playlist(playlist.id) ?? playlist }
    private var tracks: [Track] { live.trackIDs.compactMap { store.track($0) } }
    private var cover: Track { tracks.first ?? store.tracks[0] }
    private var totalMs: Int { tracks.reduce(0) { $0 + $1.durationMs } }
    private var selectedTracks: [Track] { tracks.filter { selectedTrackIDs.contains($0.id) } }

    var body: some View {
        ZStack {
            PB.black
            MeshCover(colors: cover.mesh)
                .overlay(scrim)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        BackButton()
                        Spacer()
                        playlistTopControls
                    }
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
        .restoresSwipeBack()
        .onPreferenceChange(SelectionDragTargetKey.self) { targets in
            selectionDragTargets = targets
        }
        .twoFingerSelection(
            enabled: !tracks.isEmpty,
            targets: selectionDragTargets,
            onSelect: selectDuringDrag
        )
        .overlay(alignment: .bottom) {
            if let bulkMode, !selectedTrackIDs.isEmpty {
                BulkSongActionBar(
                    count: selectedTrackIDs.count,
                    mode: bulkMode,
                    playlists: store.playlists,
                    rooms: store.rooms,
                    projectLabel: "Project",
                    canDelete: true,
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
            "Delete selected songs?",
            isPresented: $confirmBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedTrackIDs.count) \(selectedTrackIDs.count == 1 ? "song" : "songs")", role: .destructive) {
                deleteSelectedSongs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected songs from your Playback library and from this playlist. Imported audio and artwork files on this device will be deleted.")
        }
        .sheet(isPresented: $showAddSongs) {
            AddSongsToCollectionSheet(
                title: "Add songs",
                subtitle: live.title,
                store: store,
                unavailableTrackIDs: Set(live.trackIDs)
            ) { ids in
                ids.forEach { store.addTrack($0, toPlaylist: live.id) }
                showNotice("Added \(ids.count)")
            }
        }
        .sheet(item: $springboardPlaylist) { pl in
            PlaylistDetailView(playlist: pl, player: player, store: store,
                               openSong: openSong, openQueue: openQueue)
        }
        .onAppear { if !store.isDraft(live.id) { store.touch(PinRef(kind: .playlist, targetID: live.id).id) } }
        .onDisappear {
            // leaving a draft without keeping it = no changes
            if store.isDraft(live.id) { store.discardPlaylist(live.id) }
        }
    }

    private func handleSpringboardDrop(_ ids: [String]) {
        guard ids.count >= 2 else { return }
        let tracks = ids.compactMap { store.track($0) }
        let title = tracks.count == 2
            ? "\(tracks[0].title) + \(tracks[1].title)"
            : "\(tracks[0].title) + \(tracks.count - 1) more"
        let pl = store.createKeptPlaylist(title: title, trackIDs: ids)
        clearSelection()
        withAnimation(.easeInOut(duration: 0.18)) { springboardPlaylist = pl }
    }

    private var playlistTopControls: some View {
        HStack(spacing: 10) {
            if !tracks.isEmpty {
                Button {
                    if bulkMode == nil {
                        bulkMode = .selecting
                    } else {
                        clearSelection()
                    }
                } label: {
                    HeaderCircleIcon(systemName: bulkMode == nil ? "checkmark.circle" : "xmark.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bulkMode == nil ? "Select songs" : "Done selecting")
            }

            Button {
                showAddSongs = true
            } label: {
                HeaderCircleIcon(systemName: "plus")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add songs")
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
                let inHolding = bulkMode == .holding && !selectedTrackIDs.isEmpty
                let isSelected = selectedTrackIDs.contains(t.id)

                HStack(spacing: 8) {
                    if bulkMode != nil {
                        Button { toggleSelection(t.id) } label: {
                            SelectionMark(isSelected: isSelected)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSelected
                            ? "Deselect \(store.displayTitle(t.id, t.title))"
                            : "Select \(store.displayTitle(t.id, t.title))")
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

                    // Pile badge when holding; reorder handle otherwise
                    if inHolding && isSelected {
                        PileBadge(count: selectedTrackIDs.count)
                            .padding(.trailing, 4)
                    } else if bulkMode == nil {
                        HStack(spacing: 0) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(PB.cream.opacity(0.7))
                                .frame(width: 40, height: 44)
                                .contentShape(Rectangle())
                                .draggable(playlistDragPayload(live.id, t.id)) {
                                    HStack(spacing: 10) {
                                        MonoLabel(String(format: "%02d", i + 1), color: PB.cobalt, size: 10, tracking: 1)
                                        Text(store.displayTitle(t.id, t.title)).font(PB.display(16)).foregroundStyle(PB.cream)
                                    }
                                    .padding(10).background(PB.panel)
                                }
                                .accessibilityLabel("Drag to reorder \(store.displayTitle(t.id, t.title))")

                            SongActionsButton(
                                store: store,
                                track: t,
                                extraActions: [
                                    SongRowMenuAction(title: "Remove from playlist", systemImage: "minus.circle", role: .destructive) {
                                        removeFromPlaylist(t.id)
                                    }
                                ]
                            )
                        }
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
                // Drop handler: reorder (playlist payload) takes priority; springboard
                // pile payload creates a new playlist and opens it as a sheet.
                .dropDestination(for: String.self) { ids, _ in
                    // Reorder within this playlist
                    if bulkMode == nil,
                       let dragged = playlistTrackID(from: ids.first, playlistID: live.id),
                       dragged != t.id {
                        reorder(dragged, before: t.id)
                        return true
                    }
                    // Springboard pile drop → new playlist
                    if let pileIDs = idsFromPilePayload(ids.first), !pileIDs.contains(t.id) {
                        handleSpringboardDrop(pileIDs + [t.id])
                        return true
                    }
                    return false
                } isTargeted: { isTargeted in
                    dropTargetID = isTargeted ? t.id : (dropTargetID == t.id ? nil : dropTargetID)
                }
                .springboardDraggable(trackID: t.id, track: t, store: store,
                                      enabled: false)
                .springboardPileDraggable(pileIDs: Array(selectedTrackIDs),
                                          pileTracks: selectedTracks,
                                          store: store,
                                          enabled: inHolding && isSelected)
                .selectionDragTarget(id: t.id)
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

    private func selectDuringDrag(_ id: String) {
        if bulkMode == nil { bulkMode = .selecting }
        selectedTrackIDs.insert(id)
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

    private func deleteSelectedSongs() {
        let ids = selectedTrackIDs
        let deleted = ids.reduce(0) { count, id in
            count + (store.deleteTrack(id) ? 1 : 0)
        }
        if !store.tracks.isEmpty { player.replaceQueue(store.tracks) }
        showNotice(deleted == 0 ? "Nothing deleted" : "Deleted \(deleted)")
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
    @State private var showAddSongs = false
    @State private var springboardPlaylist: Playlist?
    @State private var selectionDragTargets: [SelectionDragTarget] = []

    private var live: Room { store.rooms.first { $0.id == room.id } ?? room }
    private var tracks: [Track] { live.trackIDs.compactMap { store.track($0) } }
    private var selectedTracks: [Track] { tracks.filter { selectedTrackIDs.contains($0.id) } }

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
                    projectTopControls
                }
                .padding(.top, 40)

                if let projectNotice {
                    editNotice(projectNotice)
                }

                VStack(spacing: 0) {
                    ForEach(tracks) { t in
                        projectSongItem(t)
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
        .restoresSwipeBack()
        .onPreferenceChange(SelectionDragTargetKey.self) { targets in
            selectionDragTargets = targets
        }
        .twoFingerSelection(
            enabled: !tracks.isEmpty,
            targets: selectionDragTargets,
            onSelect: selectDuringDrag
        )
        .overlay(alignment: .topLeading) { BackButton().padding(.leading, 16).padding(.top, 6) }
        .overlay(alignment: .bottom) {
            if let bulkMode, !selectedTrackIDs.isEmpty {
                BulkSongActionBar(
                    count: selectedTrackIDs.count,
                    mode: bulkMode,
                    playlists: store.playlists,
                    rooms: store.rooms.filter { $0.id != live.id },
                    projectLabel: "Move",
                    canDelete: true,
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
            "Delete selected songs?",
            isPresented: $confirmBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedTrackIDs.count) \(selectedTrackIDs.count == 1 ? "song" : "songs")", role: .destructive) {
                deleteSelectedSongs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected songs from your Playback library and from this project. Imported audio and artwork files on this device will be deleted.")
        }
        .sheet(isPresented: $showAddSongs) {
            AddSongsToCollectionSheet(
                title: "Add songs",
                subtitle: live.title,
                store: store,
                unavailableTrackIDs: Set(live.trackIDs)
            ) { ids in
                ids.forEach { store.addTrack($0, toProject: live.id) }
                showNotice("Added \(ids.count)")
            }
        }
        .sheet(item: $springboardPlaylist) { pl in
            PlaylistDetailView(playlist: pl, player: player, store: store,
                               openSong: openSong, openQueue: openQueue)
        }
        .onAppear { store.touch(PinRef(kind: .room, targetID: live.id).id) }
    }

    private func projectSongItem(_ track: Track) -> some View {
        InteractiveSongItem(
            track: track,
            store: store,
            bulkMode: $bulkMode,
            selectedTrackIDs: $selectedTrackIDs,
            selectedTracks: selectedTracks,
            extraActions: [
                SongRowMenuAction(title: "Remove from project", systemImage: "minus.circle", role: .destructive) {
                    removeSelectionFromProject(ids: Set([track.id]))
                }
            ],
            onOpen: { openQueue(track.id, tracks) },
            onSpringboardDrop: handleSpringboardDrop
        ) {
            SongRow(track: track, store: store,
                    trailing: store.openCount(track.id) > 0 ? "\(store.openCount(track.id)) open" : nil,
                    trailingColor: PB.redline)
        } idleAccessory: {
            EmptyView()
        }
    }

    private func handleSpringboardDrop(_ ids: [String]) {
        guard ids.count >= 2 else { return }
        let tracks = ids.compactMap { store.track($0) }
        let title = tracks.count == 2
            ? "\(tracks[0].title) + \(tracks[1].title)"
            : "\(tracks[0].title) + \(tracks.count - 1) more"
        let playlist = store.createKeptPlaylist(title: title, trackIDs: ids)
        clearSelection()
        withAnimation(.easeInOut(duration: 0.18)) { springboardPlaylist = playlist }
    }

    private var projectTopControls: some View {
        HStack(spacing: 10) {
            if !tracks.isEmpty {
                Button {
                    if bulkMode == nil {
                        bulkMode = .selecting
                    } else {
                        clearSelection()
                    }
                } label: {
                    HeaderCircleIcon(systemName: bulkMode == nil ? "checkmark.circle" : "xmark.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bulkMode == nil ? "Select songs" : "Done selecting")
            }

            Button {
                showAddSongs = true
            } label: {
                HeaderCircleIcon(systemName: "plus")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add songs")
        }
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

    private func selectDuringDrag(_ id: String) {
        if bulkMode == nil { bulkMode = .selecting }
        selectedTrackIDs.insert(id)
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

    private func deleteSelectedSongs() {
        let ids = selectedTrackIDs
        let deleted = ids.reduce(0) { count, id in
            count + (store.deleteTrack(id) ? 1 : 0)
        }
        if !store.tracks.isEmpty { player.replaceQueue(store.tracks) }
        showNotice(deleted == 0 ? "Nothing deleted" : "Deleted \(deleted)")
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
