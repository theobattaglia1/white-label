import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Why a share link can't be produced right now. Honest state, mono-caps,
/// inline: NOT SYNCED is a quiet dim-cream fact (the song never reached the
/// cloud — a POST is guaranteed to fail); redline is reserved for true
/// failures (storage busy, unknown errors).
enum ShareLinkIssue: Equatable {
    case notSynced      // local-only track — gated up front, or API 422
    case storageBusy    // API 503
    case failed         // everything else

    var label: String {
        switch self {
        case .notSynced: return "Not synced — upload first"
        case .storageBusy: return "Storage busy — tap to retry"
        case .failed: return "Link failed — tap to retry"
        }
    }
    var tint: Color {
        self == .notSynced ? PB.cream.opacity(0.55) : PB.redline
    }

    /// Maps the API's statusCode (commit 74f6454: 422 = song hasn't synced,
    /// 503 = storage problems) onto the right inline state.
    static func from(_ error: Error) -> ShareLinkIssue {
        switch error.serviceHTTPStatus {
        case 422: return .notSynced
        case 503: return .storageBusy
        default: return .failed
        }
    }
}

/// The floating menu's contents — share, link, playlist, export, rename.
struct MenuSheet: View {
    var player: Player
    var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var linkIssue: ShareLinkIssue?
    @State private var linkFailureRevert: Task<Void, Never>?
    @State private var exported = false
    @State private var showEditSong = false
    @State private var shareError: String?
    @State private var exportItems: [Any] = []
    @State private var showExportSheet = false
    @State private var isUploading = false
    @State private var uploadFailed = false
    @State private var uploaded = false

    private var track: Track { player.track }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 5) {
                        MonoLabel("Track", color: PB.pencil, size: 10, tracking: 2)
                        Text(store.displayTitle(track.id, track.title))
                            .font(PB.display(24)).foregroundStyle(PB.cream)
                        MonoLabel("\(track.artist) · \(track.catalog)", color: PB.pencil, size: 10, tracking: 1.2)
                    }

                    group {
                        Button { store.togglePin(PinRef(kind: .song, targetID: track.id).id) } label: {
                            let pinned = store.isPinned(PinRef(kind: .song, targetID: track.id).id)
                            MenuRow(icon: pinned ? "pin.slash" : "pin",
                                    title: pinned ? "Unpin from Home" : "Pin to Home", detail: nil,
                                    tint: pinned ? PB.cobalt : PB.cream)
                        }
                        NavigationLink { ShareView(track: track, store: store) } label: {
                            MenuRow(icon: "person.2", title: "Share", detail: "Set who can access")
                        }
                        NavigationLink { CreateFirstListenView(track: track) } label: {
                            MenuRow(icon: "headphones", title: "Create First Listen", detail: "Protected decision link")
                        }
                        NavigationLink { CreateListeningRoomView(track: track) } label: {
                            MenuRow(icon: "person.3.sequence", title: "Create Listening Room", detail: "Private synced play")
                        }
                        Button { copyLink() } label: {
                            MenuRow(icon: "link",
                                    title: linkIssue?.label ?? (copied ? "Link copied" : "Copy link"),
                                    detail: nil,
                                    tint: linkIssue?.tint ?? (copied ? PB.green : PB.cream),
                                    monoTitle: linkIssue != nil)
                        }
                        if uploaded {
                            MenuRow(icon: "checkmark.icloud",
                                    title: "Uploaded — synced",
                                    detail: nil,
                                    tint: PB.green,
                                    monoTitle: true)
                        } else if store.isLocalOnlyTrack(track.id) {
                            if store.canRetryUpload(track.id) {
                                Button { retryUpload() } label: {
                                    MenuRow(icon: "icloud.and.arrow.up",
                                            title: uploadRowTitle,
                                            detail: nil,
                                            tint: uploadRowTint,
                                            monoTitle: true)
                                }
                                .disabled(isUploading)
                            } else {
                                // The source file is gone — re-upload is
                                // impossible; be honest about what's possible.
                                MenuRow(icon: "icloud.slash",
                                        title: "Saved on this device only — re-import to share",
                                        detail: nil,
                                        tint: PB.cream.opacity(0.55),
                                        monoTitle: true)
                            }
                        }
                        NavigationLink { AddToPlaylistView(track: track, store: store) } label: {
                            MenuRow(icon: "plus.square.on.square", title: "Add to playlist", detail: "Copy into another list")
                        }
                        NavigationLink { AddToProjectView(track: track, store: store) } label: {
                            MenuRow(icon: "folder.badge.plus", title: "Add to project", detail: "Place in a room")
                        }
                        if store.isEditableTrack(track.id) {
                            Button { showEditSong = true } label: {
                                MenuRow(icon: "slider.horizontal.3", title: "Edit song info", detail: "Metadata · artwork")
                            }
                        }
                    }

                    group {
                        Button { exportFile() } label: {
                            MenuRow(icon: "arrow.down.circle", title: exported ? "Export started" : "Export",
                                    detail: "WAV · if allowed", tint: exported ? PB.green : PB.cream)
                        }
                        NavigationLink { RenameView(track: track, store: store) } label: {
                            MenuRow(icon: "pencil", title: "Rename", detail: "Owner")
                        }
                    }

                    if let shareError {
                        MonoLabel(shareError, color: PB.redline, size: 9, tracking: 1)
                    }
                }
                .padding(22)
            }
            .background(PB.black)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(PB.mono(13)).foregroundStyle(PB.cobalt)
                }
            }
            .toolbarBackground(PB.black, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(PB.black)
        .foregroundStyle(PB.cream)
        .sheet(isPresented: $showEditSong) {
            EditSongSheet(trackID: track.id, store: store)
        }
        .sheet(isPresented: $showExportSheet) {
            ActivityShareSheet(items: exportItems)
                .presentationDetents([.medium, .large])
        }
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PB.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
    }

    private var uploadRowTitle: String {
        if isUploading { return "Uploading" }
        if uploadFailed { return "Upload failed — tap to retry" }
        return "Retry upload"
    }

    private var uploadRowTint: Color {
        if isUploading { return PB.cream.opacity(0.55) }
        if uploadFailed { return PB.redline }
        return PB.cream
    }

    private func retryUpload() {
        guard !isUploading else { return }
        isUploading = true
        withAnimation { uploadFailed = false }
        Task {
            let ok = await store.retryUpload(track.id)
            await MainActor.run {
                isUploading = false
                withAnimation {
                    uploaded = ok
                    uploadFailed = !ok
                    if ok { linkIssue = nil }
                }
            }
        }
    }

    private func copyLink() {
        shareError = nil
        linkFailureRevert?.cancel()
        withAnimation { linkIssue = nil }
        guard Config.useRemoteAPI else {
            showLinkIssue(.failed)
            return
        }
        // Honest gate: a local-only track can never resolve on the server —
        // don't POST a link that's guaranteed to fail.
        guard !store.isLocalOnlyTrack(track.id) else {
            showLinkIssue(.notSynced)
            return
        }
        Task {
            do {
                let link = try await store.createShareLink(for: track)
                #if canImport(UIKit)
                UIPasteboard.general.string = link
                #endif
                await MainActor.run {
                    withAnimation { copied = true }
                }
            } catch {
                await MainActor.run {
                    showLinkIssue(.from(error))
                }
            }
        }
    }

    /// Honest state: link creation failed (or is impossible), so nothing was
    /// copied. The same row shows a quiet mono-caps inline state, reverts to
    /// idle after ~4s, and tapping it retries the request.
    private func showLinkIssue(_ issue: ShareLinkIssue) {
        withAnimation {
            copied = false
            linkIssue = issue
        }
        linkFailureRevert = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation { linkIssue = nil }
            }
        }
    }

    private func exportFile() {
        shareError = nil
        if let local = localAudioURL() {
            exportItems = [local]
            showExportSheet = true
            withAnimation { exported = true }
            return
        }

        guard Config.useRemoteAPI else {
            shareError = "Export file unavailable"
            return
        }
        // Local-only and the local file is gone — an export link can't exist.
        guard !store.isLocalOnlyTrack(track.id) else {
            shareError = "Not synced — upload first"
            return
        }
        Task {
            do {
                let link = try await store.createShareLink(for: track, allowDownload: true)
                await MainActor.run {
                    if let url = URL(string: link) {
                        exportItems = [url]
                    } else {
                        exportItems = [link]
                    }
                    showExportSheet = true
                    withAnimation { exported = true }
                }
            } catch {
                await MainActor.run {
                    shareError = "Export unavailable"
                }
            }
        }
    }

    private func localAudioURL() -> URL? {
        if let path = track.importedAudioPath {
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard let audio = track.audio else { return nil }
        let ns = audio as NSString
        let name = ns.deletingPathExtension
        let ext = ns.pathExtension.isEmpty ? nil : ns.pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext)
    }
}

