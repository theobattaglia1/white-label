import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The floating menu's contents — share, link, playlist, export, rename.
struct MenuSheet: View {
    var player: Player
    var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var exported = false
    @State private var showEditSong = false
    @State private var shareError: String?
    @State private var exportItems: [Any] = []
    @State private var showExportSheet = false

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
                        Button { copyLink() } label: {
                            MenuRow(icon: "link", title: copied ? "Link copied" : "Copy link",
                                    detail: nil, tint: copied ? PB.green : PB.cream)
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

    private func copyLink() {
        shareError = nil
        guard Config.useRemoteAPI else {
            copyLocalFallback()
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
                    shareError = "Link unavailable"
                    copyLocalFallback()
                }
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

    private func copyLocalFallback() {
        #if canImport(UIKit)
        UIPasteboard.general.string = Config.shareURL(token: track.id)
        #endif
        withAnimation { copied = true }
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

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 22).foregroundStyle(tint)
            Text(title).font(PB.text(15)).foregroundStyle(tint)
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
                            Text(isCreating ? "CREATING" : (copied ? "COPIED" : "COPY")).font(PB.mono(10)).tracking(1)
                                .foregroundStyle(copied ? PB.green : PB.cobalt)
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
        guard Config.useRemoteAPI else {
            let fallback = Config.shareURL(token: track.id)
            #if canImport(UIKit)
            UIPasteboard.general.string = fallback
            #endif
            link = fallback
            withAnimation { copied = true }
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
                    self.error = "Share link unavailable"
                }
            }
        }
    }

    private func invite() {
        error = nil
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
                    self.error = "Invite unavailable"
                    isCreating = false
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
