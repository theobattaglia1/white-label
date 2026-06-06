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

    private var track: Track { player.track }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 5) {
                        MonoLabel("Track", color: WL.pencil, size: 10, tracking: 2)
                        Text(store.displayTitle(track.id, track.title))
                            .font(WL.display(24)).foregroundStyle(WL.cream)
                        MonoLabel("\(track.artist) · \(track.catalog)", color: WL.pencil, size: 10, tracking: 1.2)
                    }

                    group {
                        Button { store.togglePin(PinRef(kind: .song, targetID: track.id).id) } label: {
                            let pinned = store.isPinned(PinRef(kind: .song, targetID: track.id).id)
                            MenuRow(icon: pinned ? "pin.slash" : "pin",
                                    title: pinned ? "Unpin from Home" : "Pin to Home", detail: nil,
                                    tint: pinned ? WL.cobalt : WL.cream)
                        }
                        NavigationLink { ShareView(track: track) } label: {
                            MenuRow(icon: "person.2", title: "Share", detail: "Set who can access")
                        }
                        Button { copyLink() } label: {
                            MenuRow(icon: "link", title: copied ? "Link copied" : "Copy link",
                                    detail: nil, tint: copied ? WL.green : WL.cream)
                        }
                        NavigationLink { AddToPlaylistView(track: track) } label: {
                            MenuRow(icon: "plus.square.on.square", title: "Add to playlist", detail: "Copy into another list")
                        }
                    }

                    group {
                        Button { exportFile() } label: {
                            MenuRow(icon: "arrow.down.circle", title: exported ? "Export started" : "Export",
                                    detail: "WAV · if allowed", tint: exported ? WL.green : WL.cream)
                        }
                        NavigationLink { RenameView(track: track, store: store) } label: {
                            MenuRow(icon: "pencil", title: "Rename", detail: "Owner")
                        }
                    }
                }
                .padding(22)
            }
            .background(WL.black)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(WL.mono(13)).foregroundStyle(WL.cobalt)
                }
            }
            .toolbarBackground(WL.black, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(WL.black)
        .foregroundStyle(WL.cream)
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WL.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WL.cream.opacity(0.07), lineWidth: 1))
    }

    private func copyLink() {
        #if canImport(UIKit)
        UIPasteboard.general.string = "https://whitelabel.fm/s/\(track.catalog.replacingOccurrences(of: "WL · ", with: ""))"
        #endif
        withAnimation { copied = true }
    }

    private func exportFile() {
        withAnimation { exported = true }
    }
}

private struct MenuRow: View {
    var icon: String
    var title: String
    var detail: String?
    var tint: Color = WL.cream

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 22).foregroundStyle(tint)
            Text(title).font(WL.text(15)).foregroundStyle(tint)
            Spacer()
            if let detail { MonoLabel(detail, color: WL.pencil, size: 9, tracking: 1) }
        }
        .padding(.horizontal, 15).padding(.vertical, 14)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(WL.cream.opacity(0.06)).frame(height: 1).padding(.leading, 50) }
    }
}

// MARK: - Share (Google-Drive-style access)

enum ShareAccess: String, CaseIterable { case restricted = "Restricted", anyone = "Anyone with the link" }
enum ShareRole: String, CaseIterable { case listen = "Can listen", comment = "Can comment", download = "Can download" }

struct ShareView: View {
    var track: Track
    @State private var access: ShareAccess = .restricted
    @State private var role: ShareRole = .comment
    @State private var copied = false

    private var link: String { "whitelabel.fm/s/\(track.catalog.replacingOccurrences(of: "WL · ", with: ""))" }

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
                section("Link") {
                    HStack {
                        Text(link).font(WL.mono(12)).foregroundStyle(WL.cream).lineLimit(1)
                        Spacer()
                        Button { copy() } label: {
                            Text(copied ? "COPIED" : "COPY").font(WL.mono(10)).tracking(1)
                                .foregroundStyle(copied ? WL.green : WL.cobalt)
                        }.buttonStyle(.plain)
                    }
                    .padding(15)
                }
            }
            .padding(22)
        }
        .background(WL.black)
        .navigationTitle("Share")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(WL.black, for: .navigationBar)
        .foregroundStyle(WL.cream)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(title, color: WL.pencil, size: 10, tracking: 2)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WL.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WL.cream.opacity(0.07), lineWidth: 1))
        }
    }

    private func optionRow(_ title: String, sub: String?, selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(WL.text(15)).foregroundStyle(WL.cream)
                    if let sub { MonoLabel(sub, color: WL.pencil, size: 9, tracking: 0.6) }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? WL.cobalt : WL.pencil)
            }
            .padding(15).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = "https://\(link)"
        #endif
        withAnimation { copied = true }
    }
}

// MARK: - Add to playlist (duplicate into another list)

struct AddToPlaylistView: View {
    var track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var addedTo: String? = nil
    private let playlists = ["Friday Session", "Pitch — Mira", "Hudson Ingram LP", "Needs Your Ear"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                MonoLabel("Add a copy to", color: WL.pencil, size: 10, tracking: 2)
                VStack(spacing: 0) {
                    ForEach(playlists, id: \.self) { p in
                        Button { withAnimation { addedTo = p } } label: {
                            HStack {
                                Text(p).font(WL.text(15)).foregroundStyle(WL.cream)
                                Spacer()
                                if addedTo == p {
                                    Label("Added", systemImage: "checkmark").font(WL.mono(10)).foregroundStyle(WL.green)
                                }
                            }
                            .padding(15).contentShape(Rectangle())
                            .overlay(alignment: .bottom) { Rectangle().fill(WL.cream.opacity(0.06)).frame(height: 1) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WL.panel))
                MonoLabel("A copy is placed in the list — the original stays here.",
                          color: WL.pencil, size: 9, tracking: 0.6)
                    .padding(.top, 4)
            }
            .padding(22)
        }
        .background(WL.black)
        .navigationTitle("Add to playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(WL.black, for: .navigationBar)
        .foregroundStyle(WL.cream)
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
                MonoLabel("Title", color: WL.pencil, size: 10, tracking: 2)
                TextField("Title", text: $text)
                    .font(WL.display(22)).foregroundStyle(WL.cream).tint(WL.cobalt)
                    .padding(15)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WL.panel))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WL.cream.opacity(0.1), lineWidth: 1))
                Button {
                    store.rename(track.id, text)
                    dismiss()
                } label: {
                    Text("SAVE").font(WL.mono(11)).tracking(1.5).foregroundStyle(WL.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Capsule().fill(WL.cream))
                }
                .buttonStyle(.plain)
            }
            .padding(22)
        }
        .background(WL.black)
        .navigationTitle("Rename")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(WL.black, for: .navigationBar)
        .foregroundStyle(WL.cream)
        .onAppear { text = store.displayTitle(track.id, track.title) }
    }
}