#if canImport(UIKit)
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

private struct MenuRow: View {
    var icon: String
    var title: String
    var detail: String?
    var tint: Color = PB.cream
    var monoTitle = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 22).foregroundStyle(tint)
            if monoTitle {
                MonoLabel(title, color: tint, size: 10, tracking: 1.2)
            } else {
                Text(title).font(PB.text(15)).foregroundStyle(tint)
            }
            Spacer()
            if let detail { MonoLabel(detail, color: PB.pencil, size: 9, tracking: 1) }
        }
        .padding(.horizontal, 15).padding(.vertical, 14)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 50) }
    }
}

// MARK: - Share (Google-Drive-style access)

enum ShareAccess: String, CaseIterable { case restricted = "Restricted", anyone = "Anyone with the link" }
enum ShareRole: String, CaseIterable { case listen = "Can listen", comment = "Can comment", download = "Can download" }

struct ShareView: View {
    var track: Track
    var store: WorkspaceStore
    @State private var access: ShareAccess = .restricted
    @State private var role: ShareRole = .comment
    @State private var copied = false
    @State private var linkIssue: ShareLinkIssue?
    @State private var linkFailureRevert: Task<Void, Never>?
    @State private var isCreating = false
    @State private var link: String?
    @State private var linkID: String?
    @State private var recipientEmail = ""
    @State private var recipientName = ""
    @State private var recipients: [ServiceClient.APIShareRecipient] = []
    @State private var delivery: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Honest state, up front: this song only exists on this
                // device — no link or invite can resolve it until it syncs.
                if store.isLocalOnlyTrack(track.id) {
                    MonoLabel("Not synced — upload first", color: PB.cream.opacity(0.55), size: 9, tracking: 1.2)
                }
                section("General access") {
                    ForEach(ShareAccess.allCases, id: \.self) { a in
                        optionRow(a.rawValue,
                                  sub: a == .restricted ? "Only people you invite" : "Anyone with the link can open",
                                  selected: access == a) { withAnimation { access = a } }
                    }
                }
                if access == .anyone {
                    section("They can") {
                        ForEach(ShareRole.allCases, id: \.self) { r in
                            optionRow(r.rawValue, sub: nil, selected: role == r) { withAnimation { role = r } }
                        }
                    }
                }
                section("People") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Email", text: $recipientEmail)
                            .font(PB.text(15)).foregroundStyle(PB.cream).tint(PB.cobalt)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.black.opacity(0.32)))
                        TextField("Name optional", text: $recipientName)
                            .font(PB.text(15)).foregroundStyle(PB.cream).tint(PB.cobalt)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PB.black.opacity(0.32)))
                        Button { invite() } label: {
                            Text(isCreating ? "WORKING" : "INVITE")
                                .font(PB.mono(10)).tracking(1.4).foregroundStyle(PB.black)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Capsule().fill(canInvite ? PB.cream : PB.pencil))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canInvite)
                    }
                    .padding(15)

                    ForEach(recipients) { recipient in
                        recipientRow(recipient)
                    }
                }
                section("Link") {
                    HStack {
                        Text(link ?? "Create link when copied").font(PB.mono(12)).foregroundStyle(PB.cream).lineLimit(1)
                        Spacer()
                        Button { copy() } label: {
                            Text(isCreating ? "CREATING" : (linkIssue?.label.uppercased() ?? (copied ? "COPIED" : "COPY"))).font(PB.mono(10)).tracking(1)
                                .foregroundStyle(linkIssue?.tint ?? (copied ? PB.green : PB.cobalt))
                        }.buttonStyle(.plain)
                        .disabled(isCreating)
                    }
                    .padding(15)
                }
                if let error {
                    MonoLabel(error, color: PB.redline, size: 9, tracking: 1)
                }
                if let delivery {
                    MonoLabel(delivery, color: PB.pencil, size: 9, tracking: 1)
                }
            }
            .padding(22)
        }
        .background(PB.black)
        .navigationTitle("Share")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PB.black, for: .navigationBar)
        .foregroundStyle(PB.cream)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(title, color: PB.pencil, size: 10, tracking: 2)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
        }
    }

    private func optionRow(_ title: String, sub: String?, selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(PB.text(15)).foregroundStyle(PB.cream)
                    if let sub { MonoLabel(sub, color: PB.pencil, size: 9, tracking: 0.6) }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? PB.cobalt : PB.pencil)
            }
            .padding(15).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var canInvite: Bool {
        recipientEmail.contains("@") && !isCreating
    }

    private var apiRole: String {
        switch role {
        case .listen: return "listen"
        case .comment: return "comment"
        case .download: return "download"
        }
    }

    private func recipientRow(_ recipient: ServiceClient.APIShareRecipient) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(recipient.display_name?.isEmpty == false ? recipient.display_name! : recipient.email)
                    .font(PB.text(15)).foregroundStyle(recipient.revoked_at == nil ? PB.cream : PB.pencil)
                MonoLabel("\(recipient.email) · \(roleLabel(recipient.role))", color: PB.pencil, size: 9, tracking: 0.8)
            }
            Spacer()
            Menu {
                Button("Can listen") { changeRole(recipient, "listen") }
                Button("Can comment") { changeRole(recipient, "comment") }
                Button("Can download") { changeRole(recipient, "download") }
                Button("Revoke", role: .destructive) { revoke(recipient) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(PB.pencil)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 15) }
    }

    private func copy() {
        error = nil
        linkFailureRevert?.cancel()
        withAnimation { linkIssue = nil }
        guard Config.useRemoteAPI else {
            showLinkIssue(.failed)
            return
        }
        // Honest gate: a local-only track can never resolve on the server —
        // don't POST a link that's guaranteed to fail.
        guard !store.isLocalOnlyTrack(track.id) else {
            showLinkIssue(.notSynced)
            return
        }
        isCreating = true
        Task {
            do {
                let created = try await ensureShareLink()
                #if canImport(UIKit)
                UIPasteboard.general.string = created.url
                #endif
                await MainActor.run {
                    isCreating = false
                    withAnimation { copied = true }
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    showLinkIssue(.from(error))
                }
            }
        }
    }

    /// Honest state: link creation failed (or is impossible), so nothing was
    /// copied. The COPY control shows a quiet mono-caps inline state, reverts
    /// to idle after ~4s, and tapping it retries the request.
    private func showLinkIssue(_ issue: ShareLinkIssue) {
        withAnimation {
            copied = false
            linkIssue = issue
        }
        linkFailureRevert = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation { linkIssue = nil }
            }
        }
    }

    private func invite() {
        error = nil
        // Same honest gate as COPY — an invite needs a link, and a link
        // needs the song to exist on the server.
        guard !store.isLocalOnlyTrack(track.id) else {
            showLinkIssue(.notSynced)
            return
        }
        isCreating = true
        Task {
            do {
                let created = try await ensureShareLink()
                let result = try await store.inviteRecipients(
                    linkID: created.linkID,
                    recipients: [(
                        email: recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                        displayName: recipientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : recipientName,
                        role: apiRole
                    )]
                )
                await MainActor.run {
                    recipients = result.recipients
                    delivery = result.delivery == "queued" ? "Invite email queued" : "Invite saved; copy the link to send manually"
                    recipientEmail = ""
                    recipientName = ""
                    isCreating = false
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    // The invite rides on link creation — surface the same
                    // differentiated state instead of a generic failure.
                    switch ShareLinkIssue.from(error) {
                    case .failed: self.error = "Invite unavailable"
                    case let issue: showLinkIssue(issue)
                    }
                }
            }
        }
    }

    private func ensureShareLink() async throws -> CreatedShareLinkSummary {
        if let linkID, let link {
            return CreatedShareLinkSummary(linkID: linkID, url: link)
        }
        let created = try await store.createShareLinkDetails(for: track, allowDownload: role == .download)
        await MainActor.run {
            linkID = created.linkID
            link = created.url
        }
        return created
    }

    private func changeRole(_ recipient: ServiceClient.APIShareRecipient, _ role: String) {
        guard let linkID else { return }
        Task {
            if let updated = try? await store.changeRecipientRole(linkID: linkID, recipientID: recipient.recipient_id, role: role) {
                await MainActor.run {
                    recipients = recipients.map { $0.recipient_id == updated.recipient_id ? updated : $0 }
                }
            }
        }
    }

    private func revoke(_ recipient: ServiceClient.APIShareRecipient) {
        guard let linkID else { return }
        Task {
            if let updated = try? await store.revokeRecipient(linkID: linkID, recipientID: recipient.recipient_id) {
                await MainActor.run {
                    recipients = recipients.map { $0.recipient_id == updated.recipient_id ? updated : $0 }
                }
            }
        }
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "download": return "Can download"
        case "comment": return "Can comment"
        default: return "Can listen"
        }
    }
}

