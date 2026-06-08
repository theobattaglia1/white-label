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
    private var duration: Int { player.durationMs }
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
        .foregroundStyle(PB.cream)
        .contentShape(Rectangle())
        .onTapGesture { composing = false }   // tap anywhere empty to dismiss the keyboard
        .onChange(of: composeToken) { _, _ in
            // focus after the slide-up settles, so the keyboard doesn't fight the scroll
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { composing = true }
        }
    }

    private var grabber: some View {
        Button {
            composing = false
            onCollapse()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(PB.cream.opacity(0.45))
                Capsule().fill(PB.cream.opacity(0.18)).frame(width: 38, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close notes and versions")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            MonoLabel("Workspace", color: PB.pencil, size: 10, tracking: 2.2)
            Text(store.displayTitle(trackID, player.track.title)).font(PB.display(26)).foregroundStyle(PB.cream)
            MonoLabel("\(player.track.artist) · \(store.currentVersion(trackID)?.label ?? player.track.versionLabel)",
                      color: PB.pencil, size: 10, tracking: 1.4)
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
                        .foregroundStyle(PB.black)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(PB.cream))
                }
                .buttonStyle(.plain)
                Text(player.positionMs.clock).font(PB.mono(11)).foregroundStyle(PB.cream.opacity(0.7)).monospacedDigit()
                Spacer()
                Text("MARK \(markPos.clock)").font(PB.mono(10)).tracking(1).foregroundStyle(PB.cobalt)
                Spacer()
                Text(duration.clock).font(PB.mono(11)).foregroundStyle(PB.cream.opacity(0.7)).monospacedDigit()
            }
        }
    }

    // MARK: versions

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            MonoLabel("Versions", color: PB.pencil, size: 10, tracking: 2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(store.versions(trackID)) { v in
                        let isCurrent = store.currentVersion(trackID)?.id == v.id
                        Button { store.setCurrent(trackID, v.id) } label: {
                            VStack(spacing: 3) {
                                HStack(spacing: 5) {
                                    Text(v.label).font(PB.mono(11))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.82)
                                    if v.approved {
                                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(PB.green)
                                    }
                                }
                                Text(v.loudness).font(PB.mono(8)).foregroundStyle(isCurrent ? PB.cream.opacity(0.7) : PB.pencil)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(width: 108)
                            .frame(minHeight: 42)
                            .background(Capsule().fill(isCurrent ? PB.cobalt.opacity(0.18) : .clear))
                            .overlay(Capsule().strokeBorder(isCurrent ? PB.cobalt : PB.cream.opacity(0.16), lineWidth: 1))
                            .foregroundStyle(isCurrent ? PB.cream : PB.pencil)
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
                MonoLabel("Notes", color: PB.pencil, size: 10, tracking: 2)
                Spacer()
                MonoLabel("\(store.openCount(trackID)) open", color: PB.redline, size: 9, tracking: 1.4)
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
                    .font(PB.mono(11)).foregroundStyle(PB.cobalt)
                TextField(editing == nil ? "Leave a note at the marker…" : "Edit note…",
                          text: $noteText, axis: .vertical)
                    .font(PB.text(14)).foregroundStyle(PB.cream).tint(PB.cobalt)
                    .focused($composing).lineLimit(1...5)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { composing = false }
                                .font(PB.mono(13)).foregroundStyle(PB.cobalt)
                        }
                    }
            }
            HStack(spacing: 12) {
                Menu {
                    ForEach(store.members, id: \.self) { m in
                        Button(m) { insertMention(m) }
                    }
                } label: {
                    Text("@ Tag").font(PB.mono(10)).tracking(1).foregroundStyle(PB.cobalt)
                }
                if editing != nil {
                    Button("Cancel") { resetComposer() }
                        .font(PB.mono(10)).foregroundStyle(PB.pencil)
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
                        Text(editing == nil ? "ADD" : "SAVE").font(PB.mono(10)).tracking(1)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(PB.cream)).foregroundStyle(PB.black)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PB.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PB.cream.opacity(0.08), lineWidth: 1))
    }

    private func noteRow(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(note.resolved ? PB.green : PB.redline).frame(width: 2)
                .opacity(note.resolved ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Button {
                        if let ms = note.positionMs { player.seek(to: Double(ms) / Double(duration)) }
                    } label: {
                        Text(note.positionMs.map { $0.clock } ?? "general")
                            .font(PB.mono(11))
                            .foregroundStyle(note.resolved ? PB.green : PB.cobalt)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(PB.cream.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    MonoLabel(note.author, color: PB.pencil, size: 9, tracking: 1.2)
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
                        Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(PB.pencil)
                            .frame(width: 28, height: 20)
                    }
                }
                Text(styled(note.body))
                    .font(PB.text(14))
                    .foregroundStyle(note.resolved ? PB.pencil : PB.cream.opacity(0.92))
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
            if p.hasPrefix("@") { a.foregroundColor = PB.cobalt }
            out += a
            if i < parts.count - 1 { out += AttributedString(" ") }
        }
        return out
    }
}
