import SwiftUI

/// The workspace page that lives directly beneath Now Playing — scroll up to
/// reveal it. Switch versions and drop notes pinned to the moment you're
/// hearing. (No inner scroll: the outer pager owns scrolling.)
struct WorkspacePage: View {
    var player: Player
    var store: WorkspaceStore
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0
    var onCollapse: () -> Void
    @State private var noteText = ""
    @FocusState private var composing: Bool

    private var trackID: String { player.track.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            grabber
            header
            versionsSection
            notesSection
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, safeTop + 12)
        .padding(.bottom, safeBottom + 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WL.black)
        .clipped()
        .foregroundStyle(WL.cream)
    }

    private var grabber: some View {
        VStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WL.cream.opacity(0.45))
            Capsule().fill(WL.cream.opacity(0.18)).frame(width: 38, height: 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onCollapse() }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            MonoLabel("Workspace", color: WL.pencil, size: 10, tracking: 2.2)
            Text(player.track.title)
                .font(WL.display(26))
                .foregroundStyle(WL.cream)
            MonoLabel("\(player.track.artist) · \(store.currentVersion(trackID)?.label ?? player.track.versionLabel)",
                      color: WL.pencil, size: 10, tracking: 1.4)
        }
    }

    // MARK: versions

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            MonoLabel("Versions", color: WL.pencil, size: 10, tracking: 2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(store.versions(trackID)) { v in
                        let isCurrent = store.currentVersion(trackID)?.id == v.id
                        Button { store.setCurrent(trackID, v.id) } label: {
                            HStack(spacing: 7) {
                                Text(v.label).font(WL.mono(12))
                                if v.approved {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(WL.green)
                                }
                                Text(v.loudness).font(WL.mono(9)).foregroundStyle(isCurrent ? WL.cream.opacity(0.7) : WL.pencil)
                            }
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background(Capsule().fill(isCurrent ? WL.cobalt.opacity(0.18) : .clear))
                            .overlay(Capsule().strokeBorder(isCurrent ? WL.cobalt : WL.cream.opacity(0.16), lineWidth: 1))
                            .foregroundStyle(isCurrent ? WL.cream : WL.pencil)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    // MARK: notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                MonoLabel("Notes", color: WL.pencil, size: 10, tracking: 2)
                Spacer()
                MonoLabel("\(store.openCount(trackID)) open", color: WL.redline, size: 9, tracking: 1.4)
            }
            composer
            ForEach(store.notes(trackID)) { note in
                noteRow(note)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("+ \(player.positionMs.clock)")
                .font(WL.mono(11)).foregroundStyle(WL.cobalt)
            TextField("Leave a note at this moment…", text: $noteText, axis: .vertical)
                .font(WL.text(14))
                .foregroundStyle(WL.cream)
                .tint(WL.cobalt)
                .focused($composing)
                .lineLimit(1...4)
            if !noteText.trimmingCharacters(in: .whitespaces).isEmpty {
                Button {
                    store.addNote(track: trackID, positionMs: player.positionMs, body: noteText)
                    noteText = ""; composing = false
                } label: {
                    Text("ADD").font(WL.mono(10)).tracking(1)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(Capsule().fill(WL.cream))
                        .foregroundStyle(WL.black)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WL.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WL.cream.opacity(0.08), lineWidth: 1))
    }

    private func noteRow(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(note.resolved ? WL.green : WL.redline)
                .frame(width: 2)
                .opacity(note.resolved ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Text(note.positionMs.map { $0.clock } ?? "general")
                        .font(WL.mono(11))
                        .foregroundStyle(note.resolved ? WL.green : WL.cobalt)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(WL.cream.opacity(0.06)))
                    MonoLabel(note.author, color: WL.pencil, size: 9, tracking: 1.2)
                    Spacer()
                    Button { store.toggleResolved(trackID, note.id) } label: {
                        Text(note.resolved ? "Reopen" : "Resolve")
                            .font(WL.mono(9)).tracking(1)
                            .foregroundStyle(note.resolved ? WL.pencil : WL.green)
                    }
                    .buttonStyle(.plain)
                }
                Text(note.body)
                    .font(WL.text(14))
                    .foregroundStyle(note.resolved ? WL.pencil : WL.cream.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .opacity(note.resolved ? 0.7 : 1)
    }
}