// MARK: - Add to playlist (duplicate into another list)

struct AddToPlaylistView: View {
    var track: Track
    var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var addedTo: String? = nil
    @State private var newTitle = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    MonoLabel("New playlist", color: PB.pencil, size: 10, tracking: 2)
                    HStack(spacing: 10) {
                        TextField("Playlist title", text: $newTitle)
                            .font(PB.text(15)).foregroundStyle(PB.cream).tint(PB.cobalt)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
                        Button {
                            let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            let playlist = store.createKeptPlaylist(title: title.isEmpty ? "\(track.title) List" : title, trackIDs: [track.id])
                            addedTo = playlist.id
                            newTitle = ""
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(PB.black)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(PB.cream))
                        }
                        .buttonStyle(.plain)
                    }
                }

                MonoLabel("Add a copy to", color: PB.pencil, size: 10, tracking: 2)
                VStack(spacing: 0) {
                    ForEach(store.playlists) { playlist in
                        Button {
                            store.addTrack(track.id, toPlaylist: playlist.id)
                            withAnimation { addedTo = playlist.id }
                        } label: {
                            HStack {
                                Text(playlist.title).font(PB.text(15)).foregroundStyle(PB.cream)
                                Spacer()
                                if addedTo == playlist.id {
                                    Label("Added", systemImage: "checkmark").font(PB.mono(10)).foregroundStyle(PB.green)
                                } else if playlist.trackIDs.contains(track.id) {
                                    MonoLabel("In list", color: PB.pencil, size: 9, tracking: 1)
                                }
                            }
                            .padding(15).contentShape(Rectangle())
                            .overlay(alignment: .bottom) { Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                MonoLabel("A copy is placed in the list; the original stays here.",
                          color: PB.pencil, size: 9, tracking: 0.6)
                    .padding(.top, 4)
            }
            .padding(22)
        }
        .background(PB.black)
        .navigationTitle("Add to playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PB.black, for: .navigationBar)
        .foregroundStyle(PB.cream)
    }
}

// MARK: - Add to project

struct AddToProjectView: View {
    var track: Track
    var store: WorkspaceStore
    @State private var addedTo: String? = nil
    @State private var newTitle = ""
    @State private var newArtist = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    MonoLabel("New project", color: PB.pencil, size: 10, tracking: 2)
                    VStack(spacing: 10) {
                        TextField("Project title", text: $newTitle)
                            .font(PB.text(15)).foregroundStyle(PB.cream).tint(PB.cobalt)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
                        HStack(spacing: 10) {
                            TextField("Artist", text: $newArtist)
                                .font(PB.text(15)).foregroundStyle(PB.cream).tint(PB.cobalt)
                                .padding(14)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
                            Button {
                                let room = store.createProject(
                                    title: newTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                                    artist: newArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? track.artist : newArtist
                                )
                                store.addTrack(track.id, toProject: room.id)
                                addedTo = room.id
                                newTitle = ""
                                newArtist = ""
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(PB.black)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(canCreate ? PB.cream : PB.pencil))
                            }
                            .buttonStyle(.plain)
                            .disabled(!canCreate)
                        }
                    }
                }

                MonoLabel("Add to", color: PB.pencil, size: 10, tracking: 2)
                VStack(spacing: 0) {
                    ForEach(store.rooms) { room in
                        Button {
                            store.addTrack(track.id, toProject: room.id)
                            withAnimation { addedTo = room.id }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(room.title).font(PB.text(15)).foregroundStyle(PB.cream)
                                    MonoLabel(room.artist, color: PB.pencil, size: 9, tracking: 1)
                                }
                                Spacer()
                                if addedTo == room.id {
                                    Label("Added", systemImage: "checkmark").font(PB.mono(10)).foregroundStyle(PB.green)
                                } else if room.trackIDs.contains(track.id) {
                                    MonoLabel("In project", color: PB.pencil, size: 9, tracking: 1)
                                }
                            }
                            .padding(15).contentShape(Rectangle())
                            .overlay(alignment: .bottom) { Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
            }
            .padding(22)
        }
        .background(PB.black)
        .navigationTitle("Add to project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PB.black, for: .navigationBar)
        .foregroundStyle(PB.cream)
    }

    private var canCreate: Bool {
        !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Rename

struct RenameView: View {
    var track: Track
    var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MonoLabel("Title", color: PB.pencil, size: 10, tracking: 2)
                TextField("Title", text: $text)
                    .font(PB.display(22)).foregroundStyle(PB.cream).tint(PB.cobalt)
                    .padding(15)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.1), lineWidth: 1))
                Button {
                    store.rename(track.id, text)
                    dismiss()
                } label: {
                    Text("SAVE").font(PB.mono(11)).tracking(1.5).foregroundStyle(PB.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Capsule().fill(PB.cream))
                }
                .buttonStyle(.plain)
            }
            .padding(22)
        }
        .background(PB.black)
        .navigationTitle("Rename")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PB.black, for: .navigationBar)
        .foregroundStyle(PB.cream)
        .onAppear { text = store.displayTitle(track.id, track.title) }
    }
}

