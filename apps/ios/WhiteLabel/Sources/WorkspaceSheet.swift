import SwiftUI

/// The workspace page beneath Now Playing. A waveform with a draggable marker
/// to place notes precisely, a mini-transport, version switching, and notes you
/// can tag, edit, resolve, and delete.
struct WorkspacePage: View {
    var player: Player
    var store: WorkspaceStore
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0
    @Binding var markerMs: Int?
    var composeToken: Int
    var onCollapse: () -> Void

    @State private var noteText = ""
    @State private var editing: UUID? = nil
    @FocusState private var composing: Bool

    private var trackID: String { player.track.id }
    private var duration: Int { max(1, player.track.durationMs) }
    private var markPos: Int { markerMs ?? player.positionMs }
    private var markFraction: Double { Double(markPos) / Double(duration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            grabber
            header
            waveSection
            versionsSection
            notesSection
        }
        .padding(.horizontal, 22)
        .padding(.top, safeTop + 12)
        .padding(.bottom, safeBottom + 28)
        .frame(maxWidth: .infinity, alignment: .top)
        .foregroundStyle(WL.cream)
        .contentShape(Rectangle())
        .onTapGesture { composing = false }   // tap anywhere empty to dismiss the keyboard
        .onChange(of: composeToken) { _, _ in
            // focus after the slide-up settles, so the keyboard doesn't fight the scroll
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { composing = true }
        }
    }

    private var grabber: some View {
        VStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(WL.cream.opacity(0.45))
            Capsule().fill(WL.cream.opacity(0.18)).frame(width: 38, height: 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { composing = false; onCollapse() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            MonoLabel("Workspace", color: WL.pencil, size: 10, tracking: 2.2)
            Text(player.track.title).font(WL.display(26)).foregroundStyle(WL.cream)
            MonoLabel("\(player.track.artist) · \(store.currentVersion(trackID)?.label ?? player.track.versionLabel)",
                      color: WL.pencil, size: 10, tracking: 1.4)
        }
    }

    // MARK: waveform + mini transport

    private var waveSection: some View {
        VStack(spacing: 10) {
            WaveStrip(
                peaks: wavePeaks(trackID),
                progress: player.progress,
                marker: markFraction,
                noteMarks: store.notes(trackID).compactMap { n in
                    n.positionMs.map { NoteMark(id: n.id, fraction: Double($0) / Double(duration), resolved: n.resolved) }
                },
                onScrub: { markerMs = Int($0 * Double(duration)) }
            )
            .frame(height: 46)

            HStack(spacing: 12) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WL.black)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(WL.cream))
                }
                .buttonStyle(.plain)
                Text(player.positionMs.clock).font(WL.mono(11)).foregroundStyle(WL.cream.opacity(0.7)).monospacedDigit()
                Spacer()
                Text("MARK \(markPos.clock)").font(WL.mono(10)).tracking(1).foregroundStyle(WL.cobalt)
                Spacer()
                Text(duration.clock).font(WL.mono(11)).foregroundStyle(WL.cream.opacity(0.7)).monospacedDigit()
            }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("\(editing == nil ? "+" : "✎") \(markPos.clock)")
                    .font(WL.mono(11)).foregroundStyle(WL.cobalt)
                TextField(editing == nil ? "Leave a note at the marker…" : "Edit note…",
                          text: $noteText, axis: .vertical)
                    .font(WL.text(14)).foregroundStyle(WL.cream).tint(WL.cobalt)
                    .focused($composing).lineLimit(1...5)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { composing = false }
                                .font(WL.mono(13)).foregroundStyle(WL.cobalt)
                        }
                    }
            }
            HStack(spacing: 12) {
                Menu {
                    ForEach(store.members, id: \.self) { m in
                        Button(m) { insertMention(m) }
                    }
                } label: {
                    Text("@ Tag").font(WL.mono(10)).tracking(1).foregroundStyle(WL.cobalt)
                }
                if editing != nil {
                    Button("Cancel") { resetComposer() }
                        .font(WL.mono(10)).foregroundStyle(WL.pencil)
                }
                Spacer()
                if !noteText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        if let id = editing {
                            store.updateNote(trackID, id, body: noteText, positionMs: markPos)
                        } else {
                            store.addNote(track: trackID, positionMs: markPos, body: noteText)
                        }
                        resetComposer()
                    } label: {
                        Text(editing == nil ? "ADD" : "SAVE").font(WL.mono(10)).tracking(1)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(WL.cream)).foregroundStyle(WL.black)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WL.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WL.cream.opacity(0.08), lineWidth: 1))
    }

    private func noteRow(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(note.resolved ? WL.green : WL.redline).frame(width: 2)
                .opacity(note.resolved ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Button {
                        if let ms = note.positionMs { player.seek(to: Double(ms) / Double(duration)) }
                    } label: {
                        Text(note.positionMs.map { $0.clock } ?? "general")
                            .font(WL.mono(11))
                            .foregroundStyle(note.resolved ? WL.green : WL.cobalt)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(WL.cream.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    MonoLabel(note.author, color: WL.pencil, size: 9, tracking: 1.2)
                    Spacer()
                    Menu {
                        Button { startEdit(note) } label: { Label("Edit", systemImage: "pencil") }
                        Button { store.toggleResolved(trackID, note.id) } label: {
                            Label(note.resolved ? "Reopen" : "Resolve", systemImage: note.resolved ? "arrow.uturn.backward" : "checkmark")
                        }
                        Button(role: .destructive) { store.deleteNote(trackID, note.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(WL.pencil)
                            .frame(width: 28, height: 20)
                    }
                }
                Text(styled(note.body))
                    .font(WL.text(14))
                    .foregroundStyle(note.resolved ? WL.pencil : WL.cream.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .opacity(note.resolved ? 0.75 : 1)
    }

    // MARK: helpers

    private func insertMention(_ member: String) {
        let first = member.split(separator: " ").first.map(String.init) ?? member
        if !noteText.isEmpty && !noteText.hasSuffix(" ") { noteText += " " }
        noteText += "@\(first) "
        composing = true
    }

    private func startEdit(_ note: Note) {
        editing = note.id
        noteText = note.body
        markerMs = note.positionMs
        composing = true
    }

    private func resetComposer() {
        // keep markerMs where the user placed it, so consecutive notes don't snap
        // back to one spot — drag the waveform marker to set each note's time.
        noteText = ""; editing = nil; composing = false
    }

    private func styled(_ body: String) -> AttributedString {
        var out = AttributedString()
        let parts = body.split(separator: " ", omittingEmptySubsequences: false)
        for (i, p) in parts.enumerated() {
            var a = AttributedString(String(p))
            if p.hasPrefix("@") { a.foregroundColor = WL.cobalt }
            out += a
            if i < parts.count - 1 { out += AttributedString(" ") }
        }
        return out
    }
}