// MARK: - First Listen + Listening Room MVP

private enum FirstListenDecisionOption: String, CaseIterable, Identifiable {
    case generalReaction = "general_reaction"
    case singleCandidate = "single_candidate"
    case meetingInterest = "meeting_interest"
    case forwardInterest = "forward_interest"
    case syncFit = "sync_fit"
    case mixNote = "mix_note"
    case versionComparison = "version_comparison"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .generalReaction: return "First reaction"
        case .singleCandidate: return "Single?"
        case .meetingInterest: return "Meeting?"
        case .forwardInterest: return "Forward?"
        case .syncFit: return "Sync fit?"
        case .mixNote: return "Mix note?"
        case .versionComparison: return "Version compare"
        }
    }
}

private enum RoomTypeOption: String, CaseIterable, Identifiable {
    case firstListenRoom = "first_listen_room"
    case revisionRoom = "revision_room"
    case singleRoom = "single_room"
    case mixNotesRoom = "mix_notes_room"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .firstListenRoom: return "First listen"
        case .revisionRoom: return "Revision"
        case .singleRoom: return "Single"
        case .mixNotesRoom: return "Mix notes"
        }
    }
}

private enum RoomRetentionOption: String, CaseIterable, Identifiable {
    case disappear = "disappear_after_room"
    case visible24h = "visible_24h"
    case saveToProject = "save_to_project"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .disappear: return "Disappear"
        case .visible24h: return "24h"
        case .saveToProject: return "Save"
        }
    }
}

struct CreateFirstListenView: View {
    let track: Track
    @State private var decision: FirstListenDecisionOption = .generalReaction
    @State private var contextNote = ""
    @State private var recipientEmail = ""
    @State private var recipientName = ""
    @State private var expiresAt = Date().addingTimeInterval(7 * 24 * 60 * 60)
    @State private var usesDeadline = true
    @State private var created: ServiceClient.APICreatedFirstListen?
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PBTrackHeader(track: track, eyebrow: "First Listen")
                if let created {
                    FirstListenShareDetailView(created: created, link: Config.firstListenURL(token: created.token))
                } else {
                    firstListenForm
                }
                if let error { MonoLabel(error, color: PB.redline, size: 9, tracking: 1) }
            }
            .padding(22)
        }
        .background(PB.black)
        .navigationTitle("First Listen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PB.black, for: .navigationBar)
        .foregroundStyle(PB.cream)
    }

    private var firstListenForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            PBStatusCard(
                eyebrow: "Protected screener",
                title: "Make the first play count",
                detail: "One focused listen, a typed decision, and replay by request.",
                color: PB.cobalt,
                icon: "headphones"
            )
            PBSection("Decision request") {
                Picker("Decision", selection: $decision) {
                    ForEach(FirstListenDecisionOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .tint(PB.cream)
                .padding(14)
            }
            PBSection("Recipient") {
                PBTextField("Email optional", text: $recipientEmail, keyboard: .emailAddress)
                PBTextField("Name optional", text: $recipientName)
            }
            PBSection("Context") {
                TextField("Purpose or framing", text: $contextNote, axis: .vertical)
                    .lineLimit(3...5)
                    .font(PB.text(15))
                    .foregroundStyle(PB.cream)
                    .tint(PB.cobalt)
                    .padding(14)
                Toggle("Deadline", isOn: $usesDeadline)
                    .font(PB.text(14))
                    .tint(PB.cobalt)
                    .padding(.horizontal, 14)
                if usesDeadline {
                    DatePicker("Expires", selection: $expiresAt, displayedComponents: [.date, .hourAndMinute])
                        .font(PB.text(14))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
            }
            PBPrimaryButton(title: isCreating ? "CREATING" : "CREATE FIRST LISTEN", isDisabled: isCreating) {
                create()
            }
        }
    }

    private func create() {
        guard !isCreating else { return }
        isCreating = true
        error = nil
        Task {
            do {
                let result = try await ServiceClient.shared.createFirstListen(
                    trackID: track.id,
                    versionID: track.remoteVersionID,
                    decisionRequestType: decision.rawValue,
                    contextNote: contextNote,
                    recipientEmail: recipientEmail,
                    displayName: recipientName,
                    expiresAt: usesDeadline ? expiresAt : nil
                )
                await MainActor.run {
                    created = result
                    isCreating = false
                }
            } catch {
                await MainActor.run {
                    self.error = "First Listen unavailable"
                    isCreating = false
                }
            }
        }
    }
}

struct FirstListenShareDetailView: View {
    let created: ServiceClient.APICreatedFirstListen
    let link: String
    @State private var detail: ServiceClient.APIFirstListenDetail?
    @State private var linkURL: IdentifiableURL?
    @State private var copied = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PBStatusCard(
                eyebrow: created.session.status.replacingOccurrences(of: "_", with: " "),
                title: "First Listen is ready",
                detail: "\(decisionLabel(created.session.decision_request_type)) · \(recipientName)",
                color: stateColor(created.recipient.access_state),
                icon: "checkmark.seal"
            )

            PBLinkCard(title: "Recipient link", link: link, copied: copied, onCopy: copy, onShare: share)

            PBMetricGrid(metrics: [
                PBMetric(title: "Opened", value: "\(openedCount)", detail: "\(recipients.count) sent"),
                PBMetric(title: "Started", value: "\(startedCount)", detail: "play events"),
                PBMetric(title: "Complete", value: "\(completedCount)", detail: "90%+ heard", color: completedCount > 0 ? PB.green : PB.pencil),
                PBMetric(title: "Decisions", value: "\(decisions.count)", detail: "submitted", color: decisions.isEmpty ? PB.pencil : PB.cobalt)
            ])

            PBSection("Recipients") {
                ForEach(recipients) { recipient in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recipient.display_name ?? recipient.recipient_email ?? "Recipient")
                                .font(PB.text(15))
                                .foregroundStyle(PB.cream)
                                .lineLimit(1)
                            MonoLabel(recipientDetail(recipient), color: PB.pencil, size: 8, tracking: 0.8)
                        }
                        Spacer(minLength: 8)
                        if recipient.access_state == "replay_requested" {
                            Button("GRANT") { grant(recipient) }
                                .font(PB.mono(10))
                                .foregroundStyle(PB.cobalt)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(PB.cobalt.opacity(0.14)))
                        } else {
                            PBStatusPill(label: recipient.access_state, color: stateColor(recipient.access_state))
                        }
                    }
                    .padding(14)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 14)
                    }
                }
            }

            if !decisions.isEmpty {
                PBSection("Decisions") {
                    ForEach(decisions) { response in
                        HStack(alignment: .top, spacing: 12) {
                            PBStatusPill(label: response.response_value, color: decisionColor(response.response_value))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(decisionLabel(response.response_value))
                                    .font(PB.text(15))
                                    .foregroundStyle(PB.cream)
                                if let note = response.text_note, !note.isEmpty {
                                    Text(note)
                                        .font(PB.text(13))
                                        .foregroundStyle(PB.pencil)
                                }
                            }
                            Spacer()
                        }
                        .padding(14)
                    }
                }
            }

            NavigationLink { FirstListenReportView(sessionID: created.session.share_session_id) } label: {
                MenuRow(icon: "doc.text.magnifyingglass", title: "Open report", detail: "Responses · pulses")
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))

            if let error { MonoLabel(error, color: PB.redline, size: 9, tracking: 1) }
        }
        .task { await refresh() }
        .shareSheet(item: $linkURL) { wrapper in
            return [wrapper.url.absoluteString]
        }
    }

    private var recipients: [ServiceClient.APIShareSessionRecipient] {
        detail?.recipients ?? [created.recipient]
    }

    private var decisions: [ServiceClient.APIDecisionResponse] {
        detail?.decisions ?? []
    }

    private var openedCount: Int {
        recipients.filter { $0.opened_at != nil || $0.access_state != "unused" }.count
    }

    private var startedCount: Int {
        recipients.filter { $0.started_at != nil || ["started", "completed", "replay_requested", "replay_granted"].contains($0.access_state) }.count
    }

    private var completedCount: Int {
        recipients.filter { $0.completed_at != nil || ["completed", "replay_requested"].contains($0.access_state) }.count
    }

    private var recipientName: String {
        let recipient = created.recipient
        return recipient.display_name ?? recipient.recipient_email ?? "Recipient"
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = link
        #endif
        withAnimation { copied = true }
    }

    private func share() {
        if let url = URL(string: link) { linkURL = IdentifiableURL(url) }
    }

    private func refresh() async {
        detail = try? await ServiceClient.shared.firstListen(created.session.share_session_id)
    }

    private func grant(_ recipient: ServiceClient.APIShareSessionRecipient) {
        Task {
            do {
                detail = try await ServiceClient.shared.grantFirstListenReplay(sessionID: created.session.share_session_id, recipientID: recipient.recipient_id)
            } catch {
                self.error = "Replay grant unavailable"
            }
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "completed", "opened", "started": return PB.green
        case "replay_requested": return PB.redline
        case "replay_granted": return PB.cobalt
        case "expired", "revoked": return PB.redline
        default: return PB.pencil
        }
    }

    private func recipientDetail(_ recipient: ServiceClient.APIShareSessionRecipient) -> String {
        if let completed = recipient.completed_at { return "completed \(shortDate(completed))" }
        if let started = recipient.started_at { return "started \(shortDate(started))" }
        if let opened = recipient.opened_at { return "opened \(shortDate(opened))" }
        return "not opened"
    }
}

struct FirstListenReportView: View {
    let sessionID: String
    @State private var report: ServiceClient.APIListeningReport?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let report {
                    FirstListenReportSummaryView(report: report)
                } else {
                    PBLoadingState(message: error ?? "Loading report", isError: error != nil)
                }
            }
            .padding(22)
        }
        .background(PB.black)
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PB.black, for: .navigationBar)
        .task {
            do { report = try await ServiceClient.shared.firstListenReport(sessionID) }
            catch { self.error = "Report unavailable" }
        }
    }
}

struct CreateListeningRoomView: View {
    let track: Track
    @State private var roomType: RoomTypeOption = .firstListenRoom
    @State private var retention: RoomRetentionOption = .saveToProject
    @State private var decision: FirstListenDecisionOption = .generalReaction
    @State private var title = ""
    @State private var contextNote = ""
    @State private var scheduled = false
    @State private var scheduledAt = Date().addingTimeInterval(60 * 60)
    @State private var created: ServiceClient.APICreatedListeningRoom?
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PBTrackHeader(track: track, eyebrow: "Listening Room")
                if let created {
                    ListeningRoomHostView(created: created, link: Config.listeningRoomURL(token: created.token))
                } else {
                    listeningRoomForm
                }
                if let error { MonoLabel(error, color: PB.redline, size: 9, tracking: 1) }
            }
            .padding(22)
        }
        .background(PB.black)
        .navigationTitle("Listening Room")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PB.black, for: .navigationBar)
        .foregroundStyle(PB.cream)
    }

    private var listeningRoomForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            PBStatusCard(
                eyebrow: "Private room",
                title: "Turn the room into the report",
                detail: "\(roomType.label) · \(retentionDetail(retention))",
                color: PB.green,
                icon: "person.3.sequence"
            )
            PBSection("Room") {
                PBTextField("Room title", text: $title)
                Picker("Type", selection: $roomType) {
                    ForEach(RoomTypeOption.allCases) { option in Text(option.label).tag(option) }
                }
                .pickerStyle(.segmented)
                .padding(14)
                Picker("Retention", selection: $retention) {
                    ForEach(RoomRetentionOption.allCases) { option in Text(option.label).tag(option) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            PBSection("Purpose") {
                Picker("Decision", selection: $decision) {
                    ForEach(FirstListenDecisionOption.allCases) { option in Text(option.label).tag(option) }
                }
                .pickerStyle(.menu)
                .tint(PB.cream)
                .padding(14)
                TextField("Context", text: $contextNote, axis: .vertical)
                    .lineLimit(3...5)
                    .font(PB.text(15))
                    .foregroundStyle(PB.cream)
                    .tint(PB.cobalt)
                    .padding(14)
            }
            PBSection("Schedule") {
                Toggle("Schedule", isOn: $scheduled)
                    .font(PB.text(14)).tint(PB.cobalt).padding(14)
                if scheduled {
                    DatePicker("Starts", selection: $scheduledAt, displayedComponents: [.date, .hourAndMinute])
                        .font(PB.text(14)).padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
            PBPrimaryButton(title: isCreating ? "CREATING" : "CREATE LISTENING ROOM", isDisabled: isCreating) {
                create()
            }
        }
    }

    private func create() {
        isCreating = true
        error = nil
        Task {
            do {
                let result = try await ServiceClient.shared.createListeningRoom(
                    trackID: track.id,
                    versionID: track.remoteVersionID,
                    roomType: roomType.rawValue,
                    title: title,
                    contextNote: contextNote,
                    decisionRequestType: decision.rawValue,
                    scheduledStartAt: scheduled ? scheduledAt : nil,
                    retentionPolicy: retention.rawValue
                )
                await MainActor.run {
                    created = result
                    isCreating = false
                }
            } catch {
                await MainActor.run {
                    self.error = "Listening Room unavailable"
                    isCreating = false
                }
            }
        }
    }
}

struct ListeningRoomHostView: View {
    let created: ServiceClient.APICreatedListeningRoom
    let link: String
    @State private var detail: ServiceClient.APIListeningRoomDetail?
    @State private var report: ServiceClient.APIListeningReport?
    @State private var linkURL: IdentifiableURL?
    @State private var copied = false
    @State private var isStarting = false
    @State private var isEnding = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PBStatusCard(
                eyebrow: lifecycleLabel,
                title: roomTitle,
                detail: "\(roomTypeLabel) · \(retentionLabel)",
                color: lifecycleColor,
                icon: lifecycleIcon
            )

            PBLinkCard(title: "Room link", link: link, copied: copied, onCopy: copy, onShare: share)

            PBMetricGrid(metrics: [
                PBMetric(title: "State", value: stateLabel, detail: "host sync", color: lifecycleColor),
                PBMetric(title: "Attending", value: "\(joinedCount)", detail: "\(participants.count) invited", color: joinedCount > 0 ? PB.green : PB.pencil),
                PBMetric(title: "First Takes", value: "\(firstTakeCount)", detail: "submitted", color: firstTakeCount > 0 ? PB.cobalt : PB.pencil),
                PBMetric(title: "Retention", value: retentionShortLabel, detail: "history")
            ])

            HStack(spacing: 10) {
                PBControlButton(
                    title: isLive ? "LIVE" : (isStarting ? "STARTING" : "START"),
                    icon: isLive ? "dot.radiowaves.left.and.right" : "play.fill",
                    color: isLive ? PB.cobalt : PB.green,
                    isDisabled: isLive || isEnded || isStarting
                ) { start() }
                PBControlButton(
                    title: isEnding ? "ENDING" : "END",
                    icon: "stop.fill",
                    color: PB.redline,
                    isDisabled: isEnded || isEnding
                ) { end() }
            }

            PBSection("Participants") {
                ForEach(participants) { participant in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(participant.role_in_room == "host" ? PB.cobalt.opacity(0.24) : PB.green.opacity(0.18))
                            .frame(width: 34, height: 34)
                            .overlay(
                                Text(initials(participant.display_name ?? participant.recipient_email ?? "Listener"))
                                    .font(PB.mono(10))
                                    .foregroundStyle(PB.cream)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(participant.display_name ?? participant.recipient_email ?? "Listener")
                                .font(PB.text(15))
                                .foregroundStyle(PB.cream)
                                .lineLimit(1)
                            MonoLabel(participant.role_in_room, color: PB.pencil, size: 8, tracking: 1)
                        }
                        Spacer()
                        PBStatusPill(label: participantStatus(participant), color: participantStatusColor(participant))
                    }
                    .padding(14)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 14)
                    }
                }
            }

            if let report {
                NavigationLink { ListeningRoomReportView(report: report) } label: {
                    MenuRow(icon: "chart.bar.doc.horizontal", title: "Open room report", detail: report.visibility)
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
            }
            if let error { MonoLabel(error, color: PB.redline, size: 9, tracking: 1) }
        }
        .task { await refresh() }
        .shareSheet(item: $linkURL) { wrapper in
            return [wrapper.url.absoluteString]
        }
    }

    private var room: ServiceClient.APIListeningRoom {
        detail?.room ?? created.room
    }

    private var participants: [ServiceClient.APIListeningRoomParticipant] {
        detail?.participants ?? [created.host]
    }

    private var roomTitle: String { room.title }
    private var roomTypeLabel: String { room.room_type.replacingOccurrences(of: "_", with: " ") }
    private var retentionLabel: String { retentionDetail(RoomRetentionOption(rawValue: room.retention_policy) ?? .saveToProject) }
    private var retentionShortLabel: String { (RoomRetentionOption(rawValue: room.retention_policy) ?? .saveToProject).label }
    private var stateLabel: String { (detail?.state.playback_state ?? room.lifecycle_state).replacingOccurrences(of: "_", with: " ") }
    private var isLive: Bool { room.lifecycle_state == "live" || detail?.state.playback_state == "playing" }
    private var isEnded: Bool { room.lifecycle_state == "ended" || report != nil }
    private var lifecycleLabel: String { isEnded ? "ended" : isLive ? "live" : room.lifecycle_state }
    private var lifecycleColor: Color { isEnded ? PB.pencil : isLive ? PB.green : PB.cobalt }
    private var lifecycleIcon: String { isEnded ? "checkmark.circle" : isLive ? "dot.radiowaves.left.and.right" : "person.3.sequence" }
    private var joinedCount: Int { participants.filter { $0.joined_at != nil }.count }
    private var firstTakeCount: Int { participants.filter { $0.first_take_submitted_at != nil }.count }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = link
        #endif
        withAnimation { copied = true }
    }

    private func share() {
        if let url = URL(string: link) { linkURL = IdentifiableURL(url) }
    }

    private func refresh() async {
        detail = try? await ServiceClient.shared.listeningRoom(created.room.listening_room_id)
        if let existing = detail?.report { report = existing }
    }

    private func start() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            do {
                let updated = try await ServiceClient.shared.startListeningRoom(created.room.listening_room_id)
                await MainActor.run {
                    detail = updated
                    isStarting = false
                }
            } catch {
                await MainActor.run {
                    self.error = "Start unavailable"
                    isStarting = false
                }
            }
        }
    }

    private func end() {
        guard !isEnding else { return }
        isEnding = true
        Task {
            do {
                let generated = try await ServiceClient.shared.endListeningRoom(created.room.listening_room_id)
                let updated = try? await ServiceClient.shared.listeningRoom(created.room.listening_room_id)
                await MainActor.run {
                    report = generated
                    detail = updated
                    isEnding = false
                }
            } catch {
                await MainActor.run {
                    self.error = "End unavailable"
                    isEnding = false
                }
            }
        }
    }

    private func participantStatus(_ participant: ServiceClient.APIListeningRoomParticipant) -> String {
        if participant.first_take_submitted_at != nil { return "first take" }
        if participant.completed_at != nil { return "complete" }
        if participant.joined_at != nil { return "joined" }
        return "invited"
    }

    private func participantStatusColor(_ participant: ServiceClient.APIListeningRoomParticipant) -> Color {
        if participant.first_take_submitted_at != nil { return PB.cobalt }
        if participant.completed_at != nil || participant.joined_at != nil { return PB.green }
        return PB.pencil
    }
}

struct ListeningRoomReportView: View {
    let report: ServiceClient.APIListeningReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ListeningRoomReportSummaryView(report: report)
            }
            .padding(22)
        }
        .background(PB.black)
        .navigationTitle("Room Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(PB.black, for: .navigationBar)
    }
}

private struct FirstListenReportSummaryView: View {
    let report: ServiceClient.APIListeningReport
    private var summary: ServiceClient.APIJSONValue { report.summary_json }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PBStatusCard(
                eyebrow: "First Listen Report",
                title: summary.string("track_title") ?? "First Listen",
                detail: reportSubtitle,
                color: PB.cobalt,
                icon: "doc.text.magnifyingglass"
            )
            PBMetricGrid(metrics: [
                PBMetric(title: "Opened", value: "\(summary.int("opened_count"))", detail: "\(summary.int("total_recipients")) sent"),
                PBMetric(title: "Started", value: "\(summary.int("started_count"))", detail: "play events"),
                PBMetric(title: "Complete", value: "\(summary.int("completed_count"))", detail: "\(summary.int("completion_rate"))%", color: summary.int("completed_count") > 0 ? PB.green : PB.pencil),
                PBMetric(title: "Replay", value: "\(summary.int("replay_requests"))", detail: "requests", color: summary.int("replay_requests") > 0 ? PB.redline : PB.pencil)
            ])
            DecisionBreakdownView(counts: summary.object("decision_counts"))
            PBSection("Moments") {
                PBReportRow(title: "Pulse peaks", value: "\(summary.array("top_pulse_moments").count)", color: PB.cobalt)
                PBReportRow(title: "Timestamp markers", value: "\(summary.array("timestamp_markers").count)", color: PB.green)
                PBReportRow(title: "Voice and text notes", value: "\(summary.array("notes").count)", color: PB.pencil)
            }
            PBSection("Version heard") {
                PBReportRow(title: summary.string("version_label") ?? "Version", value: summary.string("version_id") ?? "current", color: PB.pencil)
            }
        }
    }

    private var reportSubtitle: String {
        [
            summary.string("artist_name"),
            summary.string("project_name"),
            summary.string("version_label")
        ]
        .compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        .joined(separator: " · ")
    }
}

private struct ListeningRoomReportSummaryView: View {
    let report: ServiceClient.APIListeningReport
    private var summary: ServiceClient.APIJSONValue { report.summary_json }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PBStatusCard(
                eyebrow: "Listening Room Report",
                title: summary.string("room_title") ?? summary.string("track_title") ?? "Room Report",
                detail: reportSubtitle,
                color: PB.green,
                icon: "chart.bar.doc.horizontal"
            )
            PBMetricGrid(metrics: [
                PBMetric(title: "Attended", value: "\(summary.int("attended_count"))", detail: "\(summary.int("invited_count")) invited", color: PB.green),
                PBMetric(title: "Complete", value: "\(summary.int("completed_count"))", detail: "listeners"),
                PBMetric(title: "Duration", value: durationClock(summary.int("room_duration_ms")), detail: "room time", color: PB.cobalt),
                PBMetric(title: "Retention", value: retentionShort(summary.string("retention_policy")), detail: report.visibility)
            ])
            DecisionBreakdownView(counts: summary.object("decision_counts"))
            PBSection("Room replay") {
                PBReportRow(title: "Pulse peaks", value: "\(summary.array("top_pulse_moments").count)", color: PB.cobalt)
                PBReportRow(title: "Run it back", value: "\(summary.array("run_it_back_requests").count)", color: PB.redline)
                PBReportRow(title: "Timestamped notes", value: "\(summary.array("timestamped_notes").count)", color: PB.green)
                PBReportRow(title: "First takes", value: "\(summary.array("participant_first_takes").count)", color: PB.pencil)
            }
            PBSection("Next step") {
                PBReportRow(title: summary.string("next_step") ?? "Set next step", value: summary.string("lifecycle_state") ?? "ended", color: PB.cobalt)
            }
        }
    }

    private var reportSubtitle: String {
        [
            summary.string("artist_name"),
            summary.string("project_name"),
            summary.string("version_label")
        ]
        .compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        .joined(separator: " · ")
    }
}

private struct DecisionBreakdownView: View {
    let counts: [String: ServiceClient.APIJSONValue]

    var body: some View {
        PBSection("Decisions") {
            if counts.isEmpty {
                PBReportRow(title: "No decisions yet", value: "0", color: PB.pencil)
            } else {
                ForEach(counts.keys.sorted(), id: \.self) { key in
                    PBReportRow(
                        title: decisionLabel(key),
                        value: "\(counts[key]?.intValue ?? 0)",
                        color: decisionColor(key)
                    )
                }
            }
        }
    }
}

private struct PBMetric: Identifiable {
    var id: String { title }
    let title: String
    let value: String
    var detail: String
    var color: Color = PB.cream
}

private struct PBMetricGrid: View {
    let metrics: [PBMetric]
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 7) {
                    MonoLabel(metric.title, color: PB.pencil, size: 8, tracking: 1.4)
                    Text(metric.value)
                        .font(PB.display(28))
                        .foregroundStyle(metric.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    MonoLabel(metric.detail, color: PB.pencil.opacity(0.75), size: 8, tracking: 0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
            }
        }
    }
}

private struct PBStatusCard: View {
    let eyebrow: String
    let title: String
    let detail: String
    let color: Color
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(Circle().fill(color.opacity(0.14)))
                .overlay(Circle().strokeBorder(color.opacity(0.32), lineWidth: 1))
            VStack(alignment: .leading, spacing: 5) {
                MonoLabel(eyebrow, color: color, size: 9, tracking: 1.6)
                Text(title)
                    .font(PB.display(24))
                    .foregroundStyle(PB.cream)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                if !detail.isEmpty {
                    Text(detail)
                        .font(PB.text(13))
                        .foregroundStyle(PB.pencil)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.28), lineWidth: 1))
    }
}

private struct PBLinkCard: View {
    let title: String
    let link: String
    let copied: Bool
    let onCopy: () -> Void
    let onShare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(title, color: PB.pencil, size: 10, tracking: 2)
            HStack(spacing: 10) {
                Text(link)
                    .font(PB.mono(11))
                    .foregroundStyle(PB.cream)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copied ? "COPIED" : "COPY", action: onCopy)
                    .font(PB.mono(10))
                    .foregroundStyle(copied ? PB.green : PB.cobalt)
                Button("SHARE", action: onShare)
                    .font(PB.mono(10))
                    .foregroundStyle(PB.cobalt)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
        }
    }
}

private struct PBStatusPill: View {
    let label: String
    let color: Color

    var body: some View {
        MonoLabel(label.replacingOccurrences(of: "_", with: " "), color: color, size: 8, tracking: 1.1)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.13)))
            .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 1))
    }
}

private struct PBPrimaryButton: View {
    let title: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PB.mono(11))
                .tracking(1.4)
                .foregroundStyle(PB.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Capsule().fill(isDisabled ? PB.pencil : PB.cream))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct PBControlButton: View {
    let title: String
    let icon: String
    let color: Color
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(PB.mono(10))
                .foregroundStyle(isDisabled ? PB.pencil : (color == PB.green ? PB.black : PB.cream))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(isDisabled ? PB.panel : color))
                .overlay(Capsule().strokeBorder(color.opacity(isDisabled ? 0.28 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct PBReportRow: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(PB.text(15))
                .foregroundStyle(PB.cream)
                .lineLimit(2)
            Spacer(minLength: 10)
            Text(value.isEmpty ? "0" : value)
                .font(PB.mono(12))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 14)
        }
    }
}

private struct PBLoadingState: View {
    let message: String
    var isError = false

    var body: some View {
        HStack(spacing: 12) {
            if !isError { ProgressView().tint(PB.pencil) }
            MonoLabel(message, color: isError ? PB.redline : PB.pencil, size: 10, tracking: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
    }
}

private struct PBTrackHeader: View {
    let track: Track
    let eyebrow: String

    var body: some View {
        HStack(spacing: 14) {
            TrackArtwork(track: track, cornerRadius: 8, animateFallback: false)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                MonoLabel(eyebrow, color: PB.pencil, size: 10, tracking: 2)
                Text(track.title).font(PB.display(24)).foregroundStyle(PB.cream)
                MonoLabel("\(track.artist) · \(track.versionLabel)", color: PB.pencil, size: 9, tracking: 1)
            }
            Spacer()
        }
    }
}

private struct PBSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(title, color: PB.pencil, size: 10, tracking: 2)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.07), lineWidth: 1))
        }
    }
}

private struct PBTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    init(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) {
        self.placeholder = placeholder
        self._text = text
        self.keyboard = keyboard
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .font(PB.text(15))
            .foregroundStyle(PB.cream)
            .tint(PB.cobalt)
            .keyboardType(keyboard)
            .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)
            .padding(14)
            .overlay(alignment: .bottom) { Rectangle().fill(PB.cream.opacity(0.06)).frame(height: 1).padding(.leading, 14) }
    }
}

private func decisionLabel(_ raw: String) -> String {
    switch raw {
    case "general_reaction": return "First reaction"
    case "single_candidate": return "Single candidate"
    case "meeting_interest": return "Meeting interest"
    case "forward_interest": return "Forward internally"
    case "sync_fit": return "Sync fit"
    case "mix_note": return "Mix revision"
    case "version_comparison": return "Version comparison"
    case "love": return "Love"
    case "hold": return "Hold"
    case "pass": return "Pass"
    case "need_context": return "Need Context"
    case "needs_revision": return "Needs Revision"
    case "would_forward": return "Would Forward"
    default:
        return raw
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

private func decisionColor(_ raw: String) -> Color {
    switch raw {
    case "love", "would_forward": return PB.green
    case "hold", "need_context", "needs_revision": return PB.cobalt
    case "pass": return PB.redline
    default: return PB.pencil
    }
}

private func shortDate(_ value: String) -> String {
    if value.count >= 10 { return String(value.prefix(10)) }
    return value
}

private func durationClock(_ milliseconds: Int) -> String {
    let seconds = max(0, milliseconds / 1000)
    let minutes = seconds / 60
    let remainder = seconds % 60
    return "\(minutes):" + String(format: "%02d", remainder)
}

private func retentionDetail(_ option: RoomRetentionOption) -> String {
    switch option {
    case .disappear: return "Disappears after room"
    case .visible24h: return "Visible for 24h"
    case .saveToProject: return "Saved to project"
    }
}

private func retentionShort(_ raw: String?) -> String {
    switch raw {
    case "disappear_after_room": return "Disappear"
    case "visible_24h": return "24h"
    case "save_to_project": return "Project"
    default: return "Project"
    }
}

private func initials(_ value: String) -> String {
    let pieces = value
        .split(separator: " ")
        .prefix(2)
        .compactMap { $0.first }
    let output = String(pieces).uppercased()
    return output.isEmpty ? "PB" : output
}

private extension ServiceClient.APIJSONValue {
    var objectValue: [String: ServiceClient.APIJSONValue] {
        if case .object(let value) = self { return value }
        return [:]
    }

    var arrayValue: [ServiceClient.APIJSONValue] {
        if case .array(let value) = self { return value }
        return []
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    func string(_ key: String) -> String? {
        objectValue[key]?.stringValue
    }

    func int(_ key: String) -> Int {
        objectValue[key]?.intValue ?? 0
    }

    func array(_ key: String) -> [ServiceClient.APIJSONValue] {
        objectValue[key]?.arrayValue ?? []
    }

    func object(_ key: String) -> [String: ServiceClient.APIJSONValue] {
        objectValue[key]?.objectValue ?? [:]
    }
}
